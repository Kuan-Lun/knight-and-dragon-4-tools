import Foundation

public enum AutoLevelForegroundActivationRetryDecision: Equatable, Sendable {
    case retry(nextAttempt: Int, delayMilliseconds: Int)
    case exhausted(attempts: Int)
}

/// A bounded retry budget for focus contention detected before any input event is posted.
///
/// The caller must use this state only after it knows that neither mouse-down nor mouse-up was
/// sent. Window identity, geometry, target, capture, and timing failures remain terminal and must
/// never enter this retry state.
public struct AutoLevelForegroundActivationRetryState: Equatable, Sendable {
    public static let maximumAttempts = 3

    public private(set) var currentAttempt = 1

    public init() {}

    /// The live focused-process observation after settling is authoritative. Callers read it
    /// through AXFocusedApplication, failing closed on an unavailable or different process.
    /// AppKit activation and a separate NSRunningApplication.isActive handle are diagnostic:
    /// their asynchronous updates must not override the live focus observation.
    public static func activationIsReady(
        activateReturned: Bool,
        targetApplicationIsActive: Bool,
        frontmostProcessMatches: Bool
    ) -> Bool {
        _ = activateReturned
        _ = targetApplicationIsActive
        return frontmostProcessMatches
    }

    public static func permitsRetry(
        after rejection: AutoLevelInputRejection,
        inputWasPosted: Bool
    ) -> Bool {
        !inputWasPosted && rejection == .applicationNotFrontmost
    }

    public var settleDelayMilliseconds: Int {
        switch currentAttempt {
        case 1: 350
        case 2: 600
        default: 900
        }
    }

    public mutating func recordUnpostedFocusFailure()
        -> AutoLevelForegroundActivationRetryDecision
    {
        guard currentAttempt < Self.maximumAttempts else {
            return .exhausted(attempts: currentAttempt)
        }

        let retryDelay: Int
        switch currentAttempt {
        case 1: retryDelay = 250
        default: retryDelay = 500
        }
        currentAttempt += 1
        return .retry(nextAttempt: currentAttempt, delayMilliseconds: retryDelay)
    }
}
