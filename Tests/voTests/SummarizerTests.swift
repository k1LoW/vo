import Foundation
import Testing
@testable import vo

@Suite("Summarizer logic")
struct SummarizerTests {
    @Test func parseTranscriptLinesExtractsChannelTimestampAndText() {
        let lines = [
            """
            {"seq":0,"channel":"mic","timestamp":"2026-06-10T08:34:56.234+09:00","src":{"lang":"en-US","text":"Hello, team."}}
            """,
            """
            {"seq":1,"channel":"speaker","timestamp":"2026-06-10T08:34:58.500+09:00","src":{"lang":"en-US","text":"Hi! How are you?"},"dst":{"lang":"ja-JP","text":"こんにちは！元気ですか？"}}
            """,
            """
            {"invalid": json}
            """,
            ""
        ]

        let parsed = Summarizer.parseTranscriptLines(fromJSONLLines: lines)
        #expect(parsed.count == 2)

        #expect(parsed[0].channel == "mic")
        #expect(parsed[0].timestamp == "08:34:56")
        #expect(parsed[0].text == "Hello, team.")

        #expect(parsed[1].channel == "speaker")
        #expect(parsed[1].timestamp == "08:34:58")
        #expect(parsed[1].text == "Hi! How are you? (こんにちは！元気ですか？)")
    }

    @Test func parseTranscriptLinesIgnoresEmptySrc() {
        let lines = [
            """
            {"seq":0,"channel":"mic","timestamp":"2026-06-10T08:34:56.234+09:00","src":{"lang":"en-US","text":""}}
            """,
            """
            {"seq":1,"channel":"mic","timestamp":"2026-06-10T08:34:57.000+09:00","src":{"lang":"en-US","text":"   "}}
            """
        ]

        let parsed = Summarizer.parseTranscriptLines(fromJSONLLines: lines)
        #expect(parsed.isEmpty)
    }

    @Test func formatTranscriptCombinesLinesCleanly() {
        let items = [
            Summarizer.TranscriptLine(timestamp: "10:00:00", channel: "mic", text: "First topic."),
            Summarizer.TranscriptLine(timestamp: "10:00:05", channel: "speaker", text: "Agreed.")
        ]

        let formatted = Summarizer.formatTranscript(items)
        #expect(formatted.contains("[10:00:00] [mic] First topic."))
        #expect(formatted.contains("[10:00:05] [speaker] Agreed."))
    }

    @Test func formatTranscriptHandlesMissingTimestampsOrChannels() {
        let items = [
            Summarizer.TranscriptLine(timestamp: "", channel: "mic", text: "No timestamp."),
            Summarizer.TranscriptLine(timestamp: "10:00:00", channel: "", text: "No channel."),
            Summarizer.TranscriptLine(timestamp: "", channel: "", text: "Neither.")
        ]

        let formatted = Summarizer.formatTranscript(items)
        #expect(formatted.contains("[mic] No timestamp."))
        #expect(formatted.contains("[10:00:00] No channel."))
        #expect(formatted.contains("- Neither."))
    }

    @Test func chunkPromptIncludesRangeAndLanguageInstruction() {
        let prompt = SummaryPrompts.chunkPrompt(
            index: 0,
            startTimestamp: "10:00:00",
            endTimestamp: "10:05:00",
            chunkText: "[mic] Discussion topic"
        )
        #expect(prompt.contains("The following is part 1 (utterances 10:00:00 to 10:05:00)"))
        #expect(prompt.contains("IMPORTANT: Write the entire summary in the primary language used in the transcript."))
        #expect(prompt.contains("[mic] Discussion topic"))
    }

    @Test func chunkPromptAppliesExplicitTargetLanguage() {
        let prompt = SummaryPrompts.chunkPrompt(
            index: 0,
            startTimestamp: "10:00:00",
            endTimestamp: "10:05:00",
            chunkText: "[mic] Discussion topic",
            targetLanguage: "Japanese"
        )
        #expect(prompt.contains("IMPORTANT: Write the entire summary in Japanese."))
    }

    @Test func chunkPromptHandlesEmptyTimestamps() {
        let prompt = SummaryPrompts.chunkPrompt(
            index: 1,
            startTimestamp: nil,
            endTimestamp: nil,
            chunkText: "Sample text"
        )
        #expect(prompt.contains("The following is part 2 of a transcript."))
        #expect(!prompt.contains("utterances"))
    }

    @Test func finalPromptInstructsSameLanguageByDefault() {
        let prompt = SummaryPrompts.finalPrompt(transcript: "Transcript content")
        #expect(prompt.contains("Analyze the transcript below"))
        #expect(prompt.contains("IMPORTANT: Write the entire response in the primary language used in the transcript"))
        #expect(!prompt.contains("For example, use Japanese"))
        #expect(prompt.contains("Transcript content"))
    }

    @Test func finalPromptAppliesExplicitTargetLanguage() {
        let prompt = SummaryPrompts.finalPrompt(
            transcript: "Transcript content",
            targetLanguage: "Japanese"
        )
        #expect(prompt.contains("IMPORTANT: Write the entire response in Japanese (including all section headings"))
        #expect(!prompt.contains("primary language used in the transcript"))
    }

    @Test func finalPromptHandlesIntermediateSummary() {
        let prompt = SummaryPrompts.finalPrompt(transcript: "Part summaries", isIntermediateSummary: true)
        #expect(prompt.contains("Analyze the intermediate summaries of each part below"))
    }

    @Test func finalPromptAppliesCustomPrompt() {
        let prompt = SummaryPrompts.finalPrompt(
            transcript: "Transcript content",
            customPrompt: "Custom summarization rule"
        )
        #expect(prompt.contains("Custom summarization rule"))
        #expect(prompt.contains("Transcript content"))
        #expect(!prompt.contains("Analyze the transcript"))
    }

    @Test func finalPromptIncludesConcisenessAndItemCapRequirements() {
        let prompt = SummaryPrompts.finalPrompt(transcript: "Transcript content")
        #expect(prompt.contains("CONCISENESS & LENGTH REQUIREMENTS:"))
        #expect(prompt.contains("Strictly 3-5 bullet points"))
        #expect(prompt.contains("800 - 1,200 characters"))
    }

    @Test func finalPromptGeneratesStructuredSections() {
        let prompt = SummaryPrompts.finalPrompt(transcript: "Content")
        #expect(prompt.contains("**Overview**"))
        #expect(prompt.contains("**Key Points**"))
        #expect(prompt.contains("**Takeaways & Outcomes**"))
    }

    @Test func summarizerTracksUtteranceCountAndAppends() async {
        let summarizer = Summarizer(summaryOut: nil, customPrompt: nil)
        #expect(await summarizer.utteranceCount == 0)

        await summarizer.append(Summarizer.TranscriptLine(timestamp: "10:00:00", channel: "mic", text: "Hello"))
        await summarizer.append(Summarizer.TranscriptLine(timestamp: "10:00:05", channel: "speaker", text: "World"))

        #expect(await summarizer.utteranceCount == 2)
    }

    @Test func chunkSummaryStoresMetadataCorrectly() {
        let chunk = Summarizer.ChunkSummary(
            index: 0,
            startTime: "10:00:00",
            endTime: "10:01:30",
            utteranceCount: 25,
            summaryText: "- Discussed feature launch\n- Assigned reviewer"
        )
        #expect(chunk.index == 0)
        #expect(chunk.startTime == "10:00:00")
        #expect(chunk.endTime == "10:01:30")
        #expect(chunk.utteranceCount == 25)
        #expect(chunk.summaryText.contains("feature launch"))
    }

    @Test func languageDisplayNameExtractsEnglishNames() {
        #expect(Summarizer.languageDisplayName(for: Locale(identifier: "ja-JP")) == "Japanese")
        #expect(Summarizer.languageDisplayName(for: Locale(identifier: "en-US")) == "English")
        #expect(Summarizer.languageDisplayName(for: Locale(identifier: "fr-FR")) == "French")
    }

    @Test func shortSessionSummarizesDirectlyInOneCall() async throws {
        actor CallRecorder {
            var prompts: [String] = []
            func record(_ p: String) { prompts.append(p) }
        }
        let recorder = CallRecorder()
        let summarizer = Summarizer(
            summaryOut: nil,
            customPrompt: "Extract exact numbers.",
            responder: { prompt in
                await recorder.record(prompt)
                return "# Final Summary"
            }
        )

        for i in 1...5 {
            await summarizer.append(Summarizer.TranscriptLine(timestamp: "10:00:0\(i)", channel: "mic", text: "Line \(i)"))
        }

        let result = try await summarizer.finalize()
        let prompts = await recorder.prompts

        #expect(result == "# Final Summary")
        #expect(prompts.count == 1)
        #expect(prompts[0].contains("Extract exact numbers."))
        #expect(prompts[0].contains("Line 1"))
        #expect(await summarizer.partialSummaries.isEmpty)
    }

    @Test func longBacklogBatchesIntoChunksOfAtMost25Lines() async throws {
        let lines = (1...60).map { i in
            Summarizer.TranscriptLine(timestamp: "10:00:00", channel: "mic", text: "Utterance \(i)")
        }
        let summarizer = Summarizer(
            summaryOut: nil,
            customPrompt: nil,
            responder: { prompt in
                if prompt.contains("The following is part") {
                    return "- Chunk bullet"
                }
                return "# Synthesized Summary"
            }
        )

        let result = try await summarizer.summarize(lines: lines)
        let chunks = await summarizer.partialSummaries

        #expect(result == "# Synthesized Summary")
        #expect(chunks.count == 3)
        #expect(chunks.map(\.utteranceCount) == [25, 25, 10])
    }

    @Test func unwritableSummaryOutThrowsSummarizationFailed() async {
        let summarizer = Summarizer(
            summaryOut: "/nonexistent-dir-\(UUID().uuidString)/summary.md",
            customPrompt: nil,
            responder: { _ in "# Summary" }
        )
        await summarizer.append(Summarizer.TranscriptLine(timestamp: "10:00:00", channel: "mic", text: "Hello"))

        await #expect(throws: VoError.self) {
            _ = try await summarizer.finalize()
        }
    }

    @Test func appendSummaryChunkStillWritesAfterEOF() async {
        let pipe = Pipe()
        let renderer = StreamRenderer(
            mode: .tty,
            sourceLang: "en-US",
            targetLang: "",
            translationEnabled: false,
            showChannelLabel: true,
            out: pipe.fileHandleForWriting,
            isSummaryView: true
        )

        await renderer.handle(.eof)
        await renderer.appendSummaryChunk(
            Summarizer.ChunkSummary(
                index: 1,
                startTime: "10:01:00",
                endTime: "10:02:00",
                utteranceCount: 12,
                summaryText: "- Final chunk summary"
            )
        )
        await renderer.flush()

        try? pipe.fileHandleForWriting.close()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        try? pipe.fileHandleForReading.close()
        let output = String(decoding: data, as: UTF8.self)

        #expect(output.contains("Part 2 (12 utterances)"))
        #expect(output.contains("- Final chunk summary"))
    }

    @Test func backgroundChunkFailureBacksOffAndSkipsAfterMaxAttempts() async throws {
        actor Tracker {
            var chunkCalls: Int = 0
            var notices: [String] = []
            func recordCall() { chunkCalls += 1 }
            func recordNotice(_ n: String) { notices.append(n) }
        }
        let tracker = Tracker()

        let summarizer = Summarizer(
            summaryOut: nil,
            customPrompt: nil,
            updateIntervalSeconds: 60.0,
            maxChunkAttempts: 1,
            onNotice: { msg in
                Task { await tracker.recordNotice(msg) }
            },
            responder: { prompt in
                if prompt.contains("The following is part") {
                    await tracker.recordCall()
                    if prompt.contains("Poisoned 1") {
                        throw VoError.summarizationFailed(reason: "guardrail violation")
                    }
                    return "- Good chunk summary"
                }
                return "# Unified Summary"
            }
        )

        // Feed 25 poisoned utterances -> triggers background update #1 which fails and skips immediately (maxChunkAttempts = 1)
        for i in 1...25 {
            await summarizer.append(Summarizer.TranscriptLine(timestamp: "10:00:00", channel: "mic", text: "Poisoned \(i)"))
        }

        // Feed 25 good utterances -> since the poisoned batch was dropped, these form the next batch cleanly
        for i in 1...25 {
            await summarizer.append(Summarizer.TranscriptLine(timestamp: "10:01:00", channel: "mic", text: "Valid \(i)"))
        }

        let result = try await summarizer.finalize()
        // Allow detached notice task to settle
        try? await Task.sleep(for: .milliseconds(20))

        let calls = await tracker.chunkCalls
        let notices = await tracker.notices
        let chunks = await summarizer.partialSummaries

        #expect(result == "# Unified Summary")
        #expect(calls == 2)
        #expect(chunks.count == 1)
        #expect(chunks[0].summaryText == "- Good chunk summary")
        #expect(!notices.isEmpty)
        #expect(notices[0].contains("Skipping batch of 25 utterances"))
    }

    @Test func backgroundRetryWaitsForIntervalInsteadOfRetriggeringPerAppend() async throws {
        actor CallCounter {
            var count = 0
            func increment() -> Int {
                count += 1
                return count
            }
        }
        let counter = CallCounter()

        let summarizer = Summarizer(
            summaryOut: nil,
            customPrompt: nil,
            updateIntervalSeconds: 3600.0, // long backoff
            maxChunkAttempts: 2,
            onNotice: { _ in },
            responder: { prompt in
                if prompt.contains("The following is part") {
                    let c = await counter.increment()
                    if c == 1 {
                        throw VoError.summarizationFailed(reason: "transient error")
                    }
                    return "- Recovered chunk"
                }
                return "# Final"
            }
        )

        // First 25 lines trigger attempt #1, which fails and re-queues with currentBatchFailureCount == 1
        for i in 1...25 {
            await summarizer.append(Summarizer.TranscriptLine(timestamp: "10:00:00", channel: "mic", text: "Item \(i)"))
        }
        // Wait briefly for the background task to complete its first failed attempt
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await counter.count == 1)

        // Appending 10 more utterances must NOT fire 10 LLM calls while inside the backoff window
        for i in 26...35 {
            await summarizer.append(Summarizer.TranscriptLine(timestamp: "10:00:01", channel: "mic", text: "Item \(i)"))
        }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await counter.count == 1)

        // Finalize drains and succeeds on the retry
        let final = try await summarizer.finalize()
        #expect(final == "# Final")
        #expect(await summarizer.partialSummaries.count == 2)
    }

    @Test func finalizeDropsFailingMapBatchesAndPreservesFinalSummary() async throws {
        actor FinalPromptRecorder {
            var finalPrompt: String = ""
            func set(_ p: String) { finalPrompt = p }
        }
        let recorder = FinalPromptRecorder()

        let lines = (1...75).map { i in
            Summarizer.TranscriptLine(timestamp: "10:00:00", channel: "mic", text: "Utterance \(i)")
        }

        let summarizer = Summarizer(
            summaryOut: nil,
            customPrompt: nil,
            maxChunkAttempts: 1,
            onNotice: { _ in },
            responder: { prompt in
                if prompt.contains("The following is part") {
                    // Fail on the second batch (Utterance 26..50), succeed on 1st and 3rd
                    if prompt.contains("Utterance 26") {
                        throw VoError.summarizationFailed(reason: "context overflow")
                    }
                    return "- Chunk summary"
                }
                await recorder.set(prompt)
                return "# Synthesized Despite Failure"
            }
        )

        let result = try await summarizer.summarize(lines: lines)
        let chunks = await summarizer.partialSummaries
        let recordedPrompt = await recorder.finalPrompt

        #expect(result == "# Synthesized Despite Failure")
        // Batch 1 (1..25) and Batch 3 (51..75) both succeeded; Batch 2 was skipped without breaking the loop
        #expect(chunks.count == 2)
        // Poisoned Batch 2 is NOT dumped as raw Remaining Transcript into the Reduce prompt
        #expect(!recordedPrompt.contains("Utterance 26"))
        #expect(!recordedPrompt.contains("Remaining Transcript"))
    }

    @Test func boundedFallbackLinesTruncatesExcessiveLinesAndChars() {
        let manyLines = (1...100).map { i in
            Summarizer.TranscriptLine(
                timestamp: "10:00:00",
                channel: "mic",
                text: "Message \(i) " + String(repeating: "x", count: 100)
            )
        }

        let bounded = Summarizer.boundedFallbackLines(from: manyLines, maxLines: 25, maxChars: 600)
        let formatted = Summarizer.formatTranscript(bounded)

        #expect(!bounded.isEmpty)
        #expect(bounded.count <= 25)
        #expect(formatted.count <= 600)
        // Keeps the most recent lines at the tail
        #expect(bounded.last?.text.contains("Message 100") == true)
    }
}

