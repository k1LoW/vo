import Foundation
@preconcurrency import AVFoundation
import CoreAudio
import Darwin
import Speech
import Translation

/// Monotonic sequence counter shared across channels.
actor SeqCounter {
    private var n = 0
    func next() -> Int {
        defer { n += 1 }
        return n
    }
}

/// Wrapper that lets us pass MicCapture/SpeakerCapture stop closures across actor
/// boundaries without making the capture classes themselves Sendable. They are owned
/// strictly by their channel Task and the registry is only ever invoked from a
/// serialized actor context (or from `runChannel`'s own defer), so this is safe.
struct AsyncStopper: @unchecked Sendable {
    let action: () async -> Void
}

/// Sendable shim over `TranslationSession` (non-Sendable class) so a single
/// session can be shared across concurrent translate calls fanned out via
/// TaskGroup. Apple does not document `TranslationSession.translate(_:)` as
/// concurrent-safe explicitly, but `translations(batch:)` exists, which implies
/// the underlying engine accepts overlapping requests. We bound the concurrency
/// at the call site to limit blast radius if that assumption ever breaks.
struct SendableTranslationSession: @unchecked Sendable {
    let inner: TranslationSession
}

/// Per-channel translation fan-out width. File mode finalizes transcribe chunks
/// far faster than a single serial `translate(_:)` can drain, so chunks queue
/// up behind StreamRenderer.commitQueue's head and nothing emits until SIGINT.
/// Fanning out lets independent chunks translate in parallel; the renderer's
/// seq-ordered commit still preserves output order.
private let translateConcurrency = 4

/// Holds per-channel "stop the audio source" closures so the SIGINT handler can
/// stop capture before blocking on the save prompt. Without this the OS keeps
/// pulling mic/speaker frames while the user is deciding where to save the log.
actor StopRegistry {
    private var stoppers: [AsyncStopper] = []
    private var stopped: Bool = false

    /// Register a stopper. If `stopAll()` has already run, the stopper is invoked
    /// immediately instead of being stored — otherwise a channel that finished
    /// starting its audio source after SIGINT would leave that source running
    /// while the save prompt blocks.
    func register(_ stopper: AsyncStopper) async {
        if stopped {
            await stopper.action()
            return
        }
        stoppers.append(stopper)
    }

    /// Run every registered stopper exactly once, in registration order. Subsequent
    /// `register` calls invoke the stopper inline; subsequent `stopAll` calls are no-ops.
    func stopAll() async {
        stopped = true
        let pending = stoppers
        stoppers.removeAll()
        for s in pending { await s.action() }
    }
}

/// Bounded async buffer between the file-mode resampler and SpeechAnalyzer's input
/// sequence. `send` suspends when the buffer is full so file reads cannot race ahead
/// of the analyzer's drain rate. Used only in file mode; live capture stays on
/// AsyncStream because its yield rate is already paced by wall-clock device callbacks
/// (~50 buffers/sec mic, similar speaker), so unboundedness there is bounded in
/// practice. A file feeder has no such pacing and would otherwise let memory grow
/// proportionally to (read-speed − analyze-speed) × duration on long files, violating
/// the "memory stays bounded across long sessions" invariant CLAUDE.md asserts.
///
/// Conforms to AsyncSequence so it can be passed straight to
/// `SpeechAnalyzer.start(inputSequence:)`.
actor BoundedAnalyzerInputBuffer {
    private let capacity: Int
    private var items: [AnalyzerInput] = []
    private var takeWaiters: [CheckedContinuation<AnalyzerInput?, Never>] = []
    private var sendWaiters: [(AnalyzerInput, CheckedContinuation<Void, Never>)] = []
    private var finished = false

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    /// Append an item; suspends until there is room (or finish() is called).
    func send(_ item: AnalyzerInput) async {
        if finished { return }
        if let waiter = takeWaiters.first {
            takeWaiters.removeFirst()
            waiter.resume(returning: item)
            return
        }
        if items.count < capacity {
            items.append(item)
            return
        }
        await withCheckedContinuation { cont in
            sendWaiters.append((item, cont))
        }
    }

    /// Pop the next item; suspends until one is available, or returns nil after finish().
    func next() async -> AnalyzerInput? {
        if let item = items.first {
            items.removeFirst()
            // Free one capacity slot for the oldest waiting sender.
            if !sendWaiters.isEmpty {
                let (queued, cont) = sendWaiters.removeFirst()
                items.append(queued)
                cont.resume()
            }
            return item
        }
        if finished { return nil }
        return await withCheckedContinuation { cont in
            takeWaiters.append(cont)
        }
    }

    /// Mark the buffer closed. Pending takers wake with nil; pending senders wake
    /// without their items being delivered (the consumer is gone, so the items
    /// would be lost regardless). Idempotent.
    func finish() {
        if finished { return }
        finished = true
        for waiter in takeWaiters { waiter.resume(returning: nil) }
        takeWaiters.removeAll()
        for (_, cont) in sendWaiters { cont.resume() }
        sendWaiters.removeAll()
    }
}

extension BoundedAnalyzerInputBuffer: AsyncSequence {
    typealias Element = AnalyzerInput

    nonisolated func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(buffer: self)
    }

    struct AsyncIterator: AsyncIteratorProtocol {
        let buffer: BoundedAnalyzerInputBuffer
        func next() async -> AnalyzerInput? {
            await buffer.next()
        }
    }
}

/// Coordinates a channel's device-follow rebind between the device-change callback
/// (which fires on the main queue, where DefaultDeviceChangeListener installs it) and
/// the feeder task that pulls audio buffers.
/// The lock is the only shared state; the capture objects stay owned by their channel.
final class RebindBox: @unchecked Sendable {
    private let lock = NSLock()
    private var rebindRequested = false
    private var stopped = false
    private var current: (() async -> Void)?

    /// Record the active capture's stopper, replacing the previous one across rebinds.
    /// Returns false, leaving the caller to stop the just-started capture itself, when:
    ///   - the channel is shutting down (`stopCurrent` already ran and would not see a
    ///     capture registered after it, which would resume capture during the save prompt), or
    ///   - a rebind was already requested before this capture registered. A device-change
    ///     can fire in the window between `cap.start()` and `setCurrent`, when there is no
    ///     stopper to take yet; `requestRebindAndTakeStopper` then returns nil and only
    ///     sets `rebindRequested`. Rejecting here makes the caller stop the capture so the
    ///     feeder sees the ended stream and rebuilds, instead of the request being lost.
    func setCurrent(_ stop: @escaping () async -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, !rebindRequested else { return false }
        current = stop
        return true
    }

    /// Device-change callback entry. Atomically marks a rebind wanted and takes the
    /// active capture's stopper so the caller stops it exactly once. Returns nil when the
    /// channel is already shutting down (stopCurrent took the stopper), so the
    /// device-change path (main queue) and the shutdown path (stop registry) never stop
    /// the same capture concurrently. The capture classes have no internal locking, so a
    /// concurrent double stop would be a data race.
    func requestRebindAndTakeStopper() -> (() async -> Void)? {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return nil }
        rebindRequested = true
        let stop = current
        current = nil
        return stop
    }

    /// Feeder check after a capture's stream ends: true if it ended because the device
    /// changed (rebuild on the new default), false if the channel is shutting down.
    func shouldRebind() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard rebindRequested, !stopped else { return false }
        rebindRequested = false
        return true
    }

    /// Stop the active capture and mark the channel stopped so no rebind races shutdown.
    func stopCurrent() async {
        await takeForShutdown()?()
    }

    /// Synchronous locked section, kept out of the async caller so the lock is never
    /// held across a suspension point.
    private func takeForShutdown() -> (() async -> Void)? {
        lock.lock(); defer { lock.unlock() }
        stopped = true
        let stop = current
        current = nil
        return stop
    }
}

/// Per-channel reconciler for the multi-source (auto-detect) pipeline. Each enabled
/// source locale runs its own SpeechTranscriber on the same audio. They independently
/// segment by their own VAD, so the same utterance arrives as N (slightly offset)
/// finalized chunks. The reconciler matches them by `audio.range` overlap and emits
/// exactly one winner per utterance to the renderer + translator routing.
///
/// Matching: a candidate joins an existing pending region when
///   overlap(region, candidate) / min(region.length, candidate.length) > 0.5
/// (the shorter side must be majority-covered). The pending region's union expands
/// to include the new candidate so subsequent candidates can still match.
///
/// Emission: a region fires when either
///   - all N source locales have contributed a candidate, or
///   - 300 ms has elapsed since the first candidate for that region arrived
/// The winner is the candidate with the highest `confidence.mean`. A candidate that
/// arrives after its region already fired is dropped via the `recentlyEmitted` audio
/// range list so the same utterance never emits twice. We prune that list by audio
/// range (not wall clock) because a slow-language transcriber can lag the fast one
/// by seconds on long utterances; a wall-clock TTL would expire too early and let
/// the laggard double-emit. Since each transcriber moves monotonically forward on
/// the session timeline, an emitted region with `unionEnd <= incoming.audioStart`
/// can never overlap a future chunk and is safe to drop.
///
/// `nLocales == 1` is the legacy single-source mode; the reconciler short-circuits
/// straight to `onEmit` with no buffering or timer, so output latency is unchanged.
actor ChunkReconciler {
    struct Candidate: Sendable {
        let locale: Locale
        let text: String
        let timing: ChunkTiming
        let confidence: ChunkConfidence?
    }

    private struct PendingRegion {
        let id: UUID
        var unionStart: Double
        var unionEnd: Double
        var candidates: [String: Candidate]   // locale.identifier(.bcp47) -> candidate
        var timeoutTask: Task<Void, Never>?
    }

    private struct EmittedRegion {
        let unionStart: Double
        let unionEnd: Double
    }

    private let nLocales: Int
    private let timeoutSeconds: Double
    private let onEmit: @Sendable (Candidate) async -> Void
    private var pendings: [PendingRegion] = []
    /// Audio-range regions that have already been emitted. A late-arriving candidate
    /// that overlaps one of these is dropped to prevent double output. Pruned by
    /// audio range (see `recentlyEmittedPruneBoundary`), not wall clock, so a slow
    /// transcriber that lags the fast one by seconds still hits this guard.
    private var recentlyEmitted: [EmittedRegion] = []
    /// Defensive cap on `recentlyEmitted`. The boundary-based prune only advances
    /// once every locale has contributed a valid-timing chunk, so a misconfigured
    /// bidi run where one of the configured locales is never actually spoken
    /// (transcriber never finalizes anything usable) would otherwise let the list
    /// grow without bound. On overflow we sort and drop the oldest entries by
    /// `unionEnd`; a very-late candidate for one of those dropped utterances could
    /// then double-emit, but the user has long since moved past it. ~1024 entries
    /// at ~6 utterances/minute is roughly three hours of normal speech before the
    /// cap kicks in, which means well-configured runs never hit it.
    private let recentlyEmittedCap = 1024
    /// Latest `audioStart` observed per locale (BCP-47 identifier → max start).
    /// Pruning recentlyEmitted by the *current* candidate's start was unsafe in
    /// multi-source mode: a faster transcriber could advance far enough that
    /// already-emitted regions were dropped before the slower locale caught up,
    /// letting its late candidate for an earlier utterance create a fresh region
    /// and double-emit. Tracking per-locale progress lets us drop a region only
    /// after every locale has moved past it.
    private var lastSeenStart: [String: Double] = [:]
    private var finished = false

    init(
        nLocales: Int,
        timeoutSeconds: Double = 0.3,
        onEmit: @escaping @Sendable (Candidate) async -> Void
    ) {
        precondition(nLocales >= 1)
        self.nLocales = nLocales
        self.timeoutSeconds = timeoutSeconds
        self.onEmit = onEmit
    }

    /// Submit a finalized candidate from one source-locale transcriber. The actor
    /// decides whether it merges into an existing pending region, opens a new one,
    /// or short-circuits straight to emission (n=1 or invalid timing).
    func receive(_ candidate: Candidate) async {
        if finished { return }

        // Single-source: nothing to reconcile, emit synchronously.
        if nLocales == 1 {
            await onEmit(candidate)
            return
        }

        guard let start = candidate.timing.audioStart,
              let end = candidate.timing.audioEnd,
              end > start else {
            // No timing → can't overlap-match, so this candidate also can't ride
            // the recentlyEmitted dedup. Emitting it anyway would let the same
            // utterance double-emit if another locale produced a valid range for
            // it. SpeechTranscriber returns invalid / open-ended ranges only on
            // degenerate inputs in practice, so dropping the candidate is the
            // right tradeoff for the multi-source "never emits twice" guarantee.
            return
        }

        // Track the locale's latest start, then prune recentlyEmitted only past
        // the slowest locale's progress (`recentlyEmittedPruneBoundary`). A
        // per-candidate boundary would drop entries before a lagging locale's
        // late candidate could match them, letting the late candidate form a
        // fresh region and double-emit.
        let locKey = candidate.locale.identifier(.bcp47)
        lastSeenStart[locKey] = Swift.max(lastSeenStart[locKey] ?? 0, start)
        let bound = recentlyEmittedPruneBoundary()
        recentlyEmitted.removeAll { $0.unionEnd <= bound }

        // A candidate overlapping a recently-emitted region was already represented
        // by an earlier winner; drop to prevent double output.
        if recentlyEmitted.contains(where: { overlaps(aStart: $0.unionStart, aEnd: $0.unionEnd, bStart: start, bEnd: end) }) {
            return
        }

        let overlappingIdxs = pendings.indices.filter { i in
            overlaps(aStart: pendings[i].unionStart, aEnd: pendings[i].unionEnd, bStart: start, bEnd: end)
        }

        if let primary = overlappingIdxs.first {
            // Fold every other overlapping pending into the primary. A bridging
            // candidate that spans two near-adjacent regions (each opened earlier
            // by a different locale that did not yet overlap) would otherwise
            // leave the secondary regions stranded; their timers fire later and
            // are dropped by the emitWinner check, taking any high-confidence
            // candidates they held down with them. Merging here keeps the best
            // candidate per locale across all overlapping regions.
            for j in overlappingIdxs.dropFirst().reversed() {
                let other = pendings[j]
                other.timeoutTask?.cancel()
                for (key, c) in other.candidates {
                    if let existing = pendings[primary].candidates[key] {
                        if (c.confidence?.mean ?? 0) > (existing.confidence?.mean ?? 0) {
                            pendings[primary].candidates[key] = c
                        }
                    } else {
                        pendings[primary].candidates[key] = c
                    }
                }
                pendings[primary].unionStart = Swift.min(pendings[primary].unionStart, other.unionStart)
                pendings[primary].unionEnd = Swift.max(pendings[primary].unionEnd, other.unionEnd)
                pendings.remove(at: j)
            }

            // Same locale arriving twice (e.g. two short fragments from one transcriber
            // overlapping one chunk from the other) keeps the higher-mean one. The
            // alternative — replacing unconditionally — would discard a high-confidence
            // first fragment in favour of a noisy continuation.
            let key = candidate.locale.identifier(.bcp47)
            if let existing = pendings[primary].candidates[key] {
                let existingMean = existing.confidence?.mean ?? 0
                let newMean = candidate.confidence?.mean ?? 0
                if newMean > existingMean {
                    pendings[primary].candidates[key] = candidate
                }
            } else {
                pendings[primary].candidates[key] = candidate
            }
            pendings[primary].unionStart = Swift.min(pendings[primary].unionStart, start)
            pendings[primary].unionEnd = Swift.max(pendings[primary].unionEnd, end)

            if pendings[primary].candidates.count >= nLocales {
                let region = pendings.remove(at: primary)
                region.timeoutTask?.cancel()
                await emitWinner(from: region)
            }
        } else {
            // First candidate for a new region. Schedule a one-shot timeout.
            let id = UUID()
            var region = PendingRegion(
                id: id,
                unionStart: start,
                unionEnd: end,
                candidates: [candidate.locale.identifier(.bcp47): candidate],
                timeoutTask: nil
            )
            let timeoutSeconds = self.timeoutSeconds
            region.timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                if Task.isCancelled { return }
                await self?.fireTimeout(id: id)
            }
            pendings.append(region)
        }
    }

    /// Cancel all timers and emit whatever has been collected so far. Called by the
    /// channel teardown path so a pending region never strands its candidate after
    /// the transcribers have finished.
    func finish() async {
        if finished { return }
        finished = true
        let remaining = pendings
        pendings.removeAll()
        for region in remaining {
            region.timeoutTask?.cancel()
            await emitWinner(from: region)
        }
    }

    // MARK: - Internals

    private func fireTimeout(id: UUID) async {
        if finished { return }
        guard let idx = pendings.firstIndex(where: { $0.id == id }) else { return }
        let region = pendings.remove(at: idx)
        await emitWinner(from: region)
    }

    private func emitWinner(from region: PendingRegion) async {
        // Skip if this region's audio range was already represented by an earlier
        // emission. The receive-time check only protects against late-arriving
        // candidates; two pendings can each survive `receive` (non-overlapping at
        // creation) and then have one expand via a bridging candidate to absorb
        // the other's range before the laggard's timer fires. Without this second
        // check the laggard would double-emit. Use the same per-locale safe
        // boundary as receive so a slow transcriber's late candidate still finds
        // its earlier region in recentlyEmitted instead of being treated as new.
        let bound = recentlyEmittedPruneBoundary()
        recentlyEmitted.removeAll { $0.unionEnd <= bound }
        if recentlyEmitted.contains(where: { overlaps(aStart: $0.unionStart, aEnd: $0.unionEnd, bStart: region.unionStart, bEnd: region.unionEnd) }) {
            return
        }

        guard let winner = region.candidates.values.max(by: {
            ($0.confidence?.mean ?? 0) < ($1.confidence?.mean ?? 0)
        }) else { return }

        // Remember this emission so a stray late candidate for the same utterance
        // is dropped instead of creating a new region.
        recentlyEmitted.append(EmittedRegion(
            unionStart: region.unionStart,
            unionEnd: region.unionEnd
        ))
        // Apply the defensive cap. In a healthy run the boundary prune above
        // already keeps recentlyEmitted small, so this overflow path stays
        // dormant; only triggers in misconfigured bidi where one locale never
        // contributes a valid-timing finalized chunk.
        if recentlyEmitted.count > recentlyEmittedCap {
            recentlyEmitted.sort { $0.unionEnd < $1.unionEnd }
            recentlyEmitted.removeFirst(recentlyEmitted.count - recentlyEmittedCap)
        }

        await onEmit(winner)
    }

    /// Safe boundary for pruning `recentlyEmitted`. Returns the smallest
    /// `audioStart` any locale has reported so far; an emitted region with
    /// `unionEnd <= boundary` can no longer overlap any future candidate from
    /// any locale (each transcriber moves monotonically forward), so it is safe
    /// to drop. Returns 0 until every locale has contributed at least one
    /// valid-timing candidate, because a locale we have not seen yet might
    /// still send a chunk for an earlier audio range.
    private func recentlyEmittedPruneBoundary() -> Double {
        guard lastSeenStart.count >= nLocales else { return 0 }
        return lastSeenStart.values.min() ?? 0
    }

    private func overlaps(aStart: Double, aEnd: Double, bStart: Double, bEnd: Double) -> Bool {
        let ovStart = Swift.max(aStart, bStart)
        let ovEnd = Swift.min(aEnd, bEnd)
        let ov = ovEnd - ovStart
        guard ov > 0 else { return false }
        let aLen = aEnd - aStart
        let bLen = bEnd - bStart
        let shorter = Swift.min(aLen, bLen)
        guard shorter > 0 else { return false }
        return ov / shorter > 0.5
    }
}

/// Per-channel hybrid leaderboard for partial (volatile) transcripts in multi-source
/// mode. Each locale's transcriber yields its own stream of partial fragments while
/// it is still recognizing; without arbitration the renderer's per-channel live
/// region would flip between locales mid-utterance and read as flicker. The gate
/// sits between `drainTranscriberResults` and the renderer and decides which
/// fragment to show:
///
///   1. **Sticky winner**: prefer the locale that won the most recent finalized
///      utterance on this channel. Speech tends to stay in one language for
///      several utterances in a row, so this stays stable across them.
///   2. **Override**: if another locale's latest volatile mean confidence beats
///      the sticky winner's by `overrideThreshold` (default 0.15), switch to it.
///      This catches a real language switch without flipping on close scores.
///   3. **Staleness**: drop scores older than `staleThreshold` so a transcriber
///      that went quiet does not strand the live region with old text.
///
/// `nLocales == 1` short-circuits straight to the renderer so single-source mode
/// keeps its existing zero-overhead path.
actor VolatileGate {
    private struct Score {
        let text: String
        let mean: Double
        let receivedAt: Date
    }
    private let channel: AudioChannel
    private let renderer: any Renderer
    /// Exposed as nonisolated so callers can skip work (e.g. aggregateConfidence)
    /// when the gate is going to ignore it. `nLocales` is immutable after init.
    nonisolated let nLocales: Int
    private let overrideThreshold: Double
    private let staleThreshold: TimeInterval
    private var scores: [String: Score] = [:]
    private var sticky: String?

    init(
        channel: AudioChannel,
        renderer: any Renderer,
        nLocales: Int,
        overrideThreshold: Double = 0.15,
        staleThreshold: TimeInterval = 1.0
    ) {
        self.channel = channel
        self.renderer = renderer
        self.nLocales = nLocales
        self.overrideThreshold = overrideThreshold
        self.staleThreshold = staleThreshold
    }

    /// Record a partial fragment from one source locale and forward the currently
    /// preferred fragment (per the sticky / override / staleness rules above) to
    /// the renderer's live region.
    func update(locale: Locale, text: String, mean: Double) async {
        if nLocales == 1 {
            await renderer.handle(.volatile(channel: channel, text: text))
            return
        }
        let key = locale.identifier(.bcp47)
        let now = Date()
        scores[key] = Score(text: text, mean: mean, receivedAt: now)
        // Rebuild the table rather than mutate-while-iterating; Swift's Dictionary
        // traps with "Dictionary mutated while being enumerated" if we both walk
        // and remove from the same instance, and this runs on every volatile
        // partial in multi-locale mode (hot path).
        scores = scores.filter { _, v in now.timeIntervalSince(v.receivedAt) <= staleThreshold }
        guard let chosen = pickLeader() else { return }
        await renderer.handle(.volatile(channel: channel, text: chosen.text))
    }

    /// Record which locale won the latest finalized utterance. Called from the
    /// reconciler's emit path so the next utterance's sticky preference matches
    /// the speaker's most recently confirmed language.
    func setStickyWinner(_ locale: String) {
        sticky = locale
        // Drop the accumulated leaderboard so the next utterance starts on a
        // clean slate; the sticky alone seeds the next decision until new
        // volatiles populate the table.
        scores.removeAll()
    }

    private func pickLeader() -> Score? {
        if let sticky, let stickyScore = scores[sticky] {
            let bestOther = scores
                .filter { $0.key != sticky }
                .values
                .max(by: { $0.mean < $1.mean })
            if let bestOther, bestOther.mean - stickyScore.mean > overrideThreshold {
                return bestOther
            }
            return stickyScore
        }
        // No sticky yet, or the sticky's most recent score aged out of the
        // table; pick by raw mean among whatever is current.
        return scores.values.max(by: { $0.mean < $1.mean })
    }
}

/// End-to-end pipeline that orchestrates one or more audio channels.
///
/// For each enabled channel:
///   AudioSource -> AVAudioConverter -> SpeechTranscriber -> finalized chunk
///                                                       -> TranslationSession
///                                                       -> Renderer
///
/// Mic and Speaker run concurrently in a TaskGroup but share one renderer + one seq counter,
/// so the output order reflects which channel finalized first.
struct Pipeline {
    /// One or more source locales. When the list has more than one entry, every
    /// channel runs a SpeechTranscriber per locale in parallel and the
    /// `ChunkReconciler` picks one winner per utterance via overlap-based matching
    /// (see ChunkReconciler for the algorithm).
    let sourceLocales: [Locale]
    /// Target locales for translation, position-paired with `sourceLocales`. nil
    /// → transcribe only. When provided, length must match `sourceLocales` (Listen
    /// validates this), so the per-utterance routing `srcLocales[i] → dstLocales[i]`
    /// is a direct array lookup.
    let targetLocales: [Locale]?
    let renderer: any Renderer
    let enableMic: Bool
    let enableSpeaker: Bool
    let voiceProcessing: Bool  // apply AEC + NR + AGC on mic input
    let micDeviceID: AudioDeviceID?  // nil = follow system default input
    let speakerDeviceUID: String?    // nil = follow system default output
    /// When set, transcribe this file instead of mic / speaker. Mic and speaker flags
    /// are ignored in this mode (Listen.swift's validation rejects the combination so
    /// they're never both true here).
    let inputURL: URL?
    /// Lets callers (notably the SIGINT handler in Listen.swift) stop every active
    /// audio source without having to wait for `run()` to unwind on its own.
    let stops: StopRegistry = StopRegistry()

    func run() async throws {
        let counter = SeqCounter()

        // Resolve models once, before any channel starts. Both channels share the
        // source-locale list, so doing this here (instead of per-channel) avoids a
        // double download and lets us emit a single progress line per locale. The
        // speech asset can be fetched headlessly; the translation model cannot, so
        // we fail fast with install instructions rather than letting every chunk
        // surface a failure.
        for locale in sourceLocales {
            try await ensureSpeechAsset(locale: locale)
        }
        // Listen.parseLocaleList already rejects duplicate --src entries at the
        // CLI boundary, but pin the invariant here so a future caller (a test,
        // an embedding) gets a clear crash instead of subtle misrouting:
        // ChunkReconciler's candidate dictionary, `lastSeenStart`, the
        // dstLangByLocale map, and the translation lanes table are all keyed by
        // `identifier(.bcp47)`, so a duplicate would silently collapse two
        // configured pairs into one and break dedup / routing.
        precondition(
            Set(sourceLocales.map { $0.identifier(.bcp47) }).count == sourceLocales.count,
            "Pipeline requires sourceLocales to be unique by BCP-47 identifier; Listen.parseLocaleList enforces this at the CLI boundary."
        )
        if let targetLocales {
            // Listen.parseLocaleList already rejects unequal --src / --dst lengths
            // at the CLI boundary, but pin the invariant here so a future caller
            // that bypasses Listen (a test, an embedding) gets a clear crash
            // instead of a silently truncated `zip` that skips validation for
            // some pairs and later traps on `targetLocales[i]` out of bounds.
            precondition(
                sourceLocales.count == targetLocales.count,
                "Pipeline requires sourceLocales.count == targetLocales.count; Listen.parseLocaleList enforces this at the CLI boundary."
            )
            for i in sourceLocales.indices {
                try await ensureTranslationModel(source: sourceLocales[i], target: targetLocales[i])
            }
        }

        // File mode runs a single channel with its own timeline origin at 0, so audio
        // offsets in the JSONL line up with the file's playback position. Live mode
        // shares one host-time origin between the mic and speaker channels.
        if let inputURL {
            try await runFileChannel(inputURL: inputURL, counter: counter, sessionStart: 0)
            await renderer.handle(.eof)
            await renderer.flush()
            return
        }

        // Shared origin for both channels' audio offsets, on the same host-time clock the
        // captured buffers carry. Taken after model resolution (a first-run download must
        // not push the first subtitle far into the session) and before any capture, so the
        // resampler can align each channel's analyzer timeline to this one instant.
        let sessionStart = hostTimeNowSeconds()

        try await withThrowingTaskGroup(of: Void.self) { group in
            if enableMic {
                group.addTask {
                    try await self.runChannel(channel: .mic, counter: counter, sessionStart: sessionStart)
                }
            }
            if enableSpeaker {
                group.addTask {
                    try await self.runChannel(channel: .speaker, counter: counter, sessionStart: sessionStart)
                }
            }
            for try await _ in group {}
        }

        await renderer.handle(.eof)
        await renderer.flush()
    }

    /// Stop every registered audio source. Idempotent. Use this to halt the mic and
    /// speaker captures before the SIGINT handler blocks on an interactive prompt.
    func cancel() async {
        await stops.stopAll()
    }

    // MARK: - Per-channel

    /// Per source-locale stack: one transcriber + analyzer + analyzer-input stream.
    /// Audio fans out from one resampler to every entry's `inputBuilder`. The
    /// transcribers run independently; their finalized chunks meet at the
    /// `ChunkReconciler` which picks the winning locale per utterance.
    private struct PerLocale {
        let locale: Locale
        let transcriber: SpeechTranscriber
        let analyzer: SpeechAnalyzer
        let inputSeq: AsyncStream<AnalyzerInput>
        let inputBuilder: AsyncStream<AnalyzerInput>.Continuation
    }

    private func makeTranscriberStack(for locale: Locale) -> SpeechTranscriber {
        // `.fastResults` biases the transcriber toward a shorter context window so
        // both volatile and finalized chunks arrive with lower latency. Apple
        // documents an accuracy trade-off but it is acceptable here: the live
        // region is a preview that gets replaced by the finalized line, and the
        // finalized line still benefits from the lower latency. This pair of
        // options (volatileResults + fastResults) is what
        // `SpeechTranscriber.Preset.timeIndexedProgressiveTranscription` would
        // give us; we spell it out explicitly to keep the trade-off readable.
        // Request per-run transcription confidence alongside the time range. It is
        // aggregated per chunk (mean + min) and emitted under `src.confidence`. Note
        // the value is acoustic per-character confidence, not word correctness, but
        // for multi-source auto-detect mode the mean is also the primary signal
        // ChunkReconciler uses to pick a winner across locales.
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
    }

    private func runChannel(
        channel: AudioChannel,
        counter: SeqCounter,
        sessionStart: Double
    ) async throws {
        let willTranslate = targetLocales != nil

        // One transcriber + analyzer + input stream per source locale. With a single
        // locale this collapses to one entry and the ChunkReconciler fast-paths
        // straight through, so the auto-detect machinery costs nothing in that case.
        var perLocale: [PerLocale] = []
        for src in sourceLocales {
            let t = makeTranscriberStack(for: src)
            let a = SpeechAnalyzer(modules: [t])
            let (seq, builder) = AsyncStream<AnalyzerInput>.makeStream()
            perLocale.append(PerLocale(locale: src, transcriber: t, analyzer: a, inputSeq: seq, inputBuilder: builder))
        }

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: perLocale.map { $0.transcriber }) else {
            throw VoError.noCompatibleAudioFormat
        }

        // Start audio capture and the resampler BEFORE warming the analyzer so
        // any speech the user produces during the ANE compile window lands in
        // the inputBuilder buffers instead of being lost. Without this ordering
        // the ~1.5 s `prepareToAnalyze` would silently drop the first words of
        // a session.
        //
        // An unpinned channel follows the system default device: if the default
        // changes mid-session, the capture is rebuilt on the new default and keeps
        // feeding the same analyzers, so the session continues instead of stopping.
        // A pinned (--select-device) channel installs no device-change listener, so
        // makeCapture below runs exactly once.
        let rebind = RebindBox()

        @Sendable func makeCapture() async throws -> AsyncStream<TimedBuffer> {
            // Route device-loss stopping through the box so stop runs exactly once even
            // when a device-change event (main queue) races shutdown (stop registry): the
            // box hands the stopper to whichever path takes it first, the other gets nil.
            // This also avoids capturing cap, so onDeviceLost cannot retain-cycle it.
            let onLost: @Sendable () -> Void = { [weak rebind] in
                guard let stop = rebind?.requestRebindAndTakeStopper() else { return }
                Task { await stop() }
            }
            switch channel {
            case .mic:
                let cap = MicCapture(voiceProcessing: voiceProcessing, deviceID: micDeviceID)
                cap.onDeviceLost = onLost
                try cap.start()
                // If shutdown already started, stop the capture we just built rather
                // than registering it (the box would otherwise hold a running capture).
                if !rebind.setCurrent({ cap.stop() }) { cap.stop() }
                return cap.stream
            case .speaker:
                let cap = SpeakerCapture(outputDeviceUID: speakerDeviceUID)
                cap.onDeviceLost = onLost
                try await cap.start()
                if !rebind.setCurrent({ await cap.stop() }) { await cap.stop() }
                return cap.stream
            case .file:
                // runFileChannel is the file-mode entry; runChannel is never called with .file.
                fatalError("runChannel does not handle .file; use runFileChannel")
            }
        }

        // The box always stops whichever capture is currently active, across rebinds.
        let stopper: () async -> Void = { await rebind.stopCurrent() }

        // First capture; a failure here propagates as a normal start error.
        let firstStream = try await makeCapture()

        // Register the per-channel stopper so a SIGINT-triggered cancel() halts
        // capture before any save prompt blocks the main task.
        await stops.register(AsyncStopper(action: stopper))

        let inputBuilders = perLocale.map { $0.inputBuilder }
        let resampler = makeResampler(
            channel: channel,
            sessionStart: sessionStart,
            analyzerFormat: analyzerFormat,
            firstStream: firstStream,
            rebind: rebind,
            inputBuilders: inputBuilders,
            makeCapture: makeCapture
        )

        // Warm each model / ANE concurrently — both with the now-flowing capture
        // and with each other across locales — so the first finalized chunk
        // comes back in ~1.45 s instead of ~2.2 s and adding source locales does
        // not multiply startup latency by ANE compile time. If any prepare/start
        // throws, the resampler we just spawned would be orphaned, so cancel it
        // explicitly before propagating.
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for p in perLocale {
                    group.addTask {
                        try await p.analyzer.prepareToAnalyze(in: analyzerFormat)
                        try await p.analyzer.start(inputSequence: p.inputSeq)
                    }
                }
                try await group.waitForAll()
            }
        } catch {
            resampler.cancel()
            for b in inputBuilders { b.finish() }
            await stopper()
            throw error
        }

        // One translator + chunk pipe per (src → dst) pair. Built up-front and held as
        // `let` so the reconciler's @Sendable onEmit closure can capture without a
        // mutable-var diagnostic. Keyed by source-locale BCP-47 so the reconciler's
        // winner routes in O(1).
        let lanes: [String: TranslationLane] = makeTranslationLanes()
        let dstLangByLocale: [String: String] = {
            guard let targetLocales else { return [:] }
            var m: [String: String] = [:]
            for (i, src) in sourceLocales.enumerated() {
                m[src.identifier(.bcp47)] = targetLocales[i].identifier(.bcp47)
            }
            return m
        }()

        let volatileGate = VolatileGate(channel: channel, renderer: renderer, nLocales: sourceLocales.count)

        // Reconciler: receives finalized candidates from every per-locale transcriber,
        // picks a winner per utterance, and assigns the renderer's monotonic `seq` at
        // emission time so renderer source-order commit stays unaffected by reconciliation.
        // It also nudges the VolatileGate's sticky preference toward the winner so the
        // next utterance's live region defaults to the same language unless a
        // competing locale clearly outscores it.
        let rendererRef = renderer
        let reconciler = ChunkReconciler(nLocales: sourceLocales.count) { winner in
            let seq = await counter.next()
            let srcLang = winner.locale.identifier(.bcp47)
            let dstLang = dstLangByLocale[srcLang]
            await rendererRef.handle(.finalized(
                channel: channel,
                seq: seq,
                source: winner.text,
                timing: winner.timing,
                confidence: winner.confidence,
                srcLangOverride: srcLang,
                dstLangOverride: dstLang
            ))
            if willTranslate, let lane = lanes[srcLang] {
                lane.builder.yield((seq, winner.text))
            }
            await volatileGate.setStickyWinner(srcLang)
        }

        // Drain each transcriber's results concurrently. Volatile updates go through
        // the gate (per-channel arbitration across locales); finalized chunks go to
        // the reconciler with a wall-clock-now timestamp.
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for p in perLocale {
                    group.addTask {
                        try await self.drainTranscriberResults(
                            channel: channel,
                            transcriber: p.transcriber,
                            locale: p.locale,
                            reconciler: reconciler,
                            volatileGate: volatileGate,
                            timestampFor: { _ in Date() }
                        )
                    }
                }
                try await group.waitForAll()
            }
        } catch {
            resampler.cancel()
            for b in inputBuilders { b.finish() }
            // Drain pending reconciler winners BEFORE closing the lanes, mirroring
            // the success-path order below. emitWinner's onEmit yields into
            // lane.builder; once the builder is finished those yields are silently
            // dropped, leaving the renderer's commitQueue holding an untranslated
            // pair the error path then has no way to satisfy.
            await reconciler.finish()
            for lane in lanes.values { lane.builder.finish() }
            for lane in lanes.values { lane.translator.cancel() }
            await stopper()
            throw error
        }

        resampler.cancel()
        await stopper()
        await reconciler.finish()
        for lane in lanes.values { lane.builder.finish() }
        for lane in lanes.values { await lane.translator.value }
    }

    /// One translator + matching chunk-feeder per (src → dst) pair, keyed by the
    /// source locale's BCP-47 identifier. Empty when `targetLocales` is nil
    /// (transcribe-only). Built once per channel call so the lookup table stays
    /// immutable and captures cleanly into the reconciler's Sendable closure.
    private struct TranslationLane: Sendable {
        let translator: Task<Void, Never>
        let builder: AsyncStream<(Int, String)>.Continuation
    }

    private func makeTranslationLanes() -> [String: TranslationLane] {
        guard let targetLocales else { return [:] }
        var m: [String: TranslationLane] = [:]
        for (i, src) in sourceLocales.enumerated() {
            let dst = targetLocales[i]
            let (chunkSeq, builder) = AsyncStream<(Int, String)>.makeStream()
            let translator = makeTranslator(source: src, target: dst, chunkSeq: chunkSeq)
            m[src.identifier(.bcp47)] = TranslationLane(translator: translator, builder: builder)
        }
        return m
    }

    /// Resample + device-follow task: pull from the active capture, convert to the
    /// analyzer format, and push into the SpeechAnalyzer input. When the capture's
    /// stream ends because the default device changed, rebuild on the new default
    /// and keep feeding the same input. Buffers accumulate in `inputBuilder` while
    /// the analyzer warms up; it drains them once `start(inputSequence:)` connects.
    private func makeResampler(
        channel: AudioChannel,
        sessionStart: Double,
        analyzerFormat: AVAudioFormat,
        firstStream: AsyncStream<TimedBuffer>,
        rebind: RebindBox,
        inputBuilders: [AsyncStream<AnalyzerInput>.Continuation],
        makeCapture: @escaping @Sendable () async throws -> AsyncStream<TimedBuffer>
    ) -> Task<Void, Never> {
        Task.detached {
            var stream = firstStream
            // Host time up to which audio (real plus bridging silence) has been fed to the
            // analyzer. nil until the first buffer, when sessionStart is the baseline so
            // analyzer time 0 maps onto it. Keeps the analyzer's sample timeline aligned
            // with the shared host-time axis.
            var fedEndHostTime: Double? = nil
            while true {
                for await timed in stream {
                    let reference = fedEndHostTime ?? sessionStart
                    // Clamp to the fed marker so it stays monotonic. A buffer that fell back
                    // to `hostTimeNowSeconds()` (callback time) can report a host time later
                    // than the next buffer's valid platform timestamp; without the clamp that
                    // next buffer would push the marker backwards and the iteration after it
                    // would inject spurious silence and drift the timeline. With all-valid
                    // timestamps h is already >= reference, so this is a no-op there.
                    let h = max(timed.hostTime, reference)
                    // Bridge the span since the last fed audio with silence so the analyzer
                    // timeline tracks host time. The initial offset from sessionStart, a
                    // device-rebind reopen gap, and a hole left by a failed convert all
                    // collapse to "fill [fedEnd, h) with silence". A near-zero span rounds
                    // to no samples and is skipped, so a contiguous stream injects nothing.
                    // Each analyzer needs its own AnalyzerInput so they iterate the same
                    // PCM buffer independently.
                    if let silence = makeSilentBuffer(seconds: h - reference, format: analyzerFormat) {
                        for b in inputBuilders { b.yield(AnalyzerInput(buffer: silence)) }
                    }
                    // Advance the fed position past h only by audio actually fed. If the
                    // convert fails, the hole stays open and the next buffer bridges it with
                    // silence above, rather than silently shifting later offsets. The
                    // pre-conversion duration in seconds is resampling-invariant, so it is
                    // the right amount to advance this host-time marker by.
                    if let converted = convertBuffer(timed.buffer, to: analyzerFormat) {
                        for b in inputBuilders { b.yield(AnalyzerInput(buffer: converted)) }
                        fedEndHostTime = h + Double(timed.buffer.frameLength) / timed.buffer.format.sampleRate
                    } else {
                        fedEndHostTime = h
                    }
                }
                // A cancelled task is shutting down, so do not start a new capture even
                // if a device-change request raced in. shouldRebind alone is not enough:
                // the catch-path cleanup calls resampler.cancel() before the box is
                // marked stopped, leaving a window where shouldRebind would still be true.
                guard !Task.isCancelled, rebind.shouldRebind() else { break }
                // The new stream's first buffer bridges the reopen gap from
                // fedEndHostTime automatically, so no extra state is needed here.
                guard let reopened = await reopenCapture(channel: channel, makeCapture: makeCapture) else { break }
                stream = reopened
            }
            for b in inputBuilders { b.finish() }
        }
    }

    /// Translation worker for one (src → dst) locale pair. The caller spawns one of
    /// these per pair in the source-locale list and routes each finalized chunk's
    /// text to the worker matching the winning locale.
    ///
    /// Same-language pair (e.g. `--src ja-JP --dst ja-JP`, useful when one direction
    /// of a bidirectional setup should pass through untranslated) bypasses the
    /// TranslationSession entirely and echoes source text as target. The Translation
    /// framework rejects identity pairs as unsupported, so we must not call it.
    ///
    /// TranslationSession is non-Sendable so we create it inside the Task closure.
    private func makeTranslator(source: Locale, target: Locale, chunkSeq: AsyncStream<(Int, String)>) -> Task<Void, Never> {
        let renderer = renderer
        if isSameLanguage(source, target) {
            return Task {
                for await (seq, text) in chunkSeq {
                    await renderer.handle(.translated(seq: seq, target: text))
                }
            }
        }
        let sourceLang = source.language
        let targetLang = target.language
        return Task {
            let box = SendableTranslationSession(inner: TranslationSession(installedSource: sourceLang, target: targetLang))
            // run() already verified the pair via ensureTranslationModel (it throws
            // otherwise), so warm the model now to keep the first chunk's translation
            // off the lazy on-demand loading path. A warm-up failure is non-fatal (the
            // per-chunk translate path still surfaces real errors), but a cancellation
            // means shutdown started, so bail instead of entering the chunk loop.
            do {
                try await box.inner.prepareTranslation()
            } catch is CancellationError {
                return
            } catch {}
            // Fan out per-chunk translate calls so a slow translate doesn't block
            // later chunks. Bounded by translateConcurrency: when the in-flight
            // count hits the cap, we await one child via group.next() before adding
            // the next. StreamRenderer.commitQueue is seq-ordered, so out-of-order
            // .translated events still render in order.
            await withTaskGroup(of: Void.self) { group in
                var inFlight = 0
                for await (seq, text) in chunkSeq {
                    if inFlight >= translateConcurrency {
                        await group.next()
                        inFlight -= 1
                    }
                    group.addTask {
                        do {
                            let response = try await box.inner.translate(text)
                            await renderer.handle(.translated(seq: seq, target: response.targetText))
                        } catch {
                            await renderer.handle(.translated(seq: seq, target: "[translation failed: \(error.localizedDescription)]"))
                        }
                    }
                    inFlight += 1
                }
            }
        }
    }

    /// Drain one transcriber's result stream. Volatile previews go through the
    /// per-channel `VolatileGate` (which arbitrates between locales so the live
    /// region does not flicker); finalized chunks become candidates fed to the
    /// per-channel `ChunkReconciler`, which picks one winner per utterance across
    /// every source-locale transcriber sharing the channel.
    ///
    /// `timestampFor` returns the wall-clock instant a finalized chunk represents.
    /// Live mode passes `_ in Date()` (now); file mode passes
    /// `audioStart in localEpoch + audioStart` so timestamp tracks the file's own timeline.
    private func drainTranscriberResults(
        channel: AudioChannel,
        transcriber: SpeechTranscriber,
        locale: Locale,
        reconciler: ChunkReconciler,
        volatileGate: VolatileGate,
        timestampFor: @Sendable (Double?) -> Date
    ) async throws {
        for try await result in transcriber.results {
            // SpeechTranscriber emits every chunk after the first with a leading
            // space (stream-concatenation artifact). Trim so TTY columns stay
            // aligned and the space doesn't leak into JSONL or translation input.
            let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            if result.isFinal {
                // Whitespace-only finals carry no content; skip them so they
                // don't burn a seq or emit blank lines.
                guard !text.isEmpty else { continue }
                // The resampler has already aligned this channel's analyzer timeline to
                // the shared session axis (silence padding at the start and across
                // rebinds), so the range is the offset directly. A CMTime can be valid
                // yet infinite/indefinite (open-ended ranges); its `.seconds` is then
                // non-finite. Leave the offset nil in that case so `audio` is omitted
                // rather than backfilled with an approximation, mirroring how a nil
                // confidence is dropped rather than zero-filled. A consumer that needs
                // a timecode for every chunk (e.g. an SRT writer) reconstructs the
                // missing one from `timestamp` and neighbours.
                func sessionSeconds(_ t: CMTime) -> Double? {
                    guard t.isValid else { return nil }
                    let s = t.seconds
                    return s.isFinite ? s : nil
                }
                let audioStart = sessionSeconds(result.range.start)
                let audioEnd = sessionSeconds(result.range.end)
                let timing = ChunkTiming(
                    timestamp: timestampFor(audioStart),
                    audioStart: audioStart,
                    audioEnd: audioEnd
                )
                let confidence = aggregateConfidence(result.text)
                await reconciler.receive(ChunkReconciler.Candidate(
                    locale: locale,
                    text: text,
                    timing: timing,
                    confidence: confidence
                ))
            } else {
                // Volatile partials may not always carry transcriptionConfidence
                // (the attribute is requested but Apple does not guarantee per-run
                // values mid-recognition); a nil aggregate falls back to mean 0 so
                // the gate at worst degrades to "first arrival wins" without
                // crashing the leaderboard comparison. Skip the aggregation
                // entirely in single-source mode where the gate ignores the value
                // (volatile partials are a ~50/sec hot path on live capture).
                let mean: Double = volatileGate.nLocales > 1
                    ? (aggregateConfidence(result.text)?.mean ?? 0)
                    : 0
                await volatileGate.update(locale: locale, text: text, mean: mean)
            }
        }
    }

    // MARK: - File channel

    /// Drive the same SpeechTranscriber + TranslationSession pipeline from an on-disk
    /// audio file rather than a live capture. Differences from runChannel:
    ///   - single source, no device-follow / RebindBox machinery
    ///   - sessionStart is 0, so audio offsets in JSONL line up with the file's playback
    ///     position (the first buffer's hostTime is also 0; the resampler injects no
    ///     leading silence)
    ///   - end-to-end backpressure via pull-based `FileSource.nextBuffer()` plus a
    ///     `BoundedAnalyzerInputBuffer`. A push stream would let memory grow with file
    ///     duration when the disk feeds audio faster than the analyzer drains it.
    ///   - the analyzer's input naturally finishes when the file hits EOF, which closes
    ///     transcriber.results and lets this function return without external cancel.
    ///     A mid-stream read failure surfaces as a thrown VoError.inputFileReadFailed
    ///     via `try await resampler.value` at the end, instead of the silent truncation
    ///     a `break`-on-error feeder would produce.
    private func runFileChannel(
        inputURL: URL,
        counter: SeqCounter,
        sessionStart: Double
    ) async throws {
        let willTranslate = targetLocales != nil

        // One transcriber + analyzer + bounded input buffer per source locale, same
        // as runChannel but with BoundedAnalyzerInputBuffer instead of AsyncStream so
        // file reads are paced end-to-end by the slowest analyzer's drain rate.
        struct PerLocaleFile {
            let locale: Locale
            let transcriber: SpeechTranscriber
            let analyzer: SpeechAnalyzer
            let inputBuffer: BoundedAnalyzerInputBuffer
        }
        var perLocale: [PerLocaleFile] = []
        for src in sourceLocales {
            let t = makeTranscriberStack(for: src)
            let a = SpeechAnalyzer(modules: [t])
            // Capacity 8 is enough to absorb short producer / consumer rate mismatches
            // without ever holding more than a fraction of a second of PCM in memory:
            // 4096 frames per chunk × 8 ≈ 32 K frames, ~0.67 s at the typical 48 kHz
            // analyzer format and well under 1 MB for any mono / stereo float32 input.
            perLocale.append(PerLocaleFile(locale: src, transcriber: t, analyzer: a, inputBuffer: BoundedAnalyzerInputBuffer(capacity: 8)))
        }

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: perLocale.map { $0.transcriber }) else {
            throw VoError.noCompatibleAudioFormat
        }

        let source: FileSource
        do {
            source = try FileSource(url: inputURL)
        } catch {
            throw VoError.inputFileOpenFailed(url: inputURL, underlying: error)
        }

        // Register the stopper before any read so a SIGINT that races startup still
        // halts the feeder (StopRegistry invokes stoppers inline once stopAll has run).
        let stopper: () async -> Void = { source.stop() }
        await stops.register(AsyncStopper(action: stopper))

        let inputBuffers = perLocale.map { $0.inputBuffer }

        // Resampler: pull one buffer at a time from the file, bridge gaps with silence
        // exactly like runChannel does for live capture, and send into every bounded
        // input. `send` suspends when any buffer is full, so file reads are paced by
        // the slowest analyzer's drain rate end-to-end. A read failure rethrows as
        // VoError.inputFileReadFailed; the success path closes the buffer cleanly so
        // the analyzers' results streams drain and exit.
        let resampler: Task<Void, Error> = Task.detached { [inputURL] in
            var fedEndHostTime: Double? = nil
            while !Task.isCancelled {
                let timed: TimedBuffer?
                do {
                    timed = try source.nextBuffer()
                } catch {
                    for buf in inputBuffers { await buf.finish() }
                    throw VoError.inputFileReadFailed(url: inputURL, underlying: error)
                }
                guard let timed else { break }
                let reference = fedEndHostTime ?? sessionStart
                let h = max(timed.hostTime, reference)
                if let silence = makeSilentBuffer(seconds: h - reference, format: analyzerFormat) {
                    for buf in inputBuffers { await buf.send(AnalyzerInput(buffer: silence)) }
                }
                if let converted = convertBuffer(timed.buffer, to: analyzerFormat) {
                    for buf in inputBuffers { await buf.send(AnalyzerInput(buffer: converted)) }
                    fedEndHostTime = h + Double(timed.buffer.frameLength) / timed.buffer.format.sampleRate
                } else {
                    fedEndHostTime = h
                }
            }
            for buf in inputBuffers { await buf.finish() }
        }

        // Same parallel warm-up as runChannel: prepareToAnalyze + start fan out
        // across locales so multi-source file mode does not multiply startup
        // latency by ANE compile time per locale.
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for p in perLocale {
                    group.addTask {
                        try await p.analyzer.prepareToAnalyze(in: analyzerFormat)
                        try await p.analyzer.start(inputSequence: p.inputBuffer)
                    }
                }
                try await group.waitForAll()
            }
        } catch {
            resampler.cancel()
            for buf in inputBuffers { await buf.finish() }
            await stopper()
            throw error
        }

        let lanes: [String: TranslationLane] = makeTranslationLanes()
        let dstLangByLocale: [String: String] = {
            guard let targetLocales else { return [:] }
            var m: [String: String] = [:]
            for (i, src) in sourceLocales.enumerated() {
                m[src.identifier(.bcp47)] = targetLocales[i].identifier(.bcp47)
            }
            return m
        }()

        // In file mode, anchor timestamp to a "local-TZ epoch" (wall-clock
        // 1970-01-01T00:00:00 in the renderer's local timezone) plus
        // audio.start, so timestamp and audio.* are two views of the same
        // file position rather than two independent axes. ISO8601 with
        // local TZ then prints "1970-01-01T00:00:0X.XXX±HH:MM". Compute
        // the anchor by asking Calendar for the UTC instant whose local
        // clock reads 1970-01-01T00:00:00 in the captured TZ. Reusing
        // `secondsFromGMT(for: Date(timeIntervalSince1970: 0))` would
        // mix the offset at the Unix epoch instant with a different
        // anchor instant, which can disagree under historical/DST rules
        // and shift the rendered date away from 1970-01-01. The Calendar
        // round-trip stays consistent against the same TZ database the
        // formatter uses. Computed once outside the loop so a mid-run TZ
        // change cannot drift the anchor.
        let localEpoch: Date = {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = .current
            return cal.date(from: DateComponents(year: 1970, month: 1, day: 1)) ?? Date(timeIntervalSince1970: 0)
        }()

        let volatileGate = VolatileGate(channel: .file, renderer: renderer, nLocales: sourceLocales.count)

        let rendererRef = renderer
        let reconciler = ChunkReconciler(nLocales: sourceLocales.count) { winner in
            let seq = await counter.next()
            let srcLang = winner.locale.identifier(.bcp47)
            let dstLang = dstLangByLocale[srcLang]
            await rendererRef.handle(.finalized(
                channel: .file,
                seq: seq,
                source: winner.text,
                timing: winner.timing,
                confidence: winner.confidence,
                srcLangOverride: srcLang,
                dstLangOverride: dstLang
            ))
            if willTranslate, let lane = lanes[srcLang] {
                lane.builder.yield((seq, winner.text))
            }
            await volatileGate.setStickyWinner(srcLang)
        }

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for p in perLocale {
                    group.addTask {
                        try await self.drainTranscriberResults(
                            channel: .file,
                            transcriber: p.transcriber,
                            locale: p.locale,
                            reconciler: reconciler,
                            volatileGate: volatileGate,
                            // A missing audio.start (invalid range) falls back to the
                            // same anchor as audio.start = 0 (the local-TZ epoch),
                            // not Unix epoch 00:00Z.
                            timestampFor: { audioStart in localEpoch.addingTimeInterval(audioStart ?? 0) }
                        )
                    }
                }
                try await group.waitForAll()
            }
        } catch {
            resampler.cancel()
            // Close the bounded buffers so a resampler suspended in `send` (buffer
            // full at the moment the drain threw) is unblocked. Without this, cancel
            // alone leaves the CheckedContinuation unresumed and the resampler task
            // strands, leaking its frame and the buffered AVAudioPCMBuffers.
            for buf in inputBuffers { await buf.finish() }
            // Drain pending reconciler winners BEFORE closing the lanes, mirroring
            // the success-path order below. emitWinner's onEmit yields into
            // lane.builder; once the builder is finished those yields are silently
            // dropped, leaving the renderer's commitQueue holding an untranslated
            // pair the error path then has no way to satisfy.
            await reconciler.finish()
            for lane in lanes.values { lane.builder.finish() }
            for lane in lanes.values { lane.translator.cancel() }
            await stopper()
            throw error
        }

        await stopper()
        await reconciler.finish()
        for lane in lanes.values { lane.builder.finish() }
        for lane in lanes.values { await lane.translator.value }
        // The analyzer's results finished because the resampler closed the input
        // buffers. If the close was preceded by a read failure, that failure is still
        // pending on the resampler's value; rethrow it here so a corrupt / truncated
        // file does not surface as a clean exit.
        try await resampler.value
    }

    // MARK: - Helpers

    private func ensureSpeechAsset(locale: Locale) async throws {
        let supportedIDs = (await SpeechTranscriber.supportedLocales).map { $0.identifier(.bcp47) }
        let isSupported = supportedIDs.contains(locale.identifier(.bcp47))
        guard isSupported else {
            throw VoError.unsupportedSpeechLocale(locale, supported: supportedIDs)
        }

        let installed = await SpeechTranscriber.installedLocales
        let isInstalled = installed.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
        guard !isInstalled else { return }

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange]
        )
        guard let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else { return }
        // Unlike the Translation framework, the speech asset downloads headlessly.
        // Announce it only once a real request exists, so the first run's blocking
        // wait doesn't look like a hang without claiming a download that isn't happening.
        emitProgress("Downloading speech model for \(locale.identifier(.bcp47))… (first run only)")
        try await req.downloadAndInstall()
    }

    /// Verify the translation model for this pair is installed. The Translation
    /// framework only downloads via a UI confirmation sheet, which a CLI cannot
    /// present, so an uninstalled pair would otherwise fail silently on every
    /// chunk. Fail fast with install instructions instead.
    ///
    /// Same-language pairs (e.g. `ja-JP → ja-JP` in a bidi setup) are a no-op
    /// passthrough handled in `makeTranslator`; `LanguageAvailability.status`
    /// reports them as `.unsupported`, which would otherwise abort startup.
    private func ensureTranslationModel(source: Locale, target: Locale) async throws {
        if isSameLanguage(source, target) { return }
        let status = await LanguageAvailability().status(from: source.language, to: target.language)
        switch status {
        case .installed:
            return
        case .supported:
            throw VoError.translationModelNotInstalled(source: source, target: target)
        case .unsupported:
            throw VoError.unsupportedTranslationPair(source: source, target: target)
        @unknown default:
            // A status we don't recognize is not a confirmed install, so fail fast
            // rather than letting an unverified pair reach the per-chunk translate path.
            throw VoError.translationModelNotInstalled(source: source, target: target)
        }
    }
}

/// Write a one-line status to stderr. Stays off stdout so it never corrupts the
/// JSONL stream a downstream reader may be consuming.
/// How many times a channel tries to reopen its capture after the default device changed
/// before it gives up and ends. With the backoff below this spans roughly ten minutes,
/// which covers a headset that stays busy for a good part of a meeting while still
/// terminating rather than retrying forever.
let maxReopenAttempts = 120
private let reopenBackoffBase = Duration.milliseconds(250)
private let reopenBackoffCap = Duration.seconds(5)

/// Delay before reopen attempt `attempt`, counted from 0 for the attempt that runs as soon
/// as the device change is seen. Doubles per failure up to `reopenBackoffCap`, so a device
/// that comes back immediately is picked up immediately, and one that is contended (a
/// conferencing app holding the headset profile) is not hammered for minutes.
func reopenBackoffDelay(attempt: Int) -> Duration {
    guard attempt > 0 else { return .zero }
    // Cap the shift before it is applied, not the product: 1 << 120 is undefined,
    // and the capped delay is reached long before the exponent gets large anyway.
    let doublings = min(attempt - 1, 16)
    let delay = reopenBackoffBase * (1 << doublings)
    return min(delay, reopenBackoffCap)
}

/// Rebuild a channel's capture on the new default device, retrying while the device
/// refuses to open. A Bluetooth profile switch leaves the device unopenable (or reporting
/// a format that would make the tap install fail) for seconds at a time, and giving up on
/// the first refusal silently drops that channel for the rest of the session while vo
/// still looks healthy. Returns nil when the channel should end.
private func reopenCapture(
    channel: AudioChannel,
    makeCapture: @escaping @Sendable () async throws -> AsyncStream<TimedBuffer>
) async -> AsyncStream<TimedBuffer>? {
    var lastError: Error?
    for attempt in 0..<maxReopenAttempts {
        let delay = reopenBackoffDelay(attempt: attempt)
        if delay > .zero {
            do { try await Task.sleep(for: delay) } catch { return nil }
        }
        if Task.isCancelled { return nil }
        do {
            let stream = try await makeCapture()
            if attempt == 0 {
                emitProgress("vo: the \(channel.deviceDescription) changed. Following the new default.")
            } else {
                emitProgress("vo: the \(channel.deviceDescription) is back. Following the new default.")
            }
            return stream
        } catch is CancellationError {
            return nil
        } catch {
            // One notice per outage, not per attempt, so a long retry streak does not
            // bury the transcript's own stderr output.
            if attempt == 0 {
                emitProgress("vo: the \(channel.deviceDescription) changed but the new default could not be opened yet. Retrying…")
            }
            lastError = error
        }
    }
    let reason = lastError.map { " (\($0.localizedDescription))" } ?? ""
    emitProgress("vo: the \(channel.deviceDescription) could not be reopened after \(maxReopenAttempts) attempts\(reason). Stopping this channel.")
    return nil
}

private func emitProgress(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Aggregate a finalized chunk's per-run `transcriptionConfidence` into a
/// length-weighted mean and the minimum run value, rounded to three decimals.
/// Returns nil when no run carried a confidence value. Runs split per character for
/// CJK text, so weighting by run length keeps multi-character (e.g. English word)
/// runs from being under-counted relative to single-character ones.
private func aggregateConfidence(_ text: AttributedString) -> ChunkConfidence? {
    var weightedSum = 0.0
    var weight = 0
    var lowest = Double.greatestFiniteMagnitude
    for run in text.runs {
        guard let c = run.transcriptionConfidence else { continue }
        let n = text[run.range].characters.count
        weightedSum += c * Double(n)
        weight += n
        lowest = Swift.min(lowest, c)
    }
    guard weight > 0 else { return nil }
    let round3 = { (x: Double) in (x * 1000).rounded() / 1000 }
    return ChunkConfidence(mean: round3(weightedSum / Double(weight)), min: round3(lowest))
}

/// Two locales share the same underlying language. Used to detect the passthrough
/// case in bidi setups (e.g. `--src en-US,ja-JP --dst ja-JP,ja-JP` where the second
/// pair is `ja-JP → ja-JP`, meaning leave the source untranslated). Compares the
/// language code only, so `ja-JP` / `ja` / `ja-Hira-JP` all match.
private func isSameLanguage(_ a: Locale, _ b: Locale) -> Bool {
    guard let lhs = a.language.languageCode, let rhs = b.language.languageCode else { return false }
    return lhs == rhs
}

/// Current host time in seconds on the mach timebase, matching the `hostTime` that captured
/// buffers carry. Serves as the shared session origin for both channels' audio offsets, and
/// as the capture layer's fallback when a platform buffer timestamp is invalid.
func hostTimeNowSeconds() -> Double {
    AVAudioTime.seconds(forHostTime: mach_absolute_time())
}

/// Build `seconds` of silence in `format`, used to bridge a device-rebind reopen gap (and
/// the initial offset from sessionStart) so the analyzer's sample timeline stays aligned
/// with host time (the shared session axis).
/// Returns nil for a non-positive, non-finite, or unrepresentable duration, in which case
/// the caller skips that span and leaves the timeline unadjusted for it.
private func makeSilentBuffer(seconds: Double, format: AVAudioFormat) -> AVAudioPCMBuffer? {
    guard seconds > 0, seconds.isFinite else { return nil }
    let frameCount = (seconds * format.sampleRate).rounded()
    guard frameCount >= 1, frameCount <= Double(AVAudioFrameCount.max) else { return nil }
    let frames = AVAudioFrameCount(frameCount)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
    buffer.frameLength = frames
    // AVAudioPCMBuffer does not document its allocation as zero-filled, so make the
    // silence explicit by zeroing every channel's backing store up to frameLength.
    for channel in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
        if let data = channel.mData {
            memset(data, 0, Int(channel.mDataByteSize))
        }
    }
    return buffer
}

/// Convert one PCM buffer to the analyzer's preferred format. Handles sample-rate conversion.
private func convertBuffer(_ source: AVAudioPCMBuffer, to dstFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
    let srcFormat = source.format
    if srcFormat == dstFormat {
        return source
    }
    guard let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else { return nil }

    let ratio = dstFormat.sampleRate / srcFormat.sampleRate
    let outCapacity = AVAudioFrameCount(Double(source.frameLength) * ratio + 1024)
    guard let dst = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: outCapacity) else { return nil }

    final class State: @unchecked Sendable { var consumed = false }
    let state = State()
    var error: NSError?
    converter.convert(to: dst, error: &error) { _, status in
        if state.consumed {
            status.pointee = .endOfStream
            return nil
        }
        state.consumed = true
        status.pointee = .haveData
        return source
    }
    return error == nil ? dst : nil
}

enum VoError: Error, CustomStringConvertible {
    case noCompatibleAudioFormat
    case unsupportedSpeechLocale(Locale, supported: [String])
    case translationModelNotInstalled(source: Locale, target: Locale)
    case unsupportedTranslationPair(source: Locale, target: Locale)
    case inputFileOpenFailed(url: URL, underlying: Error)
    case inputFileReadFailed(url: URL, underlying: Error)
    case audioDeviceNotReady(channel: AudioChannel, format: String)
    case audioTapInstallFailed(channel: AudioChannel, underlying: Error)

    var description: String {
        switch self {
        case .noCompatibleAudioFormat:
            return "No audio format compatible with SpeechTranscriber is available on this device."

        case .audioDeviceNotReady(let channel, let format):
            return """
            The \(channel.deviceDescription) is not ready yet (it reports \(format)).
            It is probably still switching format, which Bluetooth headsets do when they
            move between their playback and headset profiles. Retry in a moment.
            """

        case .audioTapInstallFailed(let channel, let underlying):
            return "Could not start capturing from the \(channel.deviceDescription): \(underlying.localizedDescription)"

        case .inputFileOpenFailed(let url, let underlying):
            let path = url.isFileURL ? url.path : url.absoluteString
            return "Could not open input file \(path): \(underlying.localizedDescription)"

        case .inputFileReadFailed(let url, let underlying):
            let path = url.isFileURL ? url.path : url.absoluteString
            return "Read failure on input file \(path) (the file may be corrupt or truncated, or the volume may have disconnected): \(underlying.localizedDescription)"

        case .translationModelNotInstalled(let s, let t):
            return """
            Translation model for \(s.identifier(.bcp47)) → \(t.identifier(.bcp47)) is not installed.
            macOS does not allow downloading it from a CLI, so install it once via
            System Settings > General > Language & Region > Translation Languages, then re-run.
            (Run `vo --doctor` to see translation languages available on this device.)
            """

        case .unsupportedTranslationPair(let s, let t):
            return """
            Translation from \(s.identifier(.bcp47)) to \(t.identifier(.bcp47)) is not supported on this device.
            Run `vo --doctor` to see available translation languages.
            """

        case .unsupportedSpeechLocale(let l, let supported):
            let id = l.identifier(.bcp47)
            let langCode = l.language.languageCode?.identifier ?? ""
            let nearby = supported
                .filter { $0.hasPrefix(langCode + "-") }
                .sorted()
            if !nearby.isEmpty {
                return """
                SpeechTranscriber does not support locale \(id). Try one of these regional variants:
                  \(nearby.joined(separator: ", "))
                """
            }
            return """
            SpeechTranscriber does not support locale \(id). Run `vo --doctor` to see all supported locales.
            """
        }
    }
}
