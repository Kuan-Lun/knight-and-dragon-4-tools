import CoreGraphics
import Foundation
import MirrorProbeCore

/// A borrowed foreground focus that the loop gives back later. Production uses
/// `ForegroundFocusBorrow`; tests record the borrow and its restoration instead.
protocol AutomationFocusBorrow {
    var previousProcessID: Int32 { get }

    @discardableResult
    mutating func restore() -> ForegroundActivationRequest?
}

extension ForegroundFocusBorrow: AutomationFocusBorrow {}

/// What one activation preflight receives from the loop beyond the locked window context.
struct AutoLevelPreflightRequest {
    let request: AutoLevelActionRequest
    let expectedFocusSourceProcessID: Int32?
    let activationAttempt: Int
    let activationSettleDelayMilliseconds: Int
    let battleSessionID: String?
    let allAutoStatus: AutoLevelAllAutoStatus
    let battleStatus: AutoLevelBattleStatus
    let actionDeadline: TimeInterval
    let expectedResultPage: MissionSuccessPageIdentity?
    let battleRecognitionRecovery: BattleRecognitionRecoveryAssessment?
    let inputGeneration: UInt64
}

/// What one click on an already confirmed target receives from the loop.
struct AutoLevelClickRequest {
    let request: AutoLevelActionRequest
    let confirmedTarget: AutoLevelActionTarget
    let observation: AutomationObservation
    let activation: AutomationForegroundActivationSnapshot?
    let expectedFrame: CGRect
    let actionDeadline: TimeInterval
    let sessionDeadline: TimeInterval?
}

/// The macOS operations the automation loop performs, bound to one locked window. Production
/// runs `live`; tests script these so the unchanged loop runs offline and never posts input.
/// The loop's own policy, controller, detectors and reporting stay exactly the production code.
struct AutoLevelLoopOperations {
    var now: () -> TimeInterval
    var sleep: (TimeInterval) async throws -> Void
    var captureObservation: (
        _ phase: String, _ deadline: AutomationCaptureDeadline?
    ) async throws -> AutomationObservation
    var confirmVisualStability: (
        _ confirmation: BattleVisualStabilityConfirmation,
        _ anchor: AutomationObservation,
        _ inputGeneration: UInt64
    ) async throws -> AutomationVisualConfirmationResult
    var borrowFocus: (_ targetProcessID: Int32) -> (any AutomationFocusBorrow)?
    var activateAndPreflight: (AutoLevelPreflightRequest) async throws -> AutomationActionPreflightResult
    var postClick: (AutoLevelClickRequest) throws -> AutomationClickResult

    static func live(
        identity: AutoLevelWindowIdentity,
        initialFrame: CGRect,
        inputMode: AutoLevelInputMode,
        captureRecorder: AutomationCaptureRecorder,
        windowRecovery: AutomationWindowRecoveryContext,
        stopURL: URL
    ) -> AutoLevelLoopOperations {
        AutoLevelLoopOperations(
            now: { ProcessInfo.processInfo.systemUptime },
            sleep: { try await Task.sleep(for: .seconds($0)) },
            captureObservation: { phase, deadline in
                try await MirrorProbeRuntime.captureAutomationObservation(
                    requestedID: identity.windowID,
                    expectedIdentity: identity,
                    expectedFrame: windowRecovery.currentFrame ?? initialFrame,
                    captureRecorder: captureRecorder,
                    recovery: windowRecovery,
                    phase: phase,
                    deadline: deadline
                )
            },
            confirmVisualStability: { confirmation, anchor, inputGeneration in
                try await MirrorProbeRuntime.confirmAutomationVisualStability(
                    confirmation,
                    anchor: anchor,
                    identity: identity,
                    expectedFrame: windowRecovery.currentFrame ?? initialFrame,
                    inputGeneration: inputGeneration,
                    sessionDeadline: windowRecovery.sessionDeadline,
                    stopURL: stopURL,
                    captureRecorder: captureRecorder,
                    windowRecovery: windowRecovery
                )
            },
            borrowFocus: { ForegroundFocusBorrow(targetProcessID: $0) },
            activateAndPreflight: { preflight in
                try await MirrorProbeRuntime.activateAndPreflightAutomationAction(
                    preflight.request,
                    identity: identity,
                    expectedFrame: windowRecovery.currentFrame ?? initialFrame,
                    inputMode: inputMode,
                    expectedFocusSourceProcessID: preflight.expectedFocusSourceProcessID,
                    activationAttempt: preflight.activationAttempt,
                    activationSettleDelayMilliseconds: preflight.activationSettleDelayMilliseconds,
                    battleSessionID: preflight.battleSessionID,
                    allAutoStatus: preflight.allAutoStatus,
                    battleStatus: preflight.battleStatus,
                    captureRecorder: captureRecorder,
                    windowRecovery: windowRecovery,
                    actionDeadline: preflight.actionDeadline,
                    expectedResultPage: preflight.expectedResultPage,
                    battleRecognitionRecovery: preflight.battleRecognitionRecovery,
                    inputGeneration: preflight.inputGeneration
                )
            },
            postClick: { click in
                try MirrorProbeRuntime.postAutomationClick(
                    click.request,
                    confirmedTarget: click.confirmedTarget,
                    using: click.observation,
                    activation: click.activation,
                    identity: identity,
                    expectedFrame: click.expectedFrame,
                    inputMode: inputMode,
                    actionDeadline: click.actionDeadline,
                    sessionDeadline: click.sessionDeadline,
                    stopURL: stopURL
                )
            }
        )
    }
}
