import AVFoundation
import Testing
@testable import vo

@Suite("Bridging silence")
struct FeedSilenceTests {
    private let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!

    private func collect(seconds: Double) async -> [AVAudioFrameCount] {
        var frames: [AVAudioFrameCount] = []
        await feedSilence(seconds: seconds, format: format) { buffer in
            frames.append(buffer.frameLength)
        }
        return frames
    }

    /// The analyzer's timeline is driven by the number of samples fed, so splitting a gap
    /// must feed exactly the frame count the unsplit span would have.
    @Test func totalFramesMatchTheRequestedSpan() async {
        for seconds in [0.03, 1.0, 2.5, 7.31, 600.0] {
            let frames = await collect(seconds: seconds)
            let total = frames.reduce(AVAudioFrameCount(0), +)
            #expect(total == AVAudioFrameCount((seconds * 16000).rounded()))
        }
    }

    /// No single buffer may scale with the outage, which is the whole point of chunking:
    /// a ten-minute reopen gap must not allocate a ten-minute PCM buffer.
    @Test func noBufferGrowsWithTheGap() async {
        let frames = await collect(seconds: 600)
        #expect(frames.allSatisfy { $0 <= 16000 })
        #expect(frames.count == 600)
    }

    /// A gap shorter than one chunk stays a single buffer, so the common case (the initial
    /// offset from sessionStart, a hole left by a failed convert) is unchanged.
    @Test func shortGapStaysOneBuffer() async {
        let frames = await collect(seconds: 0.25)
        #expect(frames == [4000])
    }

    /// A span that cannot be turned into samples feeds nothing, leaving the caller's
    /// timeline untouched rather than inventing audio for it.
    @Test func unusableSpansFeedNothing() async {
        #expect(await collect(seconds: 0).isEmpty)
        #expect(await collect(seconds: -1).isEmpty)
        #expect(await collect(seconds: .infinity).isEmpty)
        #expect(await collect(seconds: .nan).isEmpty)
        // Rounds to zero frames at 16 kHz.
        #expect(await collect(seconds: 0.00001).isEmpty)
    }
}
