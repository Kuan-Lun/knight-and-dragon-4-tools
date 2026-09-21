import Testing
@testable import MirrorProbeCore

@Suite("Foreground deferral")
struct AutoLevelForegroundDeferralTests {
    @Test("Deferrals back off 5, 10, 20, 30 seconds and stay bounded to two minutes")
    func backoffScheduleAndLimit() {
        var state = AutoLevelForegroundDeferralState()

        #expect(!state.isDeferring)
        #expect(state.recordDeferral(at: 100)
            == .deferred(deferredActions: 1, unavailableSeconds: 0, backoffSeconds: 5))
        #expect(state.isDeferring)
        #expect(state.recordDeferral(at: 108)
            == .deferred(deferredActions: 2, unavailableSeconds: 8, backoffSeconds: 10))
        #expect(state.recordDeferral(at: 121)
            == .deferred(deferredActions: 3, unavailableSeconds: 21, backoffSeconds: 20))
        #expect(state.recordDeferral(at: 144)
            == .deferred(deferredActions: 4, unavailableSeconds: 44, backoffSeconds: 30))
        #expect(state.recordDeferral(at: 177)
            == .deferred(deferredActions: 5, unavailableSeconds: 77, backoffSeconds: 30))
        #expect(state.recordDeferral(at: 210)
            == .deferred(deferredActions: 6, unavailableSeconds: 110, backoffSeconds: 30))
        #expect(state.recordDeferral(at: 220)
            == .exhausted(deferredActions: 7, unavailableSeconds: 120))
        #expect(state.recordDeferral(at: 221)
            == .exhausted(deferredActions: 8, unavailableSeconds: 121))
    }

    @Test("A confirmed foreground preflight ends the episode and reports it once")
    func recoveryEndsEpisode() {
        var state = AutoLevelForegroundDeferralState()

        #expect(state.recordForegroundAvailable(at: 50) == nil)
        _ = state.recordDeferral(at: 100)
        _ = state.recordDeferral(at: 130)
        #expect(state.recordForegroundAvailable(at: 140)
            == AutoLevelForegroundDeferralRecovery(deferredActions: 2, unavailableSeconds: 40))
        #expect(!state.isDeferring)
        #expect(state.recordForegroundAvailable(at: 141) == nil)
        #expect(state.recordDeferral(at: 300)
            == .deferred(deferredActions: 1, unavailableSeconds: 0, backoffSeconds: 5))
    }

    @Test("Quiet stretches without any needed click never count as unavailability")
    func longGapStartsNewEpisode() {
        var state = AutoLevelForegroundDeferralState()
        _ = state.recordDeferral(at: 100)
        _ = state.recordDeferral(at: 200)

        // 301 seconds after the last deferral is a fresh episode, not 401 seconds of unavailability.
        #expect(state.recordDeferral(at: 501)
            == .deferred(deferredActions: 1, unavailableSeconds: 0, backoffSeconds: 5))

        // Exactly the gap limit continues the episode.
        var continued = AutoLevelForegroundDeferralState()
        _ = continued.recordDeferral(at: 100)
        #expect(continued.recordDeferral(at: 400)
            == .exhausted(deferredActions: 2, unavailableSeconds: 300))
    }

    @Test("An invalid clock fails closed", arguments: [Double.nan, -1, Double.infinity])
    func invalidClockFailsClosed(now: Double) {
        var state = AutoLevelForegroundDeferralState()
        #expect(state.recordDeferral(at: now) == .invalidClock)
        #expect(!state.isDeferring)
    }

    @Test("A clock that runs backwards fails closed")
    func backwardsClockFailsClosed() {
        var state = AutoLevelForegroundDeferralState()
        _ = state.recordDeferral(at: 100)
        #expect(state.recordDeferral(at: 99) == .invalidClock)
        #expect(state.recordDeferral(at: 100)
            == .deferred(deferredActions: 2, unavailableSeconds: 0, backoffSeconds: 10))
    }
}
