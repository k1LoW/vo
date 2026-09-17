import Foundation
import Testing
import VoObjC
@testable import vo

@Suite("NSException bridge")
struct NSExceptionBridgeTests {
    /// A body that completes normally runs its side effects and does not throw.
    @Test func passesThroughWhenNothingIsRaised() throws {
        var ran = false
        try catchingNSException { ran = true }
        #expect(ran == true)
    }

    /// A raised NSException must surface as a Swift error rather than terminating the
    /// process, carrying the exception's reason so the caller can report it.
    @Test func convertsRaisedExceptionIntoAThrownError() {
        #expect(throws: (any Error).self) {
            try catchingNSException {
                NSException(
                    name: .invalidArgumentException,
                    reason: "Failed to create tap due to format mismatch",
                    userInfo: nil
                ).raise()
            }
        }

        do {
            try catchingNSException {
                NSException(name: .invalidArgumentException, reason: "boom", userInfo: nil).raise()
            }
            Issue.record("expected the raised exception to be thrown as an error")
        } catch {
            let err = error as NSError
            #expect(err.domain == VoNSExceptionErrorDomain)
            #expect(err.localizedDescription == "boom")
            #expect(err.userInfo[VoNSExceptionNameKey] as? String == NSExceptionName.invalidArgumentException.rawValue)
        }
    }

    /// Catching one exception must leave the bridge usable, since a device that keeps
    /// refusing makes the reopen loop call it again and again.
    @Test func staysUsableAfterCatching() throws {
        for _ in 0..<3 {
            #expect(throws: (any Error).self) {
                try catchingNSException {
                    NSException(name: .genericException, reason: "again", userInfo: nil).raise()
                }
            }
        }
        var ran = false
        try catchingNSException { ran = true }
        #expect(ran == true)
    }
}
