import Foundation

public enum AutoLevelForegroundActivationRetryDecision: Equatable, Sendable {
    case retry(nextAttempt: Int, delayMilliseconds: Int)
    case exhausted(attempts: Int)
}

/// A bounded retry budget for foreground focus contention or a known external window obscuring
/// the locked target, detected before any input event is posted.
///
/// The caller must use this state only after it knows that neither mouse-down nor mouse-up was
/// sent. A retry requires reactivation and fresh observation and authorization; it never authorizes
/// the rejected event. Window identity, geometry, target, capture, timing, and unknown or same-process
/// obstruction failures remain terminal and must never enter this retry state.
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

    /// Allows a new foreground attempt after an unposted rejection. An obscured point is retryable
    /// only when the locked window remains focused and topmost within its process, and a known
    /// window from another process covers it. Missing observations fail closed.
    public static func permitsRetry(
        after rejection: AutoLevelInputRejection,
        inputWasPosted: Bool,
        inputMode: AutoLevelInputMode = .foreground,
        expectedWindowIdentity: AutoLevelWindowIdentity? = nil,
        snapshot: AutoLevelInputSnapshot? = nil
    ) -> Bool {
        guard !inputWasPosted, inputMode == .foreground else { return false }
        switch rejection {
        case .applicationNotFrontmost:
            return true
        case .clickPointObscured:
            guard let expectedWindowIdentity,
                  let snapshot,
                  snapshot.windowIdentity == expectedWindowIdentity,
                  snapshot.frontmostProcessID == expectedWindowIdentity.processID,
                  snapshot.targetProcessTopmostWindowIdentity == expectedWindowIdentity,
                  let topmostWindowIdentity = snapshot.topmostWindowIdentity
            else { return false }
            return topmostWindowIdentity.processID != expectedWindowIdentity.processID
        default:
            return false
        }
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

        currentAttempt += 1
        // Keep the failure backoff separate from the next attempt's activation settling delay.
        return .retry(nextAttempt: currentAttempt, delayMilliseconds: 1_000)
    }
}
