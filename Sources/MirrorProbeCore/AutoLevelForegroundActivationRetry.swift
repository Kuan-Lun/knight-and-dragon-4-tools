import Foundation

public enum AutoLevelForegroundActivationRetryDecision: Equatable, Sendable {
    case retry(nextAttempt: Int, delayMilliseconds: Int)
    case exhausted(attempts: Int)
}

/// A shared, bounded retry budget for foreground focus contention, a known external window
/// obscuring the locked target, a transient application lookup failure for a confirmed live
/// process, or a transient unknown result-page confirmation before input.
///
/// The caller must use this state only after it knows that neither mouse-down nor mouse-up was
/// sent. Each retry requires reactivation and fresh observation, then full validation of the
/// original request within its unchanged deadline; it never authorizes the rejected frame.
/// Window identity, geometry, target, capture, and timing failures remain terminal. Input-point
/// obstructions with an unknown owner or another window of the target process also remain terminal.
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
        recordUnpostedFailure()
    }

    /// A missing application handle may be transient only while the locked PID is independently
    /// confirmed alive. Unknown liveness and exited processes remain terminal. This is also valid
    /// in process input mode; retrying the lookup does not itself require or authorize focus.
    /// The caller must re-resolve the same application, validate its identity and window, and
    /// capture fresh evidence within the original action and session deadlines before input.
    /// Resolution, focus, and result observation failures all spend this same attempt budget.
    public mutating func recordUnpostedApplicationResolutionFailure(
        processIsRunning: Bool,
        inputWasPosted: Bool
    ) -> AutoLevelForegroundActivationRetryDecision? {
        guard processIsRunning, !inputWasPosted else { return nil }
        return recordUnpostedFailure()
    }

    /// A temporary overlay or uncertain stamp can interrupt result recognition during preflight.
    /// This permits another complete observation of the same unposted result request, including
    /// repeat selection. No toggle has been posted by this request when this method is used.
    /// The caller must retain its original deadline, page identity, target, and post-attempt
    /// count. An unknown frame never authorizes input; explicit adverse evidence stays terminal.
    public mutating func recordUnpostedResultObservationFailure(
        intent: AutoLevelActionIntent,
        classification: GameStateClassification,
        inputWasPosted: Bool
    ) -> AutoLevelForegroundActivationRetryDecision? {
        guard !inputWasPosted,
              [.advanceMissionSuccess, .advanceMissionFailure, .selectMissionRepeat].contains(intent),
              classification.state == .unknown,
              classification.allowedActions.isEmpty,
              classification.policyGatedActions.isEmpty,
              classification.evidence.allSatisfy({
                  switch $0.kind {
                  case .lowConfidenceMarker, .missionCompleteTitle, .missionFailedTitle,
                       .missionRepeatOption, .repeatSelectedMarker, .repeatUnselectedMarker,
                       .missionExperiencePage, .missionLootPage:
                      return true
                  default:
                      return false
                  }
              })
        else {
            return nil
        }
        return recordUnpostedFailure()
    }

    /// A restored result must retain any content-page identity established by the original
    /// request. Success advances always require an identity; other result actions preserve it
    /// when available. Matching the state or shared coordinates alone is not a page check.
    public static func resultPageMatchesOriginal(
        intent: AutoLevelActionIntent,
        expectedPage: MissionSuccessPageIdentity?,
        classification: GameStateClassification
    ) -> Bool {
        switch intent {
        case .advanceMissionSuccess:
            guard let expectedPage else { return false }
            return MissionSuccessPageIdentity.resolve(in: classification) == expectedPage
        case .advanceMissionFailure, .selectMissionRepeat:
            guard let expectedPage else { return true }
            return MissionSuccessPageIdentity.resolve(in: classification) == expectedPage
        default:
            return true
        }
    }

    private mutating func recordUnpostedFailure()
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
