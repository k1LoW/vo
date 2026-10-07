import Foundation
import Synchronization
import Testing
@testable import vo

/// What a fake backend does with one call.
private enum FakeCall: Sendable {
    /// Answer every chunk.
    case answer
    /// Answer every chunk once the test opens the gate.
    case gated
    /// Answer every chunk, one per `interval`.
    case trickle(Duration)
    /// Never answer and never finish.
    case hang
    /// Throw without answering.
    case fail
    /// Keep yielding results for a seq nobody asked for, never answering the batch.
    case strays(Duration)
}

private struct FakeError: Error, LocalizedError {
    var errorDescription: String? { "boom" }
}

/// Everything the worker did, recorded so tests can assert on it.
private final class Recorder: Sendable {
    struct State {
        var calls: [(generation: Int, seqs: [Int])] = []
        var results: [Int: String] = [:]
        var notices: [String] = []
        var generations = 0
        var gateOpen = false
        var workerDone = false
        var inFlight: [Int: Int] = [:]
        var maxInFlight = 0
    }

    let state = Mutex(State())

    var calls: [(generation: Int, seqs: [Int])] { state.withLock { $0.calls } }
    var results: [Int: String] { state.withLock { $0.results } }
    var notices: [String] { state.withLock { $0.notices } }
    var gateOpen: Bool { state.withLock { $0.gateOpen } }
    /// Most calls ever open at once on a single backend. An abandoned call on a
    /// replaced backend does not count against its successor.
    var maxInFlight: Int { state.withLock { $0.maxInFlight } }

    func openGate() { state.withLock { $0.gateOpen = true } }
}

private struct FakeBackend: TranslationBackend {
    let generation: Int
    let recorder: Recorder
    let script: @Sendable (_ generation: Int, _ seqs: [Int]) -> FakeCall
    let prepareHangs: Bool

    func prepare() async throws {
        if prepareHangs {
            // Stops only once the worker cancels it, which it does after giving up.
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(60)) }
        }
    }

    func translate(_ batch: [TranslationItem]) -> AsyncThrowingStream<TranslationItem, Error> {
        let seqs = batch.map(\.seq)
        let generation = generation
        recorder.state.withLock { s in
            s.calls.append((generation, seqs))
            let open = s.inFlight[generation, default: 0] + 1
            s.inFlight[generation] = open
            s.maxInFlight = max(s.maxInFlight, open)
        }
        let call = script(generation, seqs)
        let recorder = recorder
        return AsyncThrowingStream { cont in
            cont.onTermination = { _ in
                recorder.state.withLock { $0.inFlight[generation, default: 0] -= 1 }
            }
            Task {
                switch call {
                case .answer:
                    break
                case .gated:
                    while !recorder.gateOpen { try? await Task.sleep(for: .milliseconds(5)) }
                case .trickle(let interval):
                    for item in batch {
                        try? await Task.sleep(for: interval)
                        cont.yield(TranslationItem(seq: item.seq, text: "t:\(item.text)"))
                    }
                    cont.finish()
                    return
                case .hang:
                    return
                case .fail:
                    cont.finish(throwing: FakeError())
                    return
                case .strays(let interval):
                    // This Task is not the one the worker cancels, so it watches for
                    // the stream being torn down instead.
                    while true {
                        if case .terminated = cont.yield(TranslationItem(seq: -1, text: "stray")) { return }
                        try? await Task.sleep(for: interval)
                    }
                }
                for item in batch { cont.yield(TranslationItem(seq: item.seq, text: "t:\(item.text)")) }
                cont.finish()
            }
        }
    }
}

/// Polls until `condition` holds, failing the test instead of hanging if it never does.
@discardableResult
private func waitUntil(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<400 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("condition not reached in time")
    return false
}

/// Runs a worker with a short stall timeout. `feed` pushes chunks and drives the gate;
/// the worker is awaited after the chunk stream is finished.
private func runWorker(
    maxBatch: Int = 16,
    maxStallAttempts: Int = 2,
    prepareHangs: @escaping @Sendable (_ generation: Int) -> Bool = { _ in false },
    script: @escaping @Sendable (_ generation: Int, _ seqs: [Int]) -> FakeCall,
    feed: (AsyncStream<TranslationItem>.Continuation, Recorder) async -> Void
) async -> Recorder {
    let recorder = Recorder()
    let worker = TranslationWorker(
        makeBackend: {
            let generation = recorder.state.withLock { s in
                defer { s.generations += 1 }
                return s.generations
            }
            return FakeBackend(generation: generation, recorder: recorder, script: script, prepareHangs: prepareHangs(generation))
        },
        onResult: { item in recorder.state.withLock { $0.results[item.seq] = item.text } },
        onNotice: { message in recorder.state.withLock { $0.notices.append(message) } },
        stallTimeout: .milliseconds(100),
        maxBatch: maxBatch,
        maxStallAttempts: maxStallAttempts
    )
    let (chunks, cont) = AsyncStream<TranslationItem>.makeStream()
    let task = Task {
        await worker.run(chunks: chunks)
        recorder.state.withLock { $0.workerDone = true }
    }
    await feed(cont, recorder)
    cont.finish()
    // Awaiting task.value directly would hang the whole suite if a regression left
    // the worker stuck behind a fake that never answers.
    if await !waitUntil({ recorder.state.withLock { $0.workerDone } }) {
        task.cancel()
    }
    return recorder
}

private func item(_ seq: Int) -> TranslationItem {
    TranslationItem(seq: seq, text: "s\(seq)")
}

@Suite("Translation worker")
struct TranslationWorkerTests {
    /// Chunks that arrive while a call is in flight go out together in the next call,
    /// never as overlapping calls.
    @Test func backlogIsSentAsOneBatch() async {
        let recorder = await runWorker(script: { _, seqs in seqs == [0] ? .gated : .answer }) { cont, recorder in
            cont.yield(item(0))
            await waitUntil { recorder.calls.count == 1 }
            for seq in 1...4 { cont.yield(item(seq)) }
            try? await Task.sleep(for: .milliseconds(20))
            #expect(recorder.calls.count == 1)
            recorder.openGate()
            await waitUntil { recorder.results.count == 5 }
        }
        #expect(recorder.maxInFlight == 1)
        #expect(recorder.calls.map(\.seqs) == [[0], [1, 2, 3, 4]])
        #expect(recorder.results == [0: "t:s0", 1: "t:s1", 2: "t:s2", 3: "t:s3", 4: "t:s4"])
        #expect(recorder.notices.isEmpty)
    }

    /// A backlog larger than the cap is split across consecutive calls.
    @Test func batchIsCapped() async {
        let recorder = await runWorker(maxBatch: 2, script: { _, seqs in seqs == [0] ? .gated : .answer }) { cont, recorder in
            cont.yield(item(0))
            await waitUntil { recorder.calls.count == 1 }
            for seq in 1...5 { cont.yield(item(seq)) }
            try? await Task.sleep(for: .milliseconds(20))
            recorder.openGate()
            await waitUntil { recorder.results.count == 6 }
        }
        #expect(recorder.maxInFlight == 1)
        #expect(recorder.calls.map(\.seqs) == [[0], [1, 2], [3, 4], [5]])
    }

    /// A call that stops answering is abandoned, the backend is rebuilt, and the
    /// unanswered chunk is retried on the new backend before the backlog behind it.
    @Test func stallRebuildsBackendAndRetries() async {
        let recorder = await runWorker(script: { generation, _ in generation == 0 ? .hang : .answer }) { cont, recorder in
            cont.yield(item(0))
            await waitUntil { recorder.calls.count == 1 }
            cont.yield(item(1))
            cont.yield(item(2))
            await waitUntil { recorder.results.count == 3 }
        }
        #expect(recorder.maxInFlight == 1)
        #expect(recorder.calls.map(\.generation) == [0, 1, 1])
        #expect(recorder.calls.map(\.seqs) == [[0], [0], [1, 2]])
        #expect(recorder.results == [0: "t:s0", 1: "t:s1", 2: "t:s2"])
        #expect(recorder.notices.count == 1)
    }

    /// A backend whose warm-up never finishes is never translated on, so no translate
    /// call overlaps the warm-up still running inside it.
    @Test func backendWithStuckWarmUpIsReplaced() async {
        let recorder = await runWorker(prepareHangs: { $0 == 0 }, script: { _, _ in .answer }) { cont, recorder in
            cont.yield(item(0))
            await waitUntil { recorder.results.count == 1 }
        }
        #expect(recorder.maxInFlight == 1)
        #expect(recorder.calls.map(\.generation) == [1])
        #expect(recorder.results == [0: "t:s0"])
        #expect(recorder.notices.count == 1)
    }

    /// Results that answer no pending chunk are not progress, so a backend that only
    /// emits those is still treated as stalled and replaced.
    @Test func strayResultsDoNotHoldOffTheStall() async {
        let recorder = await runWorker(script: { generation, _ in generation == 0 ? .strays(.milliseconds(20)) : .answer }) { cont, recorder in
            cont.yield(item(0))
            await waitUntil { recorder.results.count == 1 }
        }
        #expect(recorder.maxInFlight == 1)
        #expect(recorder.calls.map(\.generation) == [0, 1])
        #expect(recorder.results == [0: "t:s0"])
        #expect(recorder.notices.count == 1)
    }

    /// A chunk that wedges every fresh backend is failed on its own, so the chunks
    /// behind it still get translated instead of waiting forever.
    @Test func chunkThatKeepsStallingIsFailedAlone() async {
        let recorder = await runWorker(script: { _, seqs in seqs.contains(0) ? .hang : .answer }) { cont, recorder in
            cont.yield(item(0))
            cont.yield(item(1))
            await waitUntil { recorder.results.count == 2 }
        }
        #expect(recorder.maxInFlight == 1)
        #expect(recorder.results[0]?.hasPrefix("[translation failed:") == true)
        #expect(recorder.results[1] == "t:s1")
    }

    /// A batch slower than the stall timeout overall is not a stall as long as each
    /// result arrives within it.
    @Test func slowButAnsweringBatchIsNotAStall() async {
        let recorder = await runWorker(script: { _, seqs in seqs == [0] ? .gated : .trickle(.milliseconds(50)) }) { cont, recorder in
            cont.yield(item(0))
            await waitUntil { recorder.calls.count == 1 }
            for seq in 1...5 { cont.yield(item(seq)) }
            try? await Task.sleep(for: .milliseconds(20))
            recorder.openGate()
            await waitUntil { recorder.results.count == 6 }
        }
        #expect(recorder.maxInFlight == 1)
        #expect(recorder.calls.map(\.seqs) == [[0], [1, 2, 3, 4, 5]])
        #expect(recorder.notices.isEmpty)
    }

    /// An error thrown by a batch is narrowed down by retrying its chunks one by one,
    /// so only the chunk that really fails is marked as failed.
    @Test func batchErrorIsNarrowedToTheFailingChunk() async {
        let recorder = await runWorker(script: { _, seqs in
            if seqs == [0] { return .gated }
            return seqs.contains(2) ? .fail : .answer
        }) { cont, recorder in
            cont.yield(item(0))
            await waitUntil { recorder.calls.count == 1 }
            for seq in 1...3 { cont.yield(item(seq)) }
            try? await Task.sleep(for: .milliseconds(20))
            recorder.openGate()
            await waitUntil { recorder.results.count == 4 }
        }
        #expect(recorder.maxInFlight == 1)
        #expect(recorder.calls.map(\.seqs) == [[0], [1, 2, 3], [1], [2], [3]])
        #expect(recorder.results[1] == "t:s1")
        #expect(recorder.results[2] == "[translation failed: boom]")
        #expect(recorder.results[3] == "t:s3")
    }
}
