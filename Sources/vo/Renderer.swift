import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Wall-clock + audio-stream timing metadata attached to a finalized chunk.
struct ChunkTiming: Sendable {
    /// Wall-clock instant the chunk represents. For live channels (.mic / .spk)
    /// this is when the pipeline received the finalized result. For .file (vo
    /// --input) it is anchored to the file's own timeline (local-TZ
    /// 1970-01-01T00:00:00 + audio.start), so two runs of the same file in the
    /// same local timezone produce the same value.
    let timestamp: Date
    /// Start offset (seconds) on the shared session timeline, whose origin is common to
    /// mic + speaker. Nil when the transcriber range was invalid/non-finite.
    let audioStart: Double?
    /// End offset (seconds) on the shared session timeline. Nil when unavailable.
    let audioEnd: Double?
}

/// Aggregated transcription confidence for a finalized chunk. `mean` is weighted by
/// run length, `min` is the worst run. A chunk with no per-run confidence is carried
/// as a nil `ChunkConfidence`, never as zeros.
struct ChunkConfidence: Sendable {
    let mean: Double
    let min: Double
}

/// Events fed into Renderer from the pipeline.
///
/// `srcLangOverride` / `dstLangOverride` exist for multi-source (auto-detect)
/// mode, where each finalized chunk's locale is decided per-utterance rather
/// than fixed by the renderer's constructor. Single-locale callers leave them
/// nil and the renderer's `sourceLang` / `targetLang` defaults apply.
enum RenderEvent: Sendable {
    case volatile(channel: AudioChannel, text: String)
    case finalized(channel: AudioChannel, seq: Int, source: String, timing: ChunkTiming, confidence: ChunkConfidence?, srcLangOverride: String? = nil, dstLangOverride: String? = nil)
    case translated(seq: Int, target: String)
    case eof
}

protocol Renderer: Sendable {
    func handle(_ event: RenderEvent) async
    func flush() async
}

/// Renderer that keeps source order strict and supports multiple audio channels.
///
/// Algorithm overview:
///   - A FIFO commitQueue holds (seq, channel, source, translation?) pairs in arrival order.
///   - Translations may arrive out of order; we buffer them on the matching pair
///     but only commit (= print to scrollback) starting from the queue head, while
///     the head pair's translation is already filled in.
///   - Each channel keeps its own volatile text in the live region at the bottom.
///
/// TTY mode redraws the live region in place using ANSI cursor control. Non-TTY
/// (piped) mode emits one JSON line per committed pair and ignores volatile updates.
actor StreamRenderer: Renderer {
    struct Pair {
        let seq: Int
        let channel: AudioChannel
        let source: String
        let timing: ChunkTiming
        let confidence: ChunkConfidence?
        /// Per-chunk source-locale override (multi-source auto-detect mode). nil
        /// means fall back to the renderer's constructor-time `sourceLang`.
        let srcLangOverride: String?
        /// Per-chunk target-locale override. nil → renderer's `targetLang`.
        let dstLangOverride: String?
        var target: String?
    }

    private let mode: Mode
    private let out: FileHandle
    private let sourceLang: String
    private let targetLang: String
    private let translationEnabled: Bool
    private let showChannelLabel: Bool
    private let sourceColumnPad: String
    private let logSink: SessionLog?
    private let summarizer: Summarizer?
    private let isSummaryView: Bool
    private var appendTask: Task<Void, Never>?

    private var commitQueue: [Pair] = []
    private var volatileTexts: [AudioChannel: String] = [:]
    private var liveRegionLines: Int = 0   // how many lines we currently own at the bottom
    private var finalizedCount: Int = 0    // total utterances finalized (for exit summary)
    private var isShuttingDown: Bool = false

    /// Total utterances finalized so far (across all channels).
    var utteranceCount: Int { finalizedCount }

    enum Mode {
        case tty
        case jsonl
    }

    init(
        mode: Mode,
        sourceLang: String,
        targetLang: String,
        translationEnabled: Bool = true,
        showChannelLabel: Bool = true,
        out: FileHandle = .standardOutput,
        logSink: SessionLog? = nil,
        summarizer: Summarizer? = nil,
        isSummaryView: Bool = false
    ) {
        self.mode = mode
        self.out = out
        self.sourceLang = sourceLang
        self.targetLang = targetLang
        self.translationEnabled = translationEnabled
        self.showChannelLabel = showChannelLabel
        // With label: "HH:MM:SS" (8) + " " (1) + "[mic]" (5) + "  " (2) = 16.
        // Without:    "HH:MM:SS" (8) + "   " (3)                        = 11.
        self.sourceColumnPad = String(repeating: " ", count: showChannelLabel ? 16 : 11)
        self.logSink = logSink
        self.summarizer = summarizer
        self.isSummaryView = isSummaryView
    }

    func handle(_ event: RenderEvent) async {
        if isShuttingDown { return }
        switch event {
        case .volatile(let channel, let text):
            if isSummaryView { return }
            volatileTexts[channel] = text
            if mode == .tty { redrawLiveRegion() }

        case .finalized(let channel, let seq, let source, let timing, let confidence, let srcLangOverride, let dstLangOverride):
            volatileTexts[channel] = ""
            finalizedCount += 1
            if translationEnabled {
                commitQueue.append(Pair(seq: seq, channel: channel, source: source, timing: timing, confidence: confidence, srcLangOverride: srcLangOverride, dstLangOverride: dstLangOverride, target: nil))
                // Drain before redrawing. drainCommitQueue clears the live region
                // as a side effect, so the reverse order would blank the pending
                // "(translating…)" lines until the next event arrives.
                drainCommitQueue()
                if mode == .tty && !isSummaryView { redrawLiveRegion() }
            } else {
                // No translation: commit immediately, source-only.
                if mode == .tty && !isSummaryView { clearLiveRegion() }
                emitSourceOnly(channel: channel, seq: seq, source: source, timing: timing, confidence: confidence, srcLangOverride: srcLangOverride)
                if mode == .tty && !isSummaryView { redrawLiveRegion() }
            }

        case .translated(let seq, let target):
            if let idx = commitQueue.firstIndex(where: { $0.seq == seq }) {
                commitQueue[idx].target = target
            }
            drainCommitQueue()
            if mode == .tty && !isSummaryView { redrawLiveRegion() }

        case .eof:
            drainCommitQueue(forceUntranslated: true)
            if mode == .tty && !isSummaryView {
                clearLiveRegion()
            }
            // After eof, ignore any straggler events so audio threads can't redraw
            // over the exit prompt/summary that follows.
            isShuttingDown = true
        }
    }

    func flush() async {
        _ = await appendTask?.result
        try? out.synchronize()
    }

    // MARK: - Commit

    private func drainCommitQueue(forceUntranslated: Bool = false) {
        guard !commitQueue.isEmpty else { return }
        if mode == .tty && !isSummaryView { clearLiveRegion() }

        while let head = commitQueue.first {
            if let target = head.target {
                emitCommittedPair(pair: head, target: target)
                commitQueue.removeFirst()
            } else if forceUntranslated {
                emitCommittedPair(pair: head, target: nil)
                commitQueue.removeFirst()
            } else {
                break
            }
        }
    }

    /// Display initial notification when summary mode is active.
    func renderInitialSummaryView() {
        guard isSummaryView, mode == .tty else { return }
        writeLine("\u{001B}[38;5;244m(Real-time summary enabled. Summary chunks will be appended as audio progresses...)\u{001B}[0m\n")
    }

    /// Append a newly generated summary chunk to the terminal.
    func appendSummaryChunk(_ chunk: Summarizer.ChunkSummary) {
        guard isSummaryView, mode == .tty else { return }
        var header = "\u{001B}[1;36m"
        if !chunk.startTime.isEmpty && !chunk.endTime.isEmpty {
            header += "[\(chunk.startTime) - \(chunk.endTime)]"
        } else {
            header += "[Summary]"
        }
        header += "\u{001B}[0m \u{001B}[38;5;244mPart \(chunk.index + 1) (\(chunk.utteranceCount) utterances)\u{001B}[0m"

        writeLine(header)
        writeLine(chunk.summaryText + "\n")
    }

    private func feedSummarizer(channel: AudioChannel, timestamp: Date, source: String, target: String?) {
        guard let summarizer else { return }
        let combined: String
        if let target, !target.isEmpty && target != source {
            combined = "\(source) (\(target))"
        } else {
            combined = source
        }
        let timeStr = StreamRenderer.ttyTime.string(from: timestamp)
        let channelName: String
        switch channel {
        case .mic:     channelName = "mic"
        case .speaker: channelName = "speaker"
        case .file:    channelName = "file"
        }
        let line = Summarizer.TranscriptLine(
            timestamp: timeStr,
            channel: channelName,
            text: combined
        )
        // Maintain strict arrival order across asynchronous appends
        appendTask = Task { [previous = appendTask] in
            _ = await previous?.result
            await summarizer.append(line)
        }
    }

    private func emitSourceOnly(channel: AudioChannel, seq: Int, source: String, timing: ChunkTiming, confidence: ChunkConfidence?, srcLangOverride: String?) {
        // Skip the JSONSerialization unless someone is going to consume it. In TTY
        // mode with no transcript sink (e.g. `vo < /dev/null` where stdout is a TTY
        // but stdin isn't, so SessionLog is never opened) the serialized bytes
        // would just be thrown away.
        let jsonl: String? = (mode == .jsonl || logSink != nil)
            ? buildJSONL(seq: seq, channel: channel, source: source, target: nil, timing: timing, confidence: confidence, includeTarget: false, srcLangOverride: srcLangOverride, dstLangOverride: nil)
            : nil

        if let jsonl { logSink?.append(jsonl) }
        feedSummarizer(channel: channel, timestamp: timing.timestamp, source: source, target: nil)

        if isSummaryView {
            return
        }

        switch mode {
        case .tty:
            writeLine("\(ttyHeader(timing.timestamp, channel))\(source)")
        case .jsonl:
            if let jsonl { writeLine(jsonl) }
        }
    }

    private func emitCommittedPair(pair: Pair, target: String?) {
        let jsonl: String? = (mode == .jsonl || logSink != nil)
            ? buildJSONL(seq: pair.seq, channel: pair.channel, source: pair.source, target: target, timing: pair.timing, confidence: pair.confidence, includeTarget: translationEnabled, srcLangOverride: pair.srcLangOverride, dstLangOverride: pair.dstLangOverride)
            : nil

        if let jsonl { logSink?.append(jsonl) }
        feedSummarizer(channel: pair.channel, timestamp: pair.timing.timestamp, source: pair.source, target: target)

        if isSummaryView {
            return
        }

        switch mode {
        case .tty:
            writeLine("\(ttyHeader(pair.timing.timestamp, pair.channel))\(pair.source)")
            if let target {
                // Skip the translation line in TTY when the (src → dst) is a
                // passthrough: same language on both sides and identical text.
                // Compare language subtags so this matches Pipeline.isSameLanguage,
                // which decides upstream passthrough by language code only.
                // Otherwise --src ja-JP --dst ja (same language, different region)
                // would be a passthrough in the translator (text echoed) but the
                // TTY would still print the redundant line. JSONL still emits the
                // redundant `dst` because downstream readers may rely on the
                // schema being uniform across chunks.
                let srcLang = pair.srcLangOverride ?? self.sourceLang
                let dstLang = pair.dstLangOverride ?? self.targetLang
                let isPassthrough = sameLanguageSubtag(srcLang, dstLang) && target == pair.source
                if !isPassthrough {
                    writeLine("\(sourceColumnPad)\u{001B}[38;5;244m\(target)\u{001B}[0m")
                }
            } else {
                writeLine("\(sourceColumnPad)\u{001B}[38;5;240m(no translation)\u{001B}[0m")
            }
        case .jsonl:
            if let jsonl { writeLine(jsonl) }
        }
    }

    /// True when two BCP-47 strings name the same primary language regardless of
    /// region or script (e.g. `ja-JP` matches `ja`). Used to decide TTY passthrough
    /// suppression consistently with `Pipeline.isSameLanguage`. Returns false when
    /// either side has no parseable language subtag, so a malformed identifier
    /// never suppresses output silently.
    private func sameLanguageSubtag(_ a: String, _ b: String) -> Bool {
        let aCode = Locale(identifier: a).language.languageCode?.identifier
        let bCode = Locale(identifier: b).language.languageCode?.identifier
        guard let aCode, let bCode else { return false }
        return aCode == bCode
    }

    private func buildJSONL(
        seq: Int,
        channel: AudioChannel,
        source: String,
        target: String?,
        timing: ChunkTiming,
        confidence: ChunkConfidence?,
        includeTarget: Bool,
        srcLangOverride: String?,
        dstLangOverride: String?
    ) -> String? {
        var obj: [String: Any] = jsonlBase(seq: seq, channel: channel, timing: timing)
        let srcLang = srcLangOverride ?? self.sourceLang
        let dstLang = dstLangOverride ?? self.targetLang
        var srcObj: [String: Any] = ["lang": srcLang, "text": source]
        if let confidence {
            srcObj["confidence"] = [
                "mean": StreamRenderer.decimal3(confidence.mean),
                "min": StreamRenderer.decimal3(confidence.min),
            ]
        }
        obj["src"] = srcObj
        if includeTarget {
            obj["dst"] = target.map { ["lang": dstLang, "text": $0] }
                ?? ["lang": dstLang, "text": NSNull()]
        }
        return jsonString(obj)
    }

    // MARK: - TTY formatting helpers

    /// Pad to where [mic]/[spk] starts on volatile lines (no timestamp). Only used
    /// when channel labels are shown.
    private static let channelColumnPad = String(repeating: " ", count: 9)

    /// 256-color palette code for the given channel. Shared by the timestamp and
    /// the [mic]/[spk] label so the eye reads both as the same channel.
    private func channelColor(_ channel: AudioChannel) -> Int {
        channel.tint256
    }

    private func ttyTimestamp(_ date: Date, channel: AudioChannel) -> String {
        let s = StreamRenderer.ttyTime.string(from: date)
        return "\u{001B}[38;5;\(channelColor(channel))m\(s)\u{001B}[0m"
    }

    private func ttyChannel(_ channel: AudioChannel) -> String {
        let label: String
        switch channel {
        case .mic:     label = "[mic]"
        case .speaker: label = "[spk]"
        case .file:    label = "[file]"
        }
        return "\u{001B}[38;5;\(channelColor(channel))m\(label)\u{001B}[0m"
    }

    /// Build the leading "<timestamp> [mic]  " (or "<timestamp>   " when only one
    /// channel is active and the label is suppressed) segment.
    private func ttyHeader(_ timestamp: Date, _ channel: AudioChannel) -> String {
        showChannelLabel
            ? "\(ttyTimestamp(timestamp, channel: channel)) \(ttyChannel(channel))  "
            : "\(ttyTimestamp(timestamp, channel: channel))   "
    }

    private func jsonlBase(seq: Int, channel: AudioChannel, timing: ChunkTiming) -> [String: Any] {
        var obj: [String: Any] = [
            "seq": seq,
            "channel": channel.rawValue,
            "timestamp": StreamRenderer.iso8601.string(from: timing.timestamp)
        ]
        if let start = timing.audioStart, let end = timing.audioEnd {
            obj["audio"] = [
                "start": StreamRenderer.decimal3(start),
                "end": StreamRenderer.decimal3(end),
            ]
        }
        return obj
    }

    private func jsonString(_ obj: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // JSONSerialization renders a Double at full binary precision, so a value meant to
    // be 0.948 or 21.54 leaks as 0.94799999999999995 / 21.539999999999999. Re-encode it
    // as a base-10 Decimal rounded to three places, which serializes cleanly. Callers
    // must pass a finite value: confidence is 0..1, and audio offsets are
    // finiteness-guarded at the source (Pipeline), so Int(_:) here never traps.
    private static func decimal3(_ x: Double) -> Decimal {
        Decimal(Int((x * 1000).rounded())) / 1000
    }

    // ISO8601DateFormatter's `string(from:)` is documented as thread-safe.
    // Use local timezone so JSONL timestamps match what the user sees in TTY mode.
    // Users who want UTC can override via TZ=UTC.
    nonisolated(unsafe) private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = .current
        return f
    }()

    // 24-hour HH:mm:ss formatter for TTY timestamps, in local timezone.
    private static let ttyTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    // MARK: - TTY live region

    private func redrawLiveRegion() {
        // Pending pairs (translation not yet arrived) plus per-channel volatile lines.
        var lines: [String] = []
        for pair in commitQueue where pair.target == nil {
            lines.append("\(ttyHeader(pair.timing.timestamp, pair.channel))\(pair.source)")
            lines.append("\(sourceColumnPad)\u{001B}[38;5;240m(translating…)\u{001B}[0m")
        }
        for channel in AudioChannel.allCases {
            if let v = volatileTexts[channel], !v.isEmpty {
                // In-progress fragment is rendered in the same dim 244 the
                // translation lines use, so the eye knows it's not committed yet.
                // The "… " leader stays at 240 (darker) so it reads as a leader
                // rather than as the start of the fragment text itself.
                let leader = "\u{001B}[38;5;240m… \u{001B}[0m"
                let body = "\u{001B}[38;5;244m\(v)\u{001B}[0m"
                if showChannelLabel {
                    lines.append("\(Self.channelColumnPad)\(ttyChannel(channel))  \(leader)\(body)")
                } else {
                    lines.append("\(sourceColumnPad)\(leader)\(body)")
                }
            }
        }

        clearLiveRegion()

        // Count *physical* terminal rows so the next clear knows how far to move up.
        // Long source text wraps across multiple rows on narrow terminals.
        let termWidth = terminalWidth()
        var totalRows = 0
        for line in lines {
            writeLine(line)
            totalRows += rowsNeeded(forLine: line, termWidth: termWidth)
        }
        liveRegionLines = totalRows
    }

    private func clearLiveRegion() {
        guard liveRegionLines > 0 else { return }
        var buf = "\r"  // ensure cursor at column 0 before moving up
        for _ in 0..<liveRegionLines {
            buf += "\u{001B}[A"   // up one
            buf += "\u{001B}[2K"  // clear entire line
        }
        write(buf)
        liveRegionLines = 0
    }

    // MARK: - Terminal width and display width

    private func terminalWidth() -> Int {
        var ws = winsize()
        let fd = out.fileDescriptor
        if ioctl(fd, UInt(TIOCGWINSZ), &ws) == 0, ws.ws_col > 0 {
            return Int(ws.ws_col)
        }
        return 80
    }

    /// How many physical terminal rows the given (possibly ANSI-colored) line occupies.
    private func rowsNeeded(forLine line: String, termWidth: Int) -> Int {
        let w = displayWidth(stripANSI(line))
        guard termWidth > 0 else { return 1 }
        return max(1, (w + termWidth - 1) / termWidth)
    }

    /// Strip ANSI CSI escapes (e.g. \e[38;5;208m) for accurate width measurement.
    private func stripANSI(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var i = s.unicodeScalars.startIndex
        let end = s.unicodeScalars.endIndex
        while i < end {
            let c = s.unicodeScalars[i]
            if c == "\u{001B}" {
                let nextIdx = s.unicodeScalars.index(after: i)
                if nextIdx < end && s.unicodeScalars[nextIdx] == "[" {
                    // Skip until a final byte (any letter or @ etc., range 0x40-0x7E).
                    var j = s.unicodeScalars.index(after: nextIdx)
                    while j < end {
                        let ch = s.unicodeScalars[j].value
                        if ch >= 0x40 && ch <= 0x7E { break }
                        j = s.unicodeScalars.index(after: j)
                    }
                    i = (j < end) ? s.unicodeScalars.index(after: j) : end
                    continue
                }
            }
            out.append(c)
            i = s.unicodeScalars.index(after: i)
        }
        return String(out)
    }

    /// Display width counted in monospace cells (East Asian Wide = 2).
    private func displayWidth(_ s: String) -> Int {
        var width = 0
        for scalar in s.unicodeScalars {
            width += isWideScalar(scalar) ? 2 : 1
        }
        return width
    }

    private func isWideScalar(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return (0x1100...0x115F).contains(v)   // Hangul Jamo
            || (0x2E80...0x303E).contains(v)   // CJK Radicals / Kangxi
            || (0x3041...0x33FF).contains(v)   // Hiragana, Katakana, CJK Symbols
            || (0x3400...0x4DBF).contains(v)   // CJK Extension A
            || (0x4E00...0x9FFF).contains(v)   // CJK Unified
            || (0xA000...0xA4CF).contains(v)   // Yi
            || (0xAC00...0xD7A3).contains(v)   // Hangul Syllables
            || (0xF900...0xFAFF).contains(v)   // CJK Compatibility
            || (0xFE30...0xFE4F).contains(v)   // CJK Compatibility Forms
            || (0xFF00...0xFF60).contains(v)   // Fullwidth Forms
            || (0xFFE0...0xFFE6).contains(v)   // Fullwidth signs
            || (0x1F300...0x1F6FF).contains(v) // Emoji misc
            || (0x1F900...0x1F9FF).contains(v) // Emoji extras
    }

    // MARK: - IO

    private func writeLine(_ s: String) { write(s + "\n") }

    private func write(_ s: String) {
        if let data = s.data(using: .utf8) {
            try? out.write(contentsOf: data)
        }
    }
}

/// Decide which mode to use. If `jsonForced` is true, always JSONL; otherwise auto-detect via isatty.
func detectRenderMode(jsonForced: Bool) -> StreamRenderer.Mode {
    if jsonForced { return .jsonl }
    return isatty(fileno(stdout)) != 0 ? .tty : .jsonl
}
