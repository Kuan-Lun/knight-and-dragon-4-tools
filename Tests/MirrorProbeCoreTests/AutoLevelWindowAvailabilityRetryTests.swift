import Foundation
import Testing
@testable import MirrorProbeCore

@Suite("Window availability recovery budget")
struct AutoLevelWindowAvailabilityRetryTests {
    @Test("A missing window may recover on the next bounded query")
    func missingThenRecovery() {
        var retry = AutoLevelWindowAvailabilityRetry(startedAt: 100, sessionDeadline: 200)
        #expect(retry.attempt == 1)
        #expect(retry.validateBoundary(at: 100) == nil)
        #expect(retry.recordMissing(at: 100.2) == .retry(nextAttempt: 2, delaySeconds: 1))
        #expect(retry.validateBoundary(at: 101.2) == nil)
        // A successful second query still validates its completion before using its result.
        #expect(retry.validateBoundary(at: 101.4) == nil)
        #expect(retry.attempt == 2)
        #expect(retry.startedAt == 100)
        #expect(retry.sessionDeadline == 200)
    }

    @Test("Retries wait at least one second and four missing queries exhaust the budget")
    func attemptLimitAndBackoff() {
        var retry = AutoLevelWindowAvailabilityRetry(startedAt: 100, sessionDeadline: 200)
        #expect(retry.recordMissing(at: 100) == .retry(nextAttempt: 2, delaySeconds: 1))
        #expect(retry.recordMissing(at: 101) == .retry(nextAttempt: 3, delaySeconds: 1))
        #expect(retry.recordMissing(at: 102) == .retry(nextAttempt: 4, delaySeconds: 1.5))
        #expect(retry.recordMissing(at: 103.5) == .stop(reason: .attemptsExhausted))
        #expect(retry.attempt == AutoLevelWindowAvailabilityRetry.maximumAttempts)
        #expect(retry.validateBoundary(at: 103.6) == .attemptsExhausted)
        #expect(retry.recordMissing(at: 103.7) == .stop(reason: .attemptsExhausted))
    }

    @Test("STOP is honored before a query, after a query, and after a wait")
    func stopAtEveryBoundary() {
        var beforeQuery = AutoLevelWindowAvailabilityRetry(startedAt: 100, sessionDeadline: 200)
        #expect(beforeQuery.validateBoundary(at: 100, stopRequested: true) == .stopRequested)
        #expect(beforeQuery.validateBoundary(at: 100.1) == .stopRequested)

        var afterQuery = AutoLevelWindowAvailabilityRetry(startedAt: 100, sessionDeadline: 200)
        #expect(afterQuery.validateBoundary(at: 100) == nil)
        #expect(afterQuery.recordMissing(at: 100.2, stopRequested: true) == .stop(reason: .stopRequested))
        #expect(afterQuery.attempt == 1)

        var afterWait = AutoLevelWindowAvailabilityRetry(startedAt: 100, sessionDeadline: 200)
        #expect(afterWait.recordMissing(at: 100) == .retry(nextAttempt: 2, delaySeconds: 1))
        #expect(afterWait.validateBoundary(at: 101, stopRequested: true) == .stopRequested)
    }

    @Test("A subsecond session wait reaches the deadline without permitting another query")
    func sessionBoundaryClipsDelay() {
        var retry = AutoLevelWindowAvailabilityRetry(startedAt: 100, sessionDeadline: 100.25)
        #expect(retry.recordMissing(at: 100) == .retry(nextAttempt: 2, delaySeconds: 0.25))
        #expect(retry.validateBoundary(at: 100.125) == nil)
        // A clipped wait ends recovery at the deadline instead of starting a faster retry.
        #expect(retry.validateBoundary(at: 100.25) == .sessionExpired)
        #expect(retry.recordMissing(at: 100.5) == .stop(reason: .sessionExpired))
        #expect(retry.sessionDeadline == 100.25)
    }

    @Test("Action expiry applies both before and after a successful window query")
    func actionBoundaryAppliesToQueryCompletion() {
        var retry = AutoLevelWindowAvailabilityRetry(
            startedAt: 100, sessionDeadline: 200, actionDeadline: 100.25
        )
        #expect(retry.recordMissing(at: 100) == .retry(nextAttempt: 2, delaySeconds: 0.25))
        #expect(retry.validateBoundary(at: 100.125) == nil)
        #expect(retry.validateBoundary(at: 100.25) == .actionExpired)
        #expect(retry.recordMissing(at: 100.25) == .stop(reason: .actionExpired))
        #expect(retry.actionDeadline == 100.25)

        var slowSuccessfulQuery = AutoLevelWindowAvailabilityRetry(
            startedAt: 100, sessionDeadline: 200, actionDeadline: 100.5
        )
        #expect(slowSuccessfulQuery.validateBoundary(at: 100) == nil)
        #expect(slowSuccessfulQuery.validateBoundary(at: 100.75) == .actionExpired)
    }

    @Test("Recovery time starts once and includes slow window queries")
    func recoveryDurationDoesNotRestartAfterMissing() {
        var retry = AutoLevelWindowAvailabilityRetry(startedAt: 100, sessionDeadline: 200)
        #expect(retry.validateBoundary(at: 100) == nil)
        #expect(retry.recordMissing(at: 104.75) == .retry(nextAttempt: 2, delaySeconds: 0.25))
        #expect(retry.validateBoundary(at: 104.875) == nil)
        #expect(retry.validateBoundary(at: 105) == .recoveryExpired)
        #expect(retry.recordMissing(at: 105) == .stop(reason: .recoveryExpired))

        var slowSuccessfulQuery = AutoLevelWindowAvailabilityRetry(startedAt: 100, sessionDeadline: 200)
        #expect(slowSuccessfulQuery.validateBoundary(at: 100) == nil)
        #expect(slowSuccessfulQuery.validateBoundary(at: 105.1) == .recoveryExpired)
    }

    @Test("Captures with no pending action retain session and recovery limits")
    func noActionDeadlineDoesNotExtendOtherBudgets() {
        var observation = AutoLevelWindowAvailabilityRetry(startedAt: 100, sessionDeadline: 104)
        #expect(observation.actionDeadline == nil)
        #expect(observation.validateBoundary(at: 101) == nil)
        #expect(observation.recordMissing(at: 103.75) == .retry(nextAttempt: 2, delaySeconds: 0.25))
        #expect(observation.validateBoundary(at: 104) == .sessionExpired)

        var longerSession = AutoLevelWindowAvailabilityRetry(startedAt: 100, sessionDeadline: 200)
        #expect(longerSession.actionDeadline == nil)
        #expect(longerSession.validateBoundary(at: 105) == .recoveryExpired)
    }

    @Test("An unlimited session retains the fixed recovery deadline and query cap")
    func noSessionDeadlineStillBoundsRecovery() {
        var slowQuery = AutoLevelWindowAvailabilityRetry(startedAt: 100)
        #expect(slowQuery.sessionDeadline == nil)
        #expect(slowQuery.actionDeadline == nil)
        #expect(slowQuery.validateBoundary(at: 100) == nil)
        #expect(slowQuery.recordMissing(at: 104.75) == .retry(nextAttempt: 2, delaySeconds: 0.25))
        #expect(slowQuery.validateBoundary(at: 105) == .recoveryExpired)
        #expect(slowQuery.recordMissing(at: 105.5) == .stop(reason: .recoveryExpired))

        var missingQueries = AutoLevelWindowAvailabilityRetry(startedAt: 100, sessionDeadline: nil)
        #expect(missingQueries.recordMissing(at: 100) == .retry(nextAttempt: 2, delaySeconds: 1))
        #expect(missingQueries.recordMissing(at: 101) == .retry(nextAttempt: 3, delaySeconds: 1))
        #expect(missingQueries.recordMissing(at: 102) == .retry(nextAttempt: 4, delaySeconds: 1.5))
        #expect(missingQueries.recordMissing(at: 103.5) == .stop(reason: .attemptsExhausted))
        #expect(missingQueries.attempt == AutoLevelWindowAvailabilityRetry.maximumAttempts)
    }

    @Test("An unlimited session cannot renew an action deadline while recovering its window")
    func noSessionDeadlineRetainsOriginalActionDeadline() {
        var retry = AutoLevelWindowAvailabilityRetry(startedAt: 100, actionDeadline: 100.25)
        #expect(retry.recordMissing(at: 100) == .retry(nextAttempt: 2, delaySeconds: 0.25))
        #expect(retry.validateBoundary(at: 100.125) == nil)
        #expect(retry.validateBoundary(at: 100.25) == .actionExpired)
        #expect(retry.actionDeadline == 100.25)
        #expect(retry.recordMissing(at: 101) == .stop(reason: .actionExpired))

        var longerAction = AutoLevelWindowAvailabilityRetry(startedAt: 100, actionDeadline: 110)
        #expect(longerAction.validateBoundary(at: 105) == .recoveryExpired)
    }

    @Test("An unlimited session still honors STOP and rejects clock rollback")
    func noSessionDeadlineRetainsStopAndClockGuards() {
        var stopped = AutoLevelWindowAvailabilityRetry(startedAt: 100)
        #expect(stopped.recordMissing(at: 100) == .retry(nextAttempt: 2, delaySeconds: 1))
        #expect(stopped.validateBoundary(at: 101, stopRequested: true) == .stopRequested)
        #expect(stopped.validateBoundary(at: 102) == .stopRequested)

        var rollback = AutoLevelWindowAvailabilityRetry(startedAt: 100)
        #expect(rollback.validateBoundary(at: 101) == nil)
        #expect(rollback.recordMissing(at: 100.5) == .stop(reason: .invalidClock))
    }

    @Test("The earliest deadline determines the boundary even when several have elapsed")
    func earliestDeadlineWins() {
        var sessionFirst = AutoLevelWindowAvailabilityRetry(
            startedAt: 100, sessionDeadline: 102, actionDeadline: 103
        )
        #expect(sessionFirst.validateBoundary(at: 106) == .sessionExpired)
        var actionFirst = AutoLevelWindowAvailabilityRetry(
            startedAt: 100, sessionDeadline: 103, actionDeadline: 102
        )
        #expect(actionFirst.validateBoundary(at: 106) == .actionExpired)
        var recoveryFirst = AutoLevelWindowAvailabilityRetry(
            startedAt: 100, sessionDeadline: 107, actionDeadline: 106
        )
        #expect(recoveryFirst.validateBoundary(at: 108) == .recoveryExpired)
    }

    @Test("Coincident deadlines preserve session then action then recovery precedence")
    func coincidentDeadlinePrecedence() {
        var allEqual = AutoLevelWindowAvailabilityRetry(
            startedAt: 100, sessionDeadline: 105, actionDeadline: 105
        )
        #expect(allEqual.validateBoundary(at: 105) == .sessionExpired)
        var actionAndRecovery = AutoLevelWindowAvailabilityRetry(startedAt: 100, actionDeadline: 105)
        #expect(actionAndRecovery.validateBoundary(at: 105) == .actionExpired)
    }

    @Test("Non-finite configuration and observed clocks fail closed")
    func invalidClockFailsClosed() {
        for invalid in [TimeInterval.nan, .infinity, -.infinity] {
            var observed = AutoLevelWindowAvailabilityRetry(startedAt: 100, sessionDeadline: 200)
            #expect(observed.validateBoundary(at: invalid) == .invalidClock)
            #expect(observed.validateBoundary(at: 100) == .invalidClock)
            var started = AutoLevelWindowAvailabilityRetry(startedAt: invalid, sessionDeadline: 200)
            #expect(started.validateBoundary(at: 100) == .invalidClock)
            var session = AutoLevelWindowAvailabilityRetry(startedAt: 100, sessionDeadline: invalid)
            #expect(session.validateBoundary(at: 100) == .invalidClock)
            var action = AutoLevelWindowAvailabilityRetry(
                startedAt: 100, sessionDeadline: 200, actionDeadline: invalid
            )
            #expect(action.validateBoundary(at: 100) == .invalidClock)
        }
        var negativeStart = AutoLevelWindowAvailabilityRetry(startedAt: -1, sessionDeadline: 200)
        #expect(negativeStart.validateBoundary(at: 100) == .invalidClock)

        var negativeSession = AutoLevelWindowAvailabilityRetry(startedAt: 100, sessionDeadline: -1)
        #expect(negativeSession.validateBoundary(at: 100) == .invalidClock)
        for invalid in [TimeInterval.nan, .infinity, -.infinity, -1] {
            var actionWithoutSession = AutoLevelWindowAvailabilityRetry(startedAt: 100, actionDeadline: invalid)
            #expect(actionWithoutSession.validateBoundary(at: 100) == .invalidClock)
            var timeWithoutSession = AutoLevelWindowAvailabilityRetry(startedAt: 100)
            #expect(timeWithoutSession.validateBoundary(at: invalid) == .invalidClock)
        }
    }

    @Test("Clock rollback cannot reset or extend recovery")
    func clockRollbackFailsClosed() {
        var retry = AutoLevelWindowAvailabilityRetry(startedAt: 100, sessionDeadline: 200)
        #expect(retry.validateBoundary(at: 101) == nil)
        #expect(retry.recordMissing(at: 100.5) == .stop(reason: .invalidClock))
        #expect(retry.attempt == 1)
        #expect(retry.validateBoundary(at: 102) == .invalidClock)

        var beforeStart = AutoLevelWindowAvailabilityRetry(startedAt: 100, sessionDeadline: 200)
        #expect(beforeStart.validateBoundary(at: 99) == .invalidClock)
    }
}
