import Testing
@testable import vo

@Suite("Reopen backoff")
struct ReopenBackoffTests {
    /// The attempt made as soon as the device change is seen must not wait, so a device
    /// that is already usable is followed as promptly as before the retry loop existed.
    @Test func firstAttemptRunsImmediately() {
        #expect(reopenBackoffDelay(attempt: 0) == .zero)
    }

    /// Each further attempt waits twice as long as the previous one.
    @Test func delayDoublesPerAttempt() {
        #expect(reopenBackoffDelay(attempt: 1) == .milliseconds(250))
        #expect(reopenBackoffDelay(attempt: 2) == .milliseconds(500))
        #expect(reopenBackoffDelay(attempt: 3) == .seconds(1))
        #expect(reopenBackoffDelay(attempt: 4) == .seconds(2))
        #expect(reopenBackoffDelay(attempt: 5) == .seconds(4))
    }

    /// Growth stops at the cap, so a device that stays contended is polled at a steady
    /// rate instead of drifting towards intervals longer than the outage itself.
    @Test func delayIsCapped() {
        #expect(reopenBackoffDelay(attempt: 6) == .seconds(5))
        #expect(reopenBackoffDelay(attempt: 50) == .seconds(5))
        #expect(reopenBackoffDelay(attempt: maxReopenAttempts) == .seconds(5))
    }

    /// The whole retry budget has to outlast a Bluetooth profile switch by a wide margin
    /// (minutes, not seconds) while still being finite.
    @Test func totalBudgetSpansMinutes() {
        let total = (0..<maxReopenAttempts).reduce(Duration.zero) { $0 + reopenBackoffDelay(attempt: $1) }
        #expect(total > .seconds(300))
        #expect(total < .seconds(1800))
    }
}
