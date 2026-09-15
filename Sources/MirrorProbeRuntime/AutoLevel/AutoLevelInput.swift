import AppKit
import CoreGraphics
import Darwin
import Foundation
import MirrorProbeCore

extension MirrorProbeRuntime {
    static func activateAndPreflightAutomationAction(
        _ request: AutoLevelActionRequest,
        identity: AutoLevelWindowIdentity,
        expectedFrame: CGRect,
        inputMode: AutoLevelInputMode,
        expectedFocusSourceProcessID: Int32?,
        activationAttempt: Int,
        activationSettleDelayMilliseconds: Int,
        battleSessionID: String?,
        allAutoStatus: AutoLevelAllAutoStatus,
        battleStatus: AutoLevelBattleStatus,
        captureRecorder: AutomationCaptureRecorder,
        windowRecovery: AutomationWindowRecoveryContext,
        actionDeadline: TimeInterval,
        expectedResultPage: MissionSuccessPageIdentity?
    ) async throws -> AutomationActionPreflightResult {
        guard request.intent != .enableAllAuto else {
            throw ProbeError.unsafeWindow(
                "the auto-level runner never presses the 全部自動 toggle"
            )
        }
        guard let runningApplication = NSRunningApplication(
            processIdentifier: identity.processID
        ) else {
            // Signal zero checks only existence/permission and never signals or launches the
            // process. ESRCH or an unknown error is terminal; a live PID permits another full
            // preflight, not input. Window ID, geometry and page are revalidated after recovery.
            let processCheck = kill(identity.processID, 0)
            let processError = processCheck == 0 ? 0 : errno
            let processIsRunning = processCheck == 0 || processError == EPERM
            let processStatus = processIsRunning ? "running"
                : (processError == ESRCH ? "notFound" : "unavailable")
            let detail = "expectedPID=\(identity.processID), expectedWindowID=\(identity.windowID), "
                + "appKitResolved=false, processStatus=\(processStatus), processCheckErrno=\(processError)"
            FileHandle.standardError.write(Data("applicationResolution: \(detail)\n".utf8))
            return .applicationUnavailable(processIsRunning: processIsRunning, detail: detail)
        }
        guard !runningApplication.isTerminated,
              runningApplication.processIdentifier == identity.processID,
              runningApplication.bundleIdentifier == mirrorBundleIdentifier
        else {
            throw ProbeError.unsafeWindow(
                "the resolved iPhone Mirroring application terminated or its identity changed; "
                    + "expectedPID=\(identity.processID), expectedWindowID=\(identity.windowID)"
            )
        }
        let activateReturned: Bool?
        if inputMode == .foreground {
            guard let expectedFocusSourceProcessID else {
                throw ProbeError.unsafeWindow("the original focused application is unavailable")
            }
            let alreadyFrontmost = ForegroundApplicationFocus.currentApplication?
                .processIdentifier == identity.processID
            activateReturned = alreadyFrontmost
                ? nil
                : ForegroundApplicationActivation.request(
                    runningApplication, options: [.activateAllWindows],
                    expectedCurrentProcessID: expectedFocusSourceProcessID
                ).accepted
            // A process can already own focus while its window stacking is still settling.
            // Obstruction retries must wait too, then obtain entirely fresh page evidence.
            if !alreadyFrontmost || activationAttempt > 1 {
                try await Task.sleep(for: .milliseconds(activationSettleDelayMilliseconds))
            }
        } else {
            activateReturned = nil
        }
        if request.intent == .advanceMissionSuccess, inputMode == .foreground {
            AutomationWindowFocusDiagnostic.log(
                processID: identity.processID,
                point: CGPoint(
                    x: expectedFrame.minX + expectedFrame.width * request.target.point.x,
                    y: expectedFrame.minY + expectedFrame.height * request.target.point.y
                ),
                expectedFrame: expectedFrame
            )
        }
        // Keep the fresh capture after diagnostic reads so their latency cannot age the page
        // evidence used below. Diagnostics never replace the final input-boundary checks.
        let preflight = try await captureAutomationObservation(
            requestedID: identity.windowID,
            expectedIdentity: identity,
            expectedFrame: expectedFrame,
            captureRecorder: captureRecorder,
            recovery: windowRecovery,
            phase: "preflight",
            actionDeadline: actionDeadline
        )
        let activation: AutomationForegroundActivationSnapshot?
        if inputMode == .foreground {
            let frontmostApplication = ForegroundApplicationFocus.currentApplication
            let snapshot = AutomationForegroundActivationSnapshot(
                attempt: activationAttempt,
                maximumAttempts: AutoLevelForegroundActivationRetryState.maximumAttempts,
                activateReturned: activateReturned,
                targetApplicationIsActive: runningApplication.isActive,
                scWindowIsActive: preflight.window.isActive,
                expectedProcessID: identity.processID,
                frontmostProcessID: frontmostApplication?.processIdentifier,
                frontmostApplicationName: frontmostApplication?.localizedName,
                frontmostBundleIdentifier: frontmostApplication?.bundleIdentifier
            )
            guard snapshot.isReady else {
                return .activationContended(
                    observation: preflight,
                    activation: snapshot
                )
            }
            activation = snapshot
        } else {
            activation = nil
        }
        guard preflight.classification.state == request.observedState else {
            return .stateChanged(observation: preflight, activation: activation)
        }
        // Result pages can share state and coordinates. Every fresh confirmation, including
        // recovery from unknown, must preserve the original content identity when established.
        guard AutoLevelForegroundActivationRetryState.resultPageMatchesOriginal(
            intent: request.intent,
            expectedPage: expectedResultPage,
            classification: preflight.classification
        ) else {
            return .stateChanged(observation: preflight, activation: activation)
        }
        let runtime = AutoLevelRuntimeMetadata(
            observedAt: preflight.capturedAt,
            windowIdentity: identity,
            frameFingerprint: preflight.fingerprint,
            battleSessionID: battleSessionID,
            allAutoStatus: allAutoStatus,
            battleStatus: battleStatus
        )
        let candidates = AutoLevelSnapshot(
            classification: preflight.classification,
            runtime: runtime
        ).actionCandidates.filter { $0.intent == request.intent }
        guard candidates.count == 1,
              let confirmed = candidates.first,
              automationTargetsMatch(request.target, confirmed.target)
        else {
            throw ProbeError.unsafeWindow(
                "the named action target was missing, ambiguous, or moved during confirmation"
            )
        }
        if let retryPage = request.repeatSelectionRetryPage {
            guard request.intent == .selectMissionRepeat,
                  confirmed.target == request.target,
                  MissionRepeatSelectionProof.page(
                      in: preflight.classification, matching: confirmed.target
                  ) == retryPage
            else {
                throw ProbeError.unsafeWindow(
                    "the repeat-selection retry no longer has an empty stamp on its original result page"
                )
            }
        }
        return .confirmed(
            observation: preflight,
            target: confirmed.target,
            activation: activation
        )
    }

    static func postAutomationClick(
        _ request: AutoLevelActionRequest,
        confirmedTarget: AutoLevelActionTarget,
        using observation: AutomationObservation,
        activation: AutomationForegroundActivationSnapshot?,
        identity: AutoLevelWindowIdentity,
        expectedFrame: CGRect,
        inputMode: AutoLevelInputMode,
        actionDeadline: TimeInterval,
        sessionDeadline: TimeInterval?,
        stopURL: URL
    ) throws -> AutomationClickResult {
        guard request.intent != .enableAllAuto else {
            throw ProbeError.unsafeWindow(
                "the auto-level input boundary refused the 全部自動 toggle"
            )
        }
        guard observation.window.windowID == identity.windowID,
              observation.window.owningApplication?.processID == identity.processID,
              approximatelyEqual(observation.window.frame, expectedFrame, tolerance: 0.5)
        else {
            throw ProbeError.unsafeWindow("the preflight window identity or geometry changed")
        }
        let point = confirmedTarget.point
        let rect = confirmedTarget.rect
        guard rect.isValid,
              point.x >= rect.x, point.x <= rect.x + rect.width,
              point.y >= rect.y, point.y <= rect.y + rect.height,
              point.x >= 0.02, point.x <= 0.98, point.y >= 0.02, point.y <= 0.98,
              !isInsideAllAutoForbiddenRegion(point)
        else {
            throw ProbeError.unsafeWindow("the confirmed action target was outside the safe content area")
        }
        let clickPoint = CGPoint(
            x: expectedFrame.minX + expectedFrame.width * point.x,
            y: expectedFrame.minY + expectedFrame.height * point.y
        )
        let expectedGeometry = automationWindowGeometry(expectedFrame)
        let previousMouseLocation = inputMode == .foreground ? CGEvent(source: nil)?.location : nil
        var boundaryResult: AutomationClickResult?
        var authorizedPostTime: TimeInterval?
        let posted = try postSingleClick(
            at: clickPoint,
            processID: inputMode == .process ? identity.processID : nil
        ) {
            let windows = windowServerWindows() ?? []
            let currentWindow = windows.first { $0.identity.windowID == identity.windowID }
            let inputPointSnapshot = inputPointWindowSnapshot(
                at: clickPoint,
                expectedWindowFrame: expectedFrame,
                expectedProcessID: identity.processID,
                windows: windows
            )
            let topmostWindow = inputPointSnapshot.window
            let targetProcessTopmostWindow = windows.first {
                $0.identity.processID == identity.processID
                    && $0.alpha > 0.01
                    && $0.frame.contains(clickPoint)
            }
            let frontmostApplication = inputMode == .foreground
                ? ForegroundApplicationFocus.currentApplication : nil
            let frontmostProcessID = frontmostApplication?.processIdentifier
            let snapshot = AutoLevelInputSnapshot(
                windowIdentity: currentWindow?.identity,
                windowGeometry: currentWindow.map { automationWindowGeometry($0.frame) },
                frontmostProcessID: frontmostProcessID,
                topmostWindowIdentity: topmostWindow?.identity,
                targetProcessTopmostWindowIdentity: targetProcessTopmostWindow?.identity
            )
            let now = ProcessInfo.processInfo.systemUptime
            let stopRequested = applicationStopRequest.isRequested(stopFileURL: stopURL)
            guard let rejection = AutoLevelInputSafety.rejection(
                expectedWindowIdentity: identity,
                expectedWindowGeometry: expectedGeometry,
                inputMode: inputMode,
                snapshot: snapshot,
                now: now,
                actionDeadline: actionDeadline,
                sessionDeadline: sessionDeadline,
                stopRequested: stopRequested
            ) else {
                authorizedPostTime = now
                return true
            }
            switch rejection {
            case .stopRequested:
                boundaryResult = .stopRequested
                return false
            case .invalidTiming:
                throw ProbeError.unsafeWindow("the final input timing check was invalid")
            case .actionAuthorizationExpired:
                throw ProbeError.unsafeWindow(
                    "the action authorization expired during confirmation"
                )
            case .sessionRuntimeExpired:
                boundaryResult = .maximumRuntimeReached
                return false
            case .windowUnavailable:
                throw ProbeError.unsafeWindow(
                    "the requested window disappeared immediately before input"
                )
            case .windowIdentityChanged:
                throw ProbeError.unsafeWindow(
                    "the window identity changed immediately before input"
                )
            case .windowGeometryChanged:
                throw ProbeError.unsafeWindow(
                    "the window geometry changed immediately before input"
                )
            case .applicationNotFrontmost:
                guard AutoLevelForegroundActivationRetryState.permitsRetry(
                    after: rejection,
                    inputWasPosted: false,
                    inputMode: inputMode
                ) else {
                    throw ProbeError.unsafeWindow(
                        "the final input boundary rejected a non-retryable focus loss"
                    )
                }
                let boundarySnapshot = AutomationForegroundActivationSnapshot(
                    attempt: activation?.attempt ?? 1,
                    maximumAttempts: activation?.maximumAttempts
                        ?? AutoLevelForegroundActivationRetryState.maximumAttempts,
                    activateReturned: activation?.activateReturned,
                    targetApplicationIsActive: NSRunningApplication(
                        processIdentifier: identity.processID
                    )?.isActive ?? false,
                    scWindowIsActive: observation.window.isActive,
                    expectedProcessID: identity.processID,
                    frontmostProcessID: frontmostApplication?.processIdentifier,
                    frontmostApplicationName: frontmostApplication?.localizedName,
                    frontmostBundleIdentifier: frontmostApplication?.bundleIdentifier
                )
                boundaryResult = .foregroundActivationContended(
                    detail: boundarySnapshot.detail(
                        phase: "finalInputBoundary",
                        result: "focusContended"
                    )
                )
                return false
            case .clickPointObscured:
                let diagnostic = inputObstructionDetail(
                    request: request,
                    inputMode: inputMode,
                    attempt: activation?.attempt ?? 1,
                    point: clickPoint,
                    identity: identity,
                    frontmostProcessID: frontmostProcessID,
                    topmostWindow: topmostWindow,
                    targetProcessTopmostWindow: targetProcessTopmostWindow,
                    hitProcessID: inputPointSnapshot.hitProcessID,
                    hitError: inputPointSnapshot.hitError,
                    displayFrames: inputPointSnapshot.displayFrames,
                    windows: windows
                )
                // This boundary posts neither event. Only a known external obstruction can
                // enter the existing bounded retry loop; the next attempt recaptures the page
                // and must pass this unchanged topmost-window guard before posting anything.
                if AutoLevelForegroundActivationRetryState.permitsRetry(
                    after: rejection,
                    inputWasPosted: false,
                    inputMode: inputMode,
                    expectedWindowIdentity: identity,
                    snapshot: snapshot
                ) {
                    boundaryResult = .foregroundActivationContended(detail: diagnostic)
                    return false
                }
                let message = inputMode == .process
                    ? "another iPhone Mirroring window was above the locked mirror at the action point"
                    : "another window was above the confirmed action point immediately before input"
                throw ProbeError.unsafeWindow(message + "; " + diagnostic)
            }
        }
        guard posted else {
            guard let boundaryResult else {
                throw ProbeError.unsafeWindow(
                    "the final input boundary refused input without a classified reason"
                )
            }
            return boundaryResult
        }
        if let previousMouseLocation {
            CGWarpMouseCursorPosition(previousMouseLocation)
        }
        guard let authorizedPostTime else {
            throw ProbeError.unsafeWindow(
                "the input was posted without a recorded authorization timestamp"
            )
        }
        return .posted(at: authorizedPostTime)
    }

    /// `全部自動` is a persistent toggle, not an idempotent command. Keep a final
    /// coordinate-level deny-list at the input boundary so even a mislabeled detector target
    /// cannot switch automatic combat off.
    static func isInsideAllAutoForbiddenRegion(
        _ point: MirrorProbeCore.NormalizedPoint
    ) -> Bool {
        (0.15...0.45).contains(point.x)
            && (0.83...0.93).contains(point.y)
    }

    static func automationTargetsMatch(
        _ lhs: AutoLevelActionTarget,
        _ rhs: AutoLevelActionTarget
    ) -> Bool {
        lhs.name == rhs.name
            && abs(lhs.point.x - rhs.point.x) <= 0.02
            && abs(lhs.point.y - rhs.point.y) <= 0.02
            && abs(lhs.rect.width - rhs.rect.width) <= 0.05
            && abs(lhs.rect.height - rhs.rect.height) <= 0.05
    }
}
