import Foundation
import Testing
@testable import vo

@Suite("VoError messages")
struct VoErrorTests {
    /// An unsupported locale whose language has supported regional variants should
    /// suggest exactly those variants and nothing from other languages.
    @Test func unsupportedLocaleSuggestsRegionalVariants() {
        let err = VoError.unsupportedSpeechLocale(
            Locale(identifier: "en"),
            supported: ["en-US", "en-GB", "ja-JP"]
        )
        let msg = err.description

        #expect(msg.contains("regional variants"))
        #expect(msg.contains("en-US"))
        #expect(msg.contains("en-GB"))
        #expect(!msg.contains("ja-JP"))
    }

    /// When no regional variant matches, fall back to pointing at `--doctor`.
    @Test func unsupportedLocaleWithoutNearbyPointsToDoctor() {
        let err = VoError.unsupportedSpeechLocale(
            Locale(identifier: "xx"),
            supported: ["en-US", "ja-JP"]
        )
        let msg = err.description

        #expect(msg.contains("--doctor"))
        #expect(!msg.contains("regional variants"))
    }

    /// A supported-but-not-downloaded translation pair names both locales and the
    /// System Settings path the user must follow, since a CLI can't trigger the download.
    @Test func translationModelNotInstalledNamesPairAndInstallPath() {
        let err = VoError.translationModelNotInstalled(
            source: Locale(identifier: "en-US"),
            target: Locale(identifier: "ja-JP")
        )
        let msg = err.description

        #expect(msg.contains("en-US"))
        #expect(msg.contains("ja-JP"))
        #expect(msg.contains("System Settings"))
    }

    /// An unsupported translation pair names both locales and points at `--doctor`.
    @Test func unsupportedTranslationPairPointsToDoctor() {
        let err = VoError.unsupportedTranslationPair(
            source: Locale(identifier: "en-US"),
            target: Locale(identifier: "xx")
        )
        let msg = err.description

        #expect(msg.contains("en-US"))
        #expect(msg.contains("not supported"))
        #expect(msg.contains("--doctor"))
    }

    /// A failure to open `--input` includes the supplied path and the underlying
    /// error message, so a user can tell from stderr which file was wrong.
    @Test func inputFileOpenFailedIncludesPathAndUnderlying() {
        let url = URL(fileURLWithPath: "/tmp/vo-test-missing.wav")
        let underlying = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileReadNoSuchFileError,
            userInfo: [NSLocalizedDescriptionKey: "No such file"]
        )
        let err = VoError.inputFileOpenFailed(url: url, underlying: underlying)
        let msg = err.description

        #expect(msg.contains("Could not open"))
        #expect(msg.contains("/tmp/vo-test-missing.wav"))
        #expect(msg.contains("No such file"))
    }

    /// A mid-stream read failure distinguishes itself from the open-time error and
    /// hints at the likely causes (corruption, disconnect) so a user does not
    /// confuse it with a missing-file case.
    @Test func inputFileReadFailedNamesCorruptionAndPath() {
        let url = URL(fileURLWithPath: "/tmp/vo-test-truncated.wav")
        let underlying = NSError(
            domain: NSOSStatusErrorDomain,
            code: -50,
            userInfo: [NSLocalizedDescriptionKey: "I/O error"]
        )
        let err = VoError.inputFileReadFailed(url: url, underlying: underlying)
        let msg = err.description

        #expect(msg.contains("Read failure"))
        #expect(msg.contains("/tmp/vo-test-truncated.wav"))
        #expect(msg.contains("corrupt"))
        #expect(msg.contains("I/O error"))
    }

    /// A device caught mid-switch names the channel and the format it reported, and says
    /// the condition is transient, so the user retries instead of hunting for a setting.
    @Test func audioDeviceNotReadyNamesChannelAndFormat() {
        let err = VoError.audioDeviceNotReady(channel: .mic, format: "2 ch, 44100 Hz, Float32")
        let msg = err.description

        #expect(msg.contains("microphone input device"))
        #expect(msg.contains("2 ch, 44100 Hz, Float32"))
        #expect(msg.contains("Retry"))
    }

    /// The reason attached to a stderr notice has to be the error's own actionable text.
    /// VoError and CoreAudioError conform to no Foundation error protocol, so
    /// localizedDescription would replace it with NSError's generic wording.
    @Test func describeErrorPrefersTheTypesOwnDescription() {
        let vo = VoError.audioDeviceNotReady(channel: .mic, format: "0 ch, 0 Hz")
        #expect(describeError(vo) == vo.description)
        #expect(!describeError(vo).contains("operation couldn"))

        let coreAudio = CoreAudioError(code: -50, op: "DeviceStart")
        #expect(describeError(coreAudio) == coreAudio.description)

        // An error that does carry a localized message keeps it.
        let cocoa = NSError(
            domain: NSCocoaErrorDomain,
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Device busy"]
        )
        #expect(describeError(cocoa) == "Device busy")
    }

    /// A stderr notice carries one event per line, so a multi-line reason has to collapse
    /// before it is embedded in one. `audioDeviceNotReady`, the likeliest reason a reopen
    /// keeps failing, is exactly such a description.
    @Test func singleLineCollapsesAMultiLineDescription() {
        let err = VoError.audioDeviceNotReady(channel: .mic, format: "0 ch, 0 Hz")
        #expect(err.description.contains("\n"))

        let flattened = singleLine(err.description)
        #expect(!flattened.contains("\n"))
        #expect(flattened.contains("is not ready yet"))
        #expect(flattened.contains("Retry in a moment."))
        #expect(!flattened.contains("  "))
    }

    /// A tap install that failed carries the framework's own reason, which is the only
    /// thing distinguishing a format mismatch from a permission or device error.
    @Test func audioTapInstallFailedIncludesUnderlying() {
        let underlying = NSError(
            domain: "com.apple.coreaudio.avfaudio",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "Failed to create tap due to format mismatch"]
        )
        let err = VoError.audioTapInstallFailed(channel: .mic, underlying: underlying)
        let msg = err.description

        #expect(msg.contains("microphone input device"))
        #expect(msg.contains("format mismatch"))
    }
}
