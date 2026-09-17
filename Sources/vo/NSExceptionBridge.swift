import Foundation
import VoObjC

/// Runs `body`, turning an Objective-C `NSException` into a thrown Swift error.
///
/// Needed wherever a Cocoa API reports a failure by raising instead of returning an error.
/// `AVAudioNode.installTap` is the case vo hits: when the format it is handed no longer
/// matches the hardware, it raises `com.apple.coreaudio.avfaudio`, which no Swift `catch`
/// can see, so the process aborts mid-session.
///
/// The object `body` was setting up must be considered unusable once this throws.
func catchingNSException(_ body: () -> Void) throws {
    var raised: NSError?
    guard VoRunCatchingNSException(body, &raised) else {
        throw raised ?? NSError(
            domain: VoNSExceptionErrorDomain,
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "An Objective-C exception was raised."]
        )
    }
}
