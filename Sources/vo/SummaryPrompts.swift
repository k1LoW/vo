import Foundation

/// Templates for Apple Intelligence Foundation Models summarization prompts.
enum SummaryPrompts {
    /// Build a prompt for summarizing an intermediate chunk during Map-Reduce.
    static func chunkPrompt(
        index: Int,
        startTimestamp: String?,
        endTimestamp: String?,
        chunkText: String,
        targetLanguage: String? = nil
    ) -> String {
        let timeRange: String
        if let start = startTimestamp, !start.isEmpty, let end = endTimestamp, !end.isEmpty {
            timeRange = " (utterances \(start) to \(end))"
        } else {
            timeRange = ""
        }

        let languageInstruction: String
        if let targetLanguage, !targetLanguage.isEmpty {
            languageInstruction = "IMPORTANT: Write the entire summary in \(targetLanguage)."
        } else {
            languageInstruction = "IMPORTANT: Write the entire summary in the primary language used in the transcript."
        }

        return """
        The following is part \(index + 1)\(timeRange) of a transcript.
        Summarize the key discussion points, main topics, and notable remarks in 3-5 concise bullet points.
        \(languageInstruction)

        ---
        \(chunkText)
        """
    }

    /// Build the final prompt for generating a structured summary.
    static func finalPrompt(
        transcript: String,
        isIntermediateSummary: Bool = false,
        customPrompt: String? = nil,
        targetLanguage: String? = nil
    ) -> String {
        if let customPrompt {
            return """
            \(customPrompt)

            ---
            \(transcript)
            """
        }

        let sourceDescription = isIntermediateSummary
            ? "the intermediate summaries of each part"
            : "the transcript"

        let languageInstruction: String
        if let targetLanguage, !targetLanguage.isEmpty {
            languageInstruction = "IMPORTANT: Write the entire response in \(targetLanguage) (including all section headings, overview, key points, and takeaways). Do NOT use any other language."
        } else {
            languageInstruction = "IMPORTANT: Write the entire response in the primary language used in the transcript (including section headings). Do NOT translate into another language unless explicitly requested."
        }

        return """
        Analyze \(sourceDescription) below and synthesize a concise, structured summary in Markdown format.
        \(languageInstruction)
        Do NOT split or format by chronological parts/chunks; synthesize the entire content into a single unified summary.

        CONCISENESS & LENGTH REQUIREMENTS:
        - Keep the entire summary concise, readable in 2-3 minutes (target length: approx. 800 - 1,200 characters in Japanese, or 300 - 500 words in English).
        - Do NOT produce an overly long or exhaustive transcript recap. Strictly omit minor conversational details and focus exclusively on core takeaways and key discussions.

        Structure the summary cleanly:
        - **Title / Topic**: Concise Title / Topic
        - **Overview**: 2-4 concise sentences summarizing the main theme and overall context.
        - **Key Points**: Strictly 3-5 bullet points covering the most important concepts, discussion points, or highlights (each bullet should be 1-2 sentences). Do NOT exceed 5 bullets.
        - **Takeaways & Outcomes**: 2-4 bullet points of notable conclusions, takeaways, or next steps (or write "None" if not applicable).

        ---
        \(transcript)
        """
    }
}
