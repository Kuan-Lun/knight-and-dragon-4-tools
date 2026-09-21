import CoreGraphics
import Foundation
import MirrorProbeCore
import ScreenCaptureKit

/// The window facts the automation loop reads from a capture. A value type, so tests can
/// build observations without a live ScreenCaptureKit window; the loop never needs more.
struct AutomationWindowSnapshot: Equatable, Sendable {
    let windowID: UInt32
    let processID: Int32?
    let frame: CGRect
    /// ScreenCaptureKit streaming state; recorded for capture diagnostics, never used as focus.
    let isActive: Bool

    init(windowID: UInt32, processID: Int32?, frame: CGRect, isActive: Bool) {
        self.windowID = windowID
        self.processID = processID
        self.frame = frame
        self.isActive = isActive
    }

    init(_ window: SCWindow) {
        self.init(
            windowID: window.windowID,
            processID: window.owningApplication?.processID,
            frame: window.frame,
            isActive: window.isActive
        )
    }
}

/// Capture time precedes recognition so its latency never becomes sampled stability.
struct AutomationCapturedFrame {
    let capturedAt: TimeInterval
    let windowContinuityGeneration: UInt64
    let window: AutomationWindowSnapshot
    /// Recognition canvas (see MirrorContentLayout); identical to the capture at 406x890.
    let image: CGImage
    let rgba: RGBAFrame
    let layout: MirrorContentLayout
    let metrics: FrameMetrics
}

struct AutomationObservation {
    let capturedAt: TimeInterval
    let recognitionDurationSeconds: TimeInterval
    let windowContinuityGeneration: UInt64
    let window: AutomationWindowSnapshot
    /// Recognition canvas; action targets are canvas-normalized (see MirrorContentLayout).
    let image: CGImage
    let rgba: RGBAFrame
    let layout: MirrorContentLayout
    let metrics: FrameMetrics
    let stallEvidence: BattleStallFrameEvidence
    let activityEvidence: BattleActivityFrameEvidence
    let classification: GameStateClassification
    let fingerprint: String
}

/// A missing window or changed frame invalidates pixel continuity, even within one poll.
final class AutomationWindowRecoveryContext {
    let stopURL: URL
    let sessionDeadline: TimeInterval?
    private(set) var generation: UInt64 = 0
    private(set) var currentFrame: CGRect?
    private var captureLayout: CaptureLayout?
    private(set) var contentLayout: MirrorContentLayout?

    private struct CaptureLayout: Equatable {
        let width: Int
        let height: Int
        let bytesPerRow: Int
    }

    init(stopURL: URL, sessionDeadline: TimeInterval?, initialFrame: CGRect? = nil) {
        self.stopURL = stopURL
        self.sessionDeadline = sessionDeadline
        currentFrame = initialFrame
    }

    func interruptContinuity() {
        generation &+= 1
        captureLayout = nil
    }

    /// Moving between displays can change backing pixels even when the point frame is equal.
    func recordCaptureLayout(width: Int, height: Int, bytesPerRow: Int) {
        let layout = CaptureLayout(width: width, height: height, bytesPerRow: bytesPerRow)
        if let captureLayout, captureLayout != layout { interruptContinuity() }
        captureLayout = layout
    }

    /// The window zoom level determines where the phone content sits inside the capture.
    /// Log the geometry once per change so run diagnostics explain canvas coordinates.
    func recordContentLayout(_ layout: MirrorContentLayout) {
        guard contentLayout != layout else { return }
        contentLayout = layout
        FileHandle.standardError.write(Data("mirrorContentLayout: \(layout.summary)\n".utf8))
    }

    /// Called only after the same window has returned a stable frame during bounded recovery.
    /// Captures must be rebuilt; this value never authorizes an input by itself.
    func acceptStableFrame(_ frame: CGRect) { currentFrame = frame }

    func checkSessionBoundary() throws {
        if applicationStopRequest.isRequested(stopFileURL: stopURL) {
            throw AutomationCaptureInterruption.stopRequested
        }
        if let sessionDeadline, ProcessInfo.processInfo.systemUptime >= sessionDeadline {
            throw AutomationCaptureInterruption.sessionExpired
        }
    }
}

enum AutomationCaptureInterruption: LocalizedError {
    case stopRequested
    case sessionExpired

    var errorDescription: String? {
        switch self {
        case .stopRequested: "Capture stopped because an application Quit or STOP file was detected."
        case .sessionExpired: "Capture stopped because the session time limit was reached."
        }
    }
}

struct BufferedAutomationCapture {
    let sequence: UInt64
    let capturedAt: TimeInterval
    let state: GameState
    let fingerprint: String
    let image: CGImage
}

/// Keeps only the most recent successfully analyzed captures in memory. Nothing in this buffer
/// reaches disk during a normal error-level run.
final class AutomationCaptureRecorder {
    private var nextSequence: UInt64 = 1
    private var buffer = RecentCaptureBuffer<BufferedAutomationCapture>(capacity: 8)

    func record(_ observation: AutomationObservation) {
        record(
            image: observation.image,
            capturedAt: observation.capturedAt,
            state: observation.classification.state,
            fingerprint: observation.fingerprint
        )
    }

    /// Retention needs only immutable capture evidence, independent of a live SCWindow.
    func record(image: CGImage, capturedAt: TimeInterval, state: GameState, fingerprint: String) {
        buffer.append(BufferedAutomationCapture(
            sequence: nextSequence,
            capturedAt: capturedAt,
            state: state,
            fingerprint: fingerprint,
            image: image
        ))
        nextSequence &+= 1
    }

    var capturesOldestFirst: [BufferedAutomationCapture] {
        buffer.elementsOldestFirst
    }
}

struct AutomationForegroundActivationSnapshot {
    let attempt: Int
    let maximumAttempts: Int
    let activateReturned: Bool?
    let targetApplicationIsActive: Bool
    /// ScreenCaptureKit streaming state; recorded for capture diagnostics, never used as focus.
    let scWindowIsActive: Bool
    let expectedProcessID: Int32
    let frontmostProcessID: Int32?
    let frontmostApplicationName: String?
    let frontmostBundleIdentifier: String?

    var isReady: Bool {
        AutoLevelForegroundActivationRetryState.activationIsReady(
            activateReturned: activateReturned ?? false,
            targetApplicationIsActive: targetApplicationIsActive,
            frontmostProcessMatches: frontmostProcessID == expectedProcessID
        )
    }

    func detail(phase: String, result: String) -> String {
        let actualPID = frontmostProcessID.map(String.init) ?? "none"
        let actualName = frontmostApplicationName.map { String(reflecting: $0) } ?? "none"
        let actualBundle = frontmostBundleIdentifier.map { String(reflecting: $0) } ?? "none"
        let activationRequest = activateReturned.map(String.init) ?? "notRequestedAlreadyFrontmost"
        return "phase=\(phase), attempt=\(attempt)/\(maximumAttempts), "
            + "activationRequestAccepted=\(activationRequest), focusSource=Accessibility, "
            + "appKitTargetIsActive=\(targetApplicationIsActive), "
            + "scWindowIsActive=\(scWindowIsActive), expectedPID=\(expectedProcessID), "
            + "frontmostPID=\(actualPID), frontmostApplicationName=\(actualName), "
            + "frontmostBundleIdentifier=\(actualBundle), result=\(result), "
            + "noInputPosted=true"
    }
}

enum AutomationActionPreflightResult {
    // Produced only before activation, capture, or input. No observation is invented for a
    // missing AppKit handle; the caller retains the pending request and its original deadline.
    case applicationUnavailable(processIsRunning: Bool, detail: String)
    case confirmed(
        observation: AutomationObservation,
        target: AutoLevelActionTarget,
        activation: AutomationForegroundActivationSnapshot?
    )
    case stateChanged(
        observation: AutomationObservation,
        activation: AutomationForegroundActivationSnapshot?
    )
    case activationContended(
        observation: AutomationObservation,
        activation: AutomationForegroundActivationSnapshot
    )
}

enum AutomationClickResult {
    case posted(at: TimeInterval, cursorDisturbed: Bool)
    case stopRequested
    case maximumRuntimeReached
    case foregroundActivationContended(detail: String)
}

struct AutomationTemporalFrame {
    let rgba: RGBAFrame
    let context: BattleWindowContext
    let inputGeneration: UInt64
}

enum AutomationVisualConfirmationResult {
    case confirmed(BattleVisualStabilityConfirmation, AutomationObservation, BattleStallAssessment)
    case rejected(AutomationObservation, detail: String)
    case interrupted(AutomationCaptureInterruption)
}

struct VerifiedAutomaticBattleProgress {
    let battleSessionID: String
    let inputGeneration: UInt64

    func matches(battleSessionID: String?, inputGeneration: UInt64) -> Bool {
        guard let battleSessionID else { return false }
        return self.battleSessionID == battleSessionID
            && self.inputGeneration == inputGeneration
    }
}

struct AutomationBattleTracker {
    private(set) var currentID: String?
    private(set) var sequence = 0
    private var previousStableState: GameState?

    mutating func observe(state: GameState, sessionID: String) -> String? {
        if state == .battleEncounterPrompt, previousStableState != .battleEncounterPrompt {
            sequence += 1
            currentID = "\(sessionID)-battle-\(sequence)"
        } else if currentID == nil, isBattleFamily(state) {
            sequence += 1
            currentID = "\(sessionID)-battle-\(sequence)"
        }

        if isMissionResult(state) {
            currentID = nil
        }
        if state != .unknown {
            previousStableState = state
        }
        return currentID
    }

    private func isBattleFamily(_ state: GameState) -> Bool {
        switch state {
        case .battle, .battleEncounterPrompt, .battleEventPrompt, .defeatPrompt,
             .retreatConfirmation, .defeat:
            return true
        default:
            return false
        }
    }

    private func isMissionResult(_ state: GameState) -> Bool {
        switch state {
        case .missionComplete, .missionCompleteRepeatSelected,
             .missionFailed, .missionFailedRepeatSelected:
            return true
        default:
            return false
        }
    }
}

/// A tap posted while the user moves the mouse becomes a drag and is never received. When the
/// cursor was found away from the click point and the next capture still shows the page the
/// action was confirmed on, nothing happened: re-post right away instead of waiting for the
/// controller's acknowledgement timeout, which remains the bounded backstop.
enum AutomationClickRepostPolicy {
    static let maximumReposts = 2

    /// Largest mean absolute RGBA difference (0...1) between the confirmed page and the capture
    /// after the tap that still counts as the same page. A result page keeps changing single
    /// pixels for a few seconds after a dialog closes (one page, three fingerprints in
    /// logs/auto-level-20260920-200804), so byte identity alone misses a lost tap there. A
    /// received tap moved these pages by 0.07 or more; the lost one measured 0.00008.
    static let unchangedPageMaximumMeanAbsoluteDifference = 0.002

    static func shouldRepost(cursorDisturbed: Bool, frameUnchanged: Bool, repostsSoFar: Int) -> Bool {
        cursorDisturbed && frameUnchanged && repostsSoFar >= 0 && repostsSoFar < maximumReposts
    }

    /// Only a tap that merely advances or dismisses the page it was confirmed on may treat a
    /// settling page as unchanged. A repeat row toggles, a retreat confirmation is one-shot, and
    /// the stalled-battle retreat is confirmed on a static frame: those keep byte identity.
    static func toleratesSettlingPage(_ intent: AutoLevelActionIntent) -> Bool {
        switch intent {
        case .advanceMissionSuccess, .advanceMissionFailure, .pressWideModalTopButton,
             .closeBattlePrompt:
            return true
        case .selectMissionRepeat, .confirmLootCollection, .recruitAdventurer, .leaveAdventurer,
             .requestRetreat, .confirmRetreatWithoutTalisman, .enableAllAuto:
            return false
        }
    }

    /// Byte identity always counts. Otherwise the same classified state, the same result page
    /// identity, the confirmed target as the only candidate, and a mean absolute difference at
    /// or below the settling bound count only for the intents above.
    static func frameUnchanged(
        intent: AutoLevelActionIntent,
        fingerprintsEqual: Bool,
        sameState: Bool,
        samePage: Bool,
        sameTarget: Bool,
        meanAbsoluteDifference: Double?
    ) -> Bool {
        if fingerprintsEqual { return true }
        guard toleratesSettlingPage(intent), sameState, samePage, sameTarget,
              let difference = meanAbsoluteDifference,
              difference.isFinite, difference >= 0,
              difference <= unchangedPageMaximumMeanAbsoluteDifference
        else { return false }
        return true
    }
}

/// What the capture after a posted tap shares with the page the tap was confirmed on.
struct AutomationRepostPageComparison {
    let fingerprintsEqual: Bool
    let sameState: Bool
    let samePage: Bool
    let sameTarget: Bool
    let meanAbsoluteDifference: Double?

    var detail: String {
        "fingerprintsEqual=\(fingerprintsEqual), sameState=\(sameState), samePage=\(samePage), "
            + "sameTarget=\(sameTarget), meanAbsoluteDifference="
            + (meanAbsoluteDifference.map { String($0) } ?? "unavailableAfterWindowChange")
    }
}
