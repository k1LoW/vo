import Foundation
import FoundationModels

/// On-device summarizer using Apple Intelligence Foundation Models (`SystemLanguageModel`).
///
/// Supports real-time rolling / incremental summarization during a live audio session,
/// keeping memory and context window consumption bounded and updating the summary file live.
actor Summarizer {
    let summaryOut: String?
    let customPrompt: String?
    let targetLanguage: String?

    /// Representation of a summarized transcript chunk.
    struct ChunkSummary: Sendable {
        let index: Int
        let startTime: String
        let endTime: String
        let utteranceCount: Int
        let summaryText: String
    }

    private(set) var partialSummaries: [ChunkSummary] = []
    private(set) var finalSummary: String = ""
    private var pendingLines: [TranscriptLine] = []
    private var isUpdating: Bool = false
    private var isFinalizing: Bool = false
    private var updateTask: Task<Void, Never>?
    private var lastUpdateTime: Date = Date()
    private var totalCapturedLines: Int = 0
    private var chunkIndex: Int = 0

    /// Callback invoked when a new chunk summary is produced.
    typealias ChunkHandler = @Sendable (ChunkSummary) async -> Void
    /// Callback invoked to emit a one-line status / warning notice (e.g. to stderr).
    typealias NoticeHandler = @Sendable (String) -> Void
    /// Optional custom responder used in tests to bypass live FoundationModels inference.
    typealias Responder = @Sendable (String) async throws -> String
    private var onAppendChunk: ChunkHandler?
    private let onNotice: NoticeHandler
    private let responder: Responder?
    private var currentBatchFailureCount: Int = 0

    func setOnAppendChunk(_ handler: @escaping ChunkHandler) {
        self.onAppendChunk = handler
    }

    /// Threshold of pending lines before triggering an automatic background summary update.
    private let updateChunkThreshold = 25
    /// Minimum time between background summary updates if there are at least some pending lines.
    private let updateIntervalSeconds: TimeInterval
    /// Maximum attempts on a single chunk batch before skipping it.
    let maxChunkAttempts: Int

    init(
        summaryOut: String? = nil,
        customPrompt: String? = nil,
        targetLanguage: String? = nil,
        updateIntervalSeconds: TimeInterval = 60.0,
        maxChunkAttempts: Int = 2,
        onNotice: @escaping NoticeHandler = { message in
            FileHandle.standardError.write(Data((message + "\n").utf8))
        },
        responder: Responder? = nil
    ) {
        self.summaryOut = summaryOut
        self.customPrompt = customPrompt
        self.targetLanguage = targetLanguage
        self.updateIntervalSeconds = updateIntervalSeconds
        self.maxChunkAttempts = max(1, maxChunkAttempts)
        self.onNotice = onNotice
        self.responder = responder
    }

    /// Extract an English display name for a given locale (e.g. "Japanese" for "ja-JP", "English" for "en-US").
    nonisolated static func languageDisplayName(for locale: Locale) -> String {
        let enLocale = Locale(identifier: "en_US")
        let langCode = locale.language.languageCode?.identifier ?? locale.identifier
        if let name = enLocale.localizedString(forLanguageCode: langCode), !name.isEmpty {
            return name
        }
        return langCode
    }

    /// Query whether Foundation Models / Apple Intelligence is available on this system.
    nonisolated static func availabilityStatus() -> (available: Bool, reason: String?) {
        let availability = SystemLanguageModel.default.availability
        switch availability {
        case .available:
            return (true, nil)
        case .unavailable(let reason):
            let explanation: String
            switch reason {
            case .deviceNotEligible:
                explanation = "Device is not eligible for Apple Intelligence."
            case .appleIntelligenceNotEnabled:
                explanation = "Apple Intelligence is disabled in System Settings."
            case .modelNotReady:
                explanation = "The foundation model is not ready (still downloading or preparing assets)."
            @unknown default:
                explanation = "Foundation model is currently unavailable."
            }
            return (false, explanation)
        }
    }

    /// Check if Foundation Models / Apple Intelligence is available on this system.
    nonisolated static func checkAvailability() throws {
        let status = availabilityStatus()
        if !status.available {
            throw VoError.foundationModelNotAvailable(
                reason: status.reason ?? "Foundation model is currently unavailable."
            )
        }
    }

    /// Single line representation of a transcript item.
    struct TranscriptLine: Sendable {
        let timestamp: String
        let channel: String
        let text: String
    }

    /// Parse transcript entries from JSONL lines produced by SessionLog / StreamRenderer.
    nonisolated static func parseTranscriptLines(fromJSONLLines lines: [String]) -> [TranscriptLine] {
        var results: [TranscriptLine] = []

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else {
                continue
            }

            let channel = (obj["channel"] as? String) ?? ""
            let rawTimestamp = (obj["timestamp"] as? String) ?? ""
            let formattedTime = extractDisplayTime(from: rawTimestamp)

            let srcObj = obj["src"] as? [String: Any]
            let srcText = (srcObj?["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            let dstObj = obj["dst"] as? [String: Any]
            let dstText = (dstObj?["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !srcText.isEmpty else { continue }

            let combinedText: String
            if let dstText, !dstText.isEmpty && dstText != srcText {
                combinedText = "\(srcText) (\(dstText))"
            } else {
                combinedText = srcText
            }

            results.append(TranscriptLine(
                timestamp: formattedTime,
                channel: channel,
                text: combinedText
            ))
        }

        return results
    }

    /// Read and parse transcript lines from a JSONL file on disk.
    nonisolated static func loadTranscriptLines(fromPath path: String) throws -> [TranscriptLine] {
        let content = try String(contentsOfFile: path, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)
        return parseTranscriptLines(fromJSONLLines: lines)
    }

    /// Format transcript lines into a readable dialog block.
    nonisolated static func formatTranscript(_ lines: [TranscriptLine]) -> String {
        return lines.map { line in
            let prefix: String
            if !line.timestamp.isEmpty && !line.channel.isEmpty {
                prefix = "[\(line.timestamp)] [\(line.channel)]"
            } else if !line.channel.isEmpty {
                prefix = "[\(line.channel)]"
            } else if !line.timestamp.isEmpty {
                prefix = "[\(line.timestamp)]"
            } else {
                prefix = "-"
            }
            return "\(prefix) \(line.text)"
        }.joined(separator: "\n")
    }

    // MARK: - Streaming / Real-time API

    /// Feed a new transcript line as it is finalized by the renderer.
    func append(_ line: TranscriptLine) {
        pendingLines.append(line)
        totalCapturedLines += 1
        checkTriggerUpdate()
    }

    /// Total number of transcript lines received so far.
    var utteranceCount: Int {
        totalCapturedLines
    }

    /// Maximum raw characters of unsummarized fallback transcript to inline into the final Reduce prompt.
    private static let maxRemainingFallbackChars = 2000

    /// Finish summarization at session exit, incorporating any remaining pending lines,
    /// synthesizing a unified summary document, and returning the final Markdown.
    func finalize() async throws -> String {
        isFinalizing = true
        while let task = updateTask, isUpdating {
            await task.value
        }

        // When we already have partial summaries OR more pending lines than a single chunk,
        // drain pendingLines in batches of updateChunkThreshold via the Map step first.
        // For a short session (partialSummaries.isEmpty && pendingLines.count <= updateChunkThreshold),
        // skip the intermediate chunk step so we summarize the raw transcript directly in one LLM call.
        var unmappedLines: [TranscriptLine] = []
        if !partialSummaries.isEmpty || pendingLines.count > updateChunkThreshold {
            while !pendingLines.isEmpty {
                let batchCount = min(pendingLines.count, updateChunkThreshold)
                let lines = Array(pendingLines.prefix(batchCount))
                pendingLines.removeFirst(batchCount)
                do {
                    let chunk = try await performChunkSummarize(lines: lines, index: chunkIndex)
                    chunkIndex += 1
                    currentBatchFailureCount = 0
                    partialSummaries.append(chunk)
                    writeInterimSummaryToFileIfNeeded()
                    if let onAppendChunk {
                        await onAppendChunk(chunk)
                    }
                } catch {
                    let nextAttempts = currentBatchFailureCount + 1
                    var chunk: ChunkSummary?
                    if nextAttempts < maxChunkAttempts {
                        chunk = try? await performChunkSummarize(lines: lines, index: chunkIndex)
                    }
                    if let chunk {
                        chunkIndex += 1
                        currentBatchFailureCount = 0
                        partialSummaries.append(chunk)
                        writeInterimSummaryToFileIfNeeded()
                        if let onAppendChunk {
                            await onAppendChunk(chunk)
                        }
                    } else {
                        let reason = singleLine((error as? VoError)?.description ?? error.localizedDescription)
                        onNotice("vo: chunk summary failed (\(reason)). Skipping batch of \(lines.count) utterances.")
                        currentBatchFailureCount = 0
                        // Only retain a failing tail if no partial summaries exist at all so the
                        // session can still attempt a bounded fallback; otherwise drop the poisoned
                        // batch so it cannot take down the final Reduce call.
                        if partialSummaries.isEmpty && pendingLines.isEmpty {
                            unmappedLines.append(contentsOf: lines)
                        }
                    }
                }
            }
        } else {
            unmappedLines = pendingLines
            pendingLines.removeAll()
        }

        if partialSummaries.isEmpty && unmappedLines.isEmpty {
            return "No transcript content was captured to summarize."
        }

        // Now synthesize the final unified summary
        let prompt: String

        if partialSummaries.isEmpty {
            let tail = Self.boundedFallbackLines(from: unmappedLines)
            let formatted = Self.formatTranscript(tail)
            prompt = SummaryPrompts.finalPrompt(
                transcript: formatted,
                isIntermediateSummary: false,
                customPrompt: customPrompt,
                targetLanguage: targetLanguage
            )
        } else if partialSummaries.count == 1 && unmappedLines.isEmpty {
            let single = partialSummaries[0]
            prompt = SummaryPrompts.finalPrompt(
                transcript: single.summaryText,
                isIntermediateSummary: true,
                customPrompt: customPrompt,
                targetLanguage: targetLanguage
            )
        } else {
            var parts = partialSummaries.map { part in
                let timeRange = (!part.startTime.isEmpty && !part.endTime.isEmpty) ? " [\(part.startTime) - \(part.endTime)]" : ""
                return "### Part \(part.index + 1)\(timeRange)\n\(part.summaryText)"
            }
            if !unmappedLines.isEmpty {
                let tail = Self.boundedFallbackLines(from: unmappedLines)
                if !tail.isEmpty {
                    parts.append("### Remaining Transcript\n\(Self.formatTranscript(tail))")
                }
            }
            let combinedParts = parts.joined(separator: "\n\n")

            prompt = SummaryPrompts.finalPrompt(
                transcript: combinedParts,
                isIntermediateSummary: true,
                customPrompt: customPrompt,
                targetLanguage: targetLanguage
            )
        }

        let result = try await performFinalSummarize(prompt: prompt)
        self.finalSummary = result
        try writeFinalSummaryToFile(result)
        return result
    }

    /// Return at most `updateChunkThreshold` trailing lines whose formatted representation fits
    /// within `maxRemainingFallbackChars` so an unsummarized fallback never overflows the
    /// on-device model's context window.
    nonisolated static func boundedFallbackLines(
        from lines: [TranscriptLine],
        maxLines: Int = 25,
        maxChars: Int = maxRemainingFallbackChars
    ) -> [TranscriptLine] {
        guard !lines.isEmpty else { return [] }
        let candidates = lines.suffix(maxLines)
        var selected: [TranscriptLine] = []
        var totalChars = 0

        for line in candidates.reversed() {
            let formattedLine = formatTranscript([line])
            let clampedText: String
            if formattedLine.count > maxChars {
                clampedText = String(line.text.prefix(max(0, maxChars - 32)))
            } else {
                clampedText = line.text
            }
            let effectiveLine = (clampedText == line.text)
                ? line
                : TranscriptLine(timestamp: line.timestamp, channel: line.channel, text: clampedText)
            let cost = formatTranscript([effectiveLine]).count + (selected.isEmpty ? 0 : 1)
            if !selected.isEmpty && totalChars + cost > maxChars {
                break
            }
            selected.append(effectiveLine)
            totalChars += cost
            if totalChars >= maxChars {
                break
            }
        }
        return selected.reversed()
    }

    // MARK: - Background Update Logic

    private func checkTriggerUpdate() {
        guard !isUpdating, !isFinalizing else { return }
        let elapsed = Date().timeIntervalSince(lastUpdateTime)
        if currentBatchFailureCount > 0 {
            if elapsed >= updateIntervalSeconds {
                triggerBackgroundUpdate()
            }
            return
        }
        if pendingLines.count >= updateChunkThreshold || (pendingLines.count >= 10 && elapsed >= updateIntervalSeconds) {
            triggerBackgroundUpdate()
        }
    }

    private func triggerBackgroundUpdate() {
        guard !isUpdating, !isFinalizing, !pendingLines.isEmpty else { return }
        isUpdating = true
        let batchCount = min(pendingLines.count, updateChunkThreshold)
        let linesToSummarize = Array(pendingLines.prefix(batchCount))
        pendingLines.removeFirst(batchCount)

        updateTask = Task {
            await self.runBackgroundUpdate(lines: linesToSummarize)
        }
    }

    private func runBackgroundUpdate(lines: [TranscriptLine]) async {
        var shouldContinue = false
        defer {
            isUpdating = false
            lastUpdateTime = Date()
            // If more lines accumulated while updating and the batch was resolved (succeeded or skipped),
            // check if another update is needed for the next batch in the backlog.
            if shouldContinue, !isFinalizing, pendingLines.count >= updateChunkThreshold {
                triggerBackgroundUpdate()
            }
        }

        do {
            let chunk = try await performChunkSummarize(lines: lines, index: chunkIndex)
            chunkIndex += 1
            currentBatchFailureCount = 0
            partialSummaries.append(chunk)
            writeInterimSummaryToFileIfNeeded()
            if let onAppendChunk {
                await onAppendChunk(chunk)
            }
            shouldContinue = true
        } catch {
            currentBatchFailureCount += 1
            if currentBatchFailureCount >= maxChunkAttempts {
                let reason = singleLine((error as? VoError)?.description ?? error.localizedDescription)
                onNotice("vo: chunk summary failed after \(currentBatchFailureCount) attempts (\(reason)). Skipping batch of \(lines.count) utterances.")
                currentBatchFailureCount = 0
                shouldContinue = true
            } else {
                // Re-queue the un-summarized lines at the front for a retry after the backoff interval
                pendingLines.insert(contentsOf: lines, at: 0)
            }
        }
    }

    private func writeInterimSummaryToFileIfNeeded() {
        guard let summaryOut, !partialSummaries.isEmpty else { return }
        let resolved = (summaryOut as NSString).expandingTildeInPath
        let content = partialSummaries.map { part in
            let timeRange = (!part.startTime.isEmpty && !part.endTime.isEmpty) ? " [\(part.startTime) - \(part.endTime)]" : ""
            return "## Part \(part.index + 1)\(timeRange)\n\n\(part.summaryText)"
        }.joined(separator: "\n\n")
        try? content.write(toFile: resolved, atomically: true, encoding: .utf8)
    }

    private func writeFinalSummaryToFile(_ content: String) throws {
        guard let summaryOut, !content.isEmpty else { return }
        let resolved = (summaryOut as NSString).expandingTildeInPath
        do {
            try content.write(toFile: resolved, atomically: true, encoding: .utf8)
        } catch {
            throw VoError.summarizationFailed(reason: "Could not write summary to \(resolved): \(error.localizedDescription)")
        }
    }

    // MARK: - LLM Inference

    private func generateText(prompt: String) async throws -> String {
        if let responder {
            do {
                let content = try await responder(prompt)
                return content.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch let voError as VoError {
                throw voError
            } catch {
                throw VoError.summarizationFailed(reason: error.localizedDescription)
            }
        }

        try Self.checkAvailability()
        let session = LanguageModelSession()
        do {
            let response = try await session.respond(to: prompt)
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let genError as LanguageModelSession.GenerationError {
            throw VoError.summarizationFailed(reason: genError.localizedDescription)
        } catch {
            throw VoError.summarizationFailed(reason: error.localizedDescription)
        }
    }

    private func performFinalSummarize(prompt: String) async throws -> String {
        try await generateText(prompt: prompt)
    }

    /// Generate a concise summary chunk for a set of transcript lines.
    private func performChunkSummarize(lines: [TranscriptLine], index: Int) async throws -> ChunkSummary {
        guard !lines.isEmpty else {
            return ChunkSummary(index: index, startTime: "", endTime: "", utteranceCount: 0, summaryText: "")
        }

        let startTime = lines.first?.timestamp ?? ""
        let endTime = lines.last?.timestamp ?? ""
        let formattedLines = Self.formatTranscript(lines)
        let promptText = SummaryPrompts.chunkPrompt(
            index: index,
            startTimestamp: startTime,
            endTimestamp: endTime,
            chunkText: formattedLines,
            targetLanguage: targetLanguage
        )

        let summaryText = try await generateText(prompt: promptText)
        return ChunkSummary(
            index: index,
            startTime: startTime,
            endTime: endTime,
            utteranceCount: lines.count,
            summaryText: summaryText
        )
    }

    // MARK: - Batch API (for backwards compatibility & tests)

    /// Generate a summary from a batch of transcript lines (e.g. for offline evaluation).
    func summarize(lines: [TranscriptLine]) async throws -> String {
        partialSummaries = []
        finalSummary = ""
        pendingLines = lines
        totalCapturedLines = lines.count
        chunkIndex = 0
        isFinalizing = false

        guard !lines.isEmpty else {
            return "No transcript content was captured to summarize."
        }

        return try await finalize()
    }

    // MARK: - Helper

    nonisolated private static func extractDisplayTime(from isoDateString: String) -> String {
        guard let tIndex = isoDateString.firstIndex(of: "T") else { return "" }
        let afterT = isoDateString[isoDateString.index(after: tIndex)...]
        let timePart = afterT.prefix(8)
        return String(timePart)
    }
}
