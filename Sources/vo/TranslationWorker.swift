import Foundation

/// One chunk travelling through translation, keyed by the renderer's `seq`. Used for
/// both the request (`text` is source) and the result (`text` is target).
struct TranslationItem: Sendable, Equatable {
    let seq: Int
    let text: String
}

/// The translation engine as the worker sees it. Production wraps a
/// `TranslationSession`; tests substitute a scripted fake, which is why the worker is
/// written against this protocol instead of the framework type.
protocol TranslationBackend: Sendable {
    func prepare() async throws
    /// Translate `batch`, yielding each result as soon as it is ready, in any order.
    func translate(_ batch: [TranslationItem]) -> AsyncThrowingStream<TranslationItem, Error>
}

/// How long a call may go without yielding a result before the session is treated as
/// wedged. Ordinary chunks translate in well under a few seconds, so this only trips
/// on a real stall, while still recovering long before a user gives up on the session.
let translationStallTimeout: Duration = .seconds(30)

/// Upper bound on chunks per call. Catching up only needs a handful, and a cap keeps
/// the work thrown away by one stall small (file mode can queue hundreds of chunks).
let maxTranslationBatch = 16

/// How many stalled calls a single chunk may be part of before it is given up on.
/// A chunk that wedges a fresh session again is likely the trigger itself, and
/// retrying it forever would block every later chunk behind the strict-order commit.
let maxTranslationStallAttempts = 2

/// Feeds finalized chunks to a translation backend with exactly one call in flight.
///
/// Only one, because overlapping `translate(_:)` calls on a shared `TranslationSession`
/// are not documented as safe, and a live session was observed to stop answering
/// for good while four were in flight. Throughput comes from batching instead.
/// Whatever queued up while the previous call ran goes out together in the next, so
/// the worker translates one chunk at a time when it is keeping up and catches up in
/// bulk when it is not.
///
/// A call that yields nothing for `stallTimeout` is abandoned, not awaited, because a
/// wedged call may never honour cancellation. The backend is rebuilt and the chunks
/// still unanswered are retried one at a time, so a chunk that keeps wedging the
/// engine is identified and failed alone.
struct TranslationWorker: Sendable {
    let makeBackend: @Sendable () -> any TranslationBackend
    let onResult: @Sendable (TranslationItem) async -> Void
    let onNotice: @Sendable (String) -> Void
    var stallTimeout: Duration = translationStallTimeout
    var maxBatch: Int = maxTranslationBatch
    var maxStallAttempts: Int = maxTranslationStallAttempts

    func run(chunks: AsyncStream<TranslationItem>) async {
        let queue = TranslationQueue()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await item in chunks { await queue.push(item) }
                await queue.finish()
            }
            group.addTask { await self.loop(queue: queue) }
        }
    }

    private func loop(queue: TranslationQueue) async {
        guard var backend = await makePreparedBackend() else { return }
        var retry: [TranslationItem] = []
        var stalls: [Int: Int] = [:]

        while true {
            let batch: [TranslationItem]
            if !retry.isEmpty {
                batch = [retry.removeFirst()]
            } else if let next = await queue.take(max: maxBatch) {
                batch = next
            } else {
                return
            }

            switch await runBatch(batch, on: backend) {
            case .completed:
                continue
            case .cancelled:
                return
            case .failed(let error, let remaining):
                // A thrown batch error cannot be pinned on one chunk, so a multi-chunk
                // batch is retried singly to fail only the chunk that actually errors.
                if batch.count > 1 {
                    retry.append(contentsOf: remaining)
                } else {
                    for item in remaining {
                        await onResult(TranslationItem(seq: item.seq, text: "[translation failed: \(error.localizedDescription)]"))
                    }
                }
            case .stalled(let remaining):
                onNotice("vo: translation made no progress for \(seconds(stallTimeout))s. Restarting the translation session.")
                guard let fresh = await makePreparedBackend() else { return }
                backend = fresh
                for item in remaining {
                    let n = stalls[item.seq, default: 0] + 1
                    stalls[item.seq] = n
                    if n >= maxStallAttempts {
                        await onResult(TranslationItem(seq: item.seq, text: "[translation failed: no response within \(seconds(stallTimeout))s]"))
                    } else {
                        retry.append(item)
                    }
                }
            }
        }
    }

    /// A new backend, warmed so the first chunk does not pay for lazy model loading.
    /// Warm-up failure is non-fatal (translate surfaces real errors). A warm-up that
    /// outlives `stallTimeout` is still running inside that backend, so translating on
    /// it would overlap two calls on one session. That backend is dropped for a
    /// second one used unwarmed, because warming that one too could wedge the same
    /// way with no bound on retries, while its first translate is already bounded by
    /// the stall watchdog. nil only when the worker itself was cancelled.
    private func makePreparedBackend() async -> (any TranslationBackend)? {
        let backend = makeBackend()
        switch await prepare(backend) {
        case .ready:
            return backend
        case .timedOut:
            onNotice("vo: translation warm-up made no progress for \(seconds(stallTimeout))s. Restarting the translation session.")
            return makeBackend()
        case .cancelled:
            return nil
        }
    }

    private enum PrepareOutcome {
        case ready
        case timedOut
        case cancelled
    }

    private func prepare(_ backend: any TranslationBackend) async -> PrepareOutcome {
        let (signal, cont) = AsyncStream<PrepareOutcome>.makeStream()
        let preparing = Task {
            try? await backend.prepare()
            cont.yield(.ready)
        }
        let timer = Task {
            try? await Task.sleep(for: stallTimeout)
            cont.yield(.timedOut)
        }
        var outcome = PrepareOutcome.cancelled
        for await first in signal {
            outcome = first
            break
        }
        cont.finish()
        timer.cancel()
        if Task.isCancelled { outcome = .cancelled }
        if outcome != .ready { preparing.cancel() }
        return outcome
    }

    private enum BatchOutcome {
        case completed
        case cancelled
        case failed(Error, remaining: [TranslationItem])
        case stalled(remaining: [TranslationItem])
    }

    private enum BatchEvent: Sendable {
        case result(TranslationItem)
        case done
        case failed(Error)
        case stalled
    }

    private func runBatch(_ batch: [TranslationItem], on backend: any TranslationBackend) async -> BatchOutcome {
        var remaining = batch
        let (events, cont) = AsyncStream<BatchEvent>.makeStream()
        let progress = StallDeadline(timeout: stallTimeout)

        let consumer = Task {
            do {
                for try await result in backend.translate(batch) {
                    cont.yield(.result(result))
                }
                cont.yield(.done)
            } catch {
                cont.yield(.failed(error))
            }
        }
        let watchdog = Task {
            while !Task.isCancelled {
                let deadline = await progress.deadline
                try? await Task.sleep(until: deadline, clock: .continuous)
                if Task.isCancelled { return }
                if await progress.deadline <= .now {
                    cont.yield(.stalled)
                    return
                }
            }
        }
        defer {
            watchdog.cancel()
            cont.finish()
        }

        for await event in events {
            switch event {
            case .result(let result):
                // Results for seqs this batch no longer owns (a duplicate, or a stray
                // id) are dropped so a chunk is never committed twice.
                // They also leave the deadline alone, so a backend emitting only
                // strays is still caught as a stall.
                guard let i = remaining.firstIndex(where: { $0.seq == result.seq }) else { continue }
                remaining.remove(at: i)
                await progress.bump()
                await onResult(result)
            case .done:
                if remaining.isEmpty { return .completed }
                return .failed(TranslationWorkerError.missingResults, remaining: remaining)
            case .failed(let error):
                return .failed(error, remaining: remaining)
            case .stalled:
                consumer.cancel()
                return .stalled(remaining: remaining)
            }
        }
        consumer.cancel()
        return .cancelled
    }

    private func seconds(_ d: Duration) -> Int64 { d.components.seconds }
}

enum TranslationWorkerError: Error, LocalizedError {
    case missingResults

    var errorDescription: String? {
        switch self {
        case .missingResults: return "no result returned for this chunk"
        }
    }
}

/// FIFO between the chunk stream and the worker loop. The loop takes everything that
/// accumulated (up to a cap) in one go, which is what turns a backlog into a batch.
actor TranslationQueue {
    private var items: [TranslationItem] = []
    private var finished = false
    private var waiter: CheckedContinuation<Void, Never>?

    func push(_ item: TranslationItem) {
        items.append(item)
        wake()
    }

    func finish() {
        finished = true
        wake()
    }

    /// Up to `max` queued items, suspending while empty. nil once finished and drained.
    func take(max: Int) async -> [TranslationItem]? {
        while items.isEmpty && !finished {
            await withCheckedContinuation { waiter = $0 }
        }
        guard !items.isEmpty else { return nil }
        let n = min(max, items.count)
        let batch = Array(items.prefix(n))
        items.removeFirst(n)
        return batch
    }

    private func wake() {
        waiter?.resume()
        waiter = nil
    }
}

/// Sliding deadline pushed forward on every accepted result, so a large batch that is slow but
/// still answering is never mistaken for a stall.
private actor StallDeadline {
    private let timeout: Duration
    private(set) var deadline: ContinuousClock.Instant

    init(timeout: Duration) {
        self.timeout = timeout
        self.deadline = .now + timeout
    }

    func bump() {
        deadline = .now + timeout
    }
}
