import Foundation

public enum AutoLevelWindowAvailabilityRetryStopReason: Equatable, Sendable {
    case stopRequested
    case sessionExpired
    case actionExpired
    case recoveryExpired
    case invalidClock
    case attemptsExhausted
}

public enum AutoLevelWindowAvailabilityRetryDecision: Equatable, Sendable {
    case retry(nextAttempt: Int, delaySeconds: TimeInterval)
    case stop(reason: AutoLevelWindowAvailabilityRetryStopReason)
}

/// A short, fixed budget for re-querying a temporarily unavailable window.
/// Callers validate immediately before and after every query, including successful queries.
/// A successful query ends recovery; it does not by itself authorize any input event.
public struct AutoLevelWindowAvailabilityRetry: Equatable, Sendable {
    public static let maximumAttempts = 4
    public static let maximumRecoveryDuration: TimeInterval = 5

    public let startedAt: TimeInterval
    public let sessionDeadline: TimeInterval
    public let actionDeadline: TimeInterval?
    public private(set) var attempt = 1

    private var lastObservedTime: TimeInterval
    private var terminalReason: AutoLevelWindowAvailabilityRetryStopReason?

    public init(
        startedAt: TimeInterval,
        sessionDeadline: TimeInterval,
        actionDeadline: TimeInterval? = nil
    ) {
        self.startedAt = startedAt
        self.sessionDeadline = sessionDeadline
        self.actionDeadline = actionDeadline
        lastObservedTime = startedAt
    }

    /// `nil` means the query boundary is valid. All terminal decisions remain terminal.
    /// Omit the action deadline only when no action is pending. After posting input, callers
    /// pass the original posted-at time plus its acknowledgement timeout. Session and recovery
    /// deadlines still apply unchanged.
    public mutating func validateBoundary(
        at time: TimeInterval,
        stopRequested: Bool = false
    ) -> AutoLevelWindowAvailabilityRetryStopReason? {
        if let terminalReason { return terminalReason }
        if stopRequested { return finish(.stopRequested) }
        let recoveryDeadline = startedAt + Self.maximumRecoveryDuration
        guard startedAt.isFinite,
              startedAt >= 0,
              sessionDeadline.isFinite,
              actionDeadline?.isFinite != false,
              recoveryDeadline.isFinite,
              recoveryDeadline > startedAt,
              time.isFinite,
              time >= lastObservedTime
        else {
            return finish(.invalidClock)
        }
        lastObservedTime = time
        let deadline = earliestDeadline
        guard time < deadline.time else { return finish(deadline.reason) }
        return nil
    }

    /// Records one unsuccessful query. Retries wait at least one second unless the earliest
    /// existing deadline clips the wait. A clipped wait only reaches that deadline: the caller
    /// must validate again, which stops recovery before another query can start.
    public mutating func recordMissing(
        at time: TimeInterval,
        stopRequested: Bool = false
    ) -> AutoLevelWindowAvailabilityRetryDecision {
        if let reason = validateBoundary(at: time, stopRequested: stopRequested) {
            return .stop(reason: reason)
        }
        guard attempt < Self.maximumAttempts else {
            return .stop(reason: finish(.attemptsExhausted))
        }
        let requestedDelay = max(1, TimeInterval(attempt) * 0.5)
        let delay = min(requestedDelay, earliestDeadline.time - time)
        attempt += 1
        return .retry(nextAttempt: attempt, delaySeconds: delay)
    }

    private var earliestDeadline: (
        time: TimeInterval,
        reason: AutoLevelWindowAvailabilityRetryStopReason
    ) {
        var result: (time: TimeInterval, reason: AutoLevelWindowAvailabilityRetryStopReason) = (
            sessionDeadline, .sessionExpired
        )
        if let actionDeadline, actionDeadline < result.time {
            result = (actionDeadline, .actionExpired)
        }
        let recoveryDeadline = startedAt + Self.maximumRecoveryDuration
        if recoveryDeadline < result.time {
            result = (recoveryDeadline, .recoveryExpired)
        }
        return result
    }

    @discardableResult
    private mutating func finish(
        _ reason: AutoLevelWindowAvailabilityRetryStopReason
    ) -> AutoLevelWindowAvailabilityRetryStopReason {
        terminalReason = reason
        return reason
    }
}
