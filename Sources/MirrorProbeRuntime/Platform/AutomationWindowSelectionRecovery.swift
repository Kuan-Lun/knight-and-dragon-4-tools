import CoreGraphics
import Foundation
import MirrorProbeCore

struct AutomationWindowSelectionCandidate<Window> {
    let window: Window
    let identity: AutoLevelWindowIdentity
    let frame: CGRect
    let isEligible: Bool
}

/// A posted action's confirmation timeout must reach the controller on a fresh frame.
/// Both deadlines still bound recovery of an actually missing or changed window.
enum AutomationCaptureDeadline: Equatable, Sendable {
    case inputAuthorization(TimeInterval)
    case actionAcknowledgement(TimeInterval)

    var time: TimeInterval {
        switch self {
        case let .inputAuthorization(time), let .actionAcknowledgement(time): time
        }
    }
}

/// Recovery keeps the original process/window identity. A changed frame must remain exactly
/// equal across two queries at least one second apart before fresh captures can use it.
enum AutomationWindowSelectionRecovery {
    static func select<Window>(
        expectedIdentity: AutoLevelWindowIdentity,
        expectedFrame: CGRect,
        recovery: AutomationWindowRecoveryContext,
        deadline: AutomationCaptureDeadline?,
        query: () async throws -> [AutomationWindowSelectionCandidate<Window>],
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        pause: (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        diagnostic: (
            String, [AutomationWindowSelectionCandidate<Window>],
            AutoLevelWindowAvailabilityRetry, String
        ) -> Void
    ) async throws -> Window {
        let acceptedFrame = recovery.currentFrame ?? expectedFrame
        var retry: AutoLevelWindowAvailabilityRetry?
        var candidates: [AutomationWindowSelectionCandidate<Window>] = []
        var lastIssue = "notQueried"
        var queryCompleted = false
        var stableCandidate: (frame: CGRect, observedAt: TimeInterval)?

        func describe(_ frame: CGRect) -> String {
            "[x=\(frame.minX),y=\(frame.minY),width=\(frame.width),height=\(frame.height)]"
        }
        func detail(_ suffix: String) -> String {
            let actual = candidates.first {
                $0.identity.windowID == expectedIdentity.windowID
            }.map { describe($0.frame) } ?? "unavailable"
            return "reason=\(lastIssue), queryCompleted=\(queryCompleted), expectedFrame=\(describe(acceptedFrame)), "
                + "actualFrame=\(actual), \(suffix)"
        }
        func stop(_ reason: AutoLevelWindowAvailabilityRetryStopReason,
                  budget: AutoLevelWindowAvailabilityRetry) throws -> Never {
            let reasonDetail = detail("recoveryStop=\(reason), inputSuspendedDuringRecovery=true")
            diagnostic("exhausted", candidates, budget, reasonDetail)
            switch reason {
            case .stopRequested: throw AutomationCaptureInterruption.stopRequested
            case .sessionExpired: throw AutomationCaptureInterruption.sessionExpired
            default:
                throw ProbeError.unsafeWindow(
                    "the original iPhone Mirroring window did not become available with stable geometry "
                        + "within bounded capture recovery; \(reasonDetail)"
                )
            }
        }
        func checkBoundary() throws {
            do {
                try recovery.checkSessionBoundary()
            } catch {
                if let budget = retry {
                    diagnostic("exhausted", candidates, budget,
                               detail("recoveryStop=\(error), inputSuspendedDuringRecovery=true"))
                }
                throw error
            }
            let time = now()
            if var budget = retry {
                let rejection = budget.validateBoundary(at: time)
                retry = budget
                if let rejection { try stop(rejection, budget: budget) }
            } else {
                // Only pre-input authorization blocks an otherwise available window. An
                // acknowledgement timeout needs fresh pixels so the controller can safely
                // retry or stop; it remains a hard deadline if window recovery is needed.
                guard time.isFinite, time >= 0,
                      deadline?.time.isFinite != false,
                      deadline.map({ $0.time >= 0 }) != false
                else {
                    throw ProbeError.unsafeWindow("the window selection timing was invalid; "
                        + detail("recoveryStop=invalidClock"))
                }
                if case let .inputAuthorization(actionDeadline)? = deadline, time >= actionDeadline {
                    throw ProbeError.unsafeWindow("the action authorization expired during window selection; "
                        + detail("recoveryStop=actionExpired"))
                }
            }
        }

        while true {
            try checkBoundary()
            candidates = try await query()
            queryCompleted = true
            let candidate = candidates.first { $0.identity.windowID == expectedIdentity.windowID }
            if let candidate {
                if candidate.identity != expectedIdentity {
                    lastIssue = "identityChanged"
                } else if !candidate.isEligible {
                    lastIssue = "missing"
                } else {
                    lastIssue = MirrorProbeRuntime.approximatelyEqual(
                        candidate.frame, acceptedFrame, tolerance: 0.5
                    ) ? "available" : "geometryMismatch"
                }
            } else {
                lastIssue = "missing"
            }
            try checkBoundary()
            if let candidate {
                guard candidate.identity == expectedIdentity else {
                    throw ProbeError.unsafeWindow(
                        "the iPhone Mirroring process or window identity changed; "
                            + "expectedPID=\(expectedIdentity.processID), "
                            + "actualPID=\(candidate.identity.processID), "
                            + detail("identityChanged=true")
                    )
                }
                let validGeometry = AutoLevelWindowGeometry(
                    x: candidate.frame.origin.x, y: candidate.frame.origin.y,
                    width: candidate.frame.size.width, height: candidate.frame.size.height
                ).isValid
                if candidate.isEligible, validGeometry,
                   MirrorProbeRuntime.approximatelyEqual(candidate.frame, acceptedFrame, tolerance: 0.5) {
                    if let budget = retry {
                        diagnostic("recovered", candidates, budget,
                                   detail("sameIdentityAndGeometry=true"))
                    }
                    return candidate.window
                }
                lastIssue = candidate.isEligible ? "geometryMismatch" : "missing"
                if candidate.isEligible, validGeometry {
                    let observedAt = now()
                    if let stableCandidate, stableCandidate.frame == candidate.frame {
                        if observedAt - stableCandidate.observedAt >= 1, let budget = retry {
                            try checkBoundary()
                            recovery.acceptStableFrame(candidate.frame)
                            diagnostic("geometryRecovered", candidates, budget, detail(
                                "sameProcessAndWindow=true, stableSamples=2, minimumStableSeconds=1, "
                                    + "oldFrame=\(describe(acceptedFrame)), "
                                    + "newFrame=\(describe(candidate.frame))"
                            ))
                            return candidate.window
                        }
                    } else {
                        stableCandidate = (candidate.frame, observedAt)
                    }
                } else {
                    stableCandidate = nil
                }
            } else {
                lastIssue = "missing"
                stableCandidate = nil
            }
            if retry == nil {
                recovery.interruptContinuity()
                retry = AutoLevelWindowAvailabilityRetry(
                    startedAt: now(), sessionDeadline: recovery.sessionDeadline,
                    actionDeadline: deadline?.time
                )
            }
            guard var budget = retry else {
                throw ProbeError.requestedWindowNotFound(expectedIdentity.windowID)
            }
            diagnostic(lastIssue, candidates, budget,
                       detail("inputSuspendedDuringRecovery=true"))
            let decision = budget.recordMissing(at: now())
            retry = budget
            switch decision {
            case let .stop(reason): try stop(reason, budget: budget)
            case let .retry(_, delaySeconds):
                let wakeAt = now() + delaySeconds
                while true {
                    try checkBoundary()
                    let remaining = wakeAt - now()
                    guard remaining > 0 else { break }
                    try await pause(min(0.1, remaining))
                }
            }
        }
    }
}
