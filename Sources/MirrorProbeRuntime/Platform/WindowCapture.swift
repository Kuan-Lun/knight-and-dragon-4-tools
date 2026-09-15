import CoreGraphics
import Foundation
import MirrorProbeCore
import ScreenCaptureKit

extension MirrorProbeRuntime {
    static func ensureScreenCapturePermission() throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw ProbeError.screenCapturePermissionRequired
        }
    }

    static func ensurePostEventPermission() throws {
        guard CGPreflightPostEventAccess() else {
            throw ProbeError.postEventPermissionRequired
        }
    }

    static func mirrorWindowCandidates() async throws -> [SCWindow] {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            // Keep rejected mirror candidates for diagnostics; never persist another app's windows.
            return content.windows.filter {
                $0.owningApplication?.bundleIdentifier == mirrorBundleIdentifier
            }.sorted { $0.windowID < $1.windowID }
        } catch {
            throw ProbeError.captureFailed(error.localizedDescription)
        }
    }

    static func isEligibleMirrorWindow(_ window: SCWindow) -> Bool {
        window.windowLayer == 0 && window.isOnScreen
            && window.frame.width >= 120 && window.frame.height >= 200
    }

    static func mirrorWindows() async throws -> [SCWindow] {
        try await mirrorWindowCandidates().filter(isEligibleMirrorWindow)
    }

    /// Only a missing eligible window enters recovery. A replacement window, moved geometry,
    /// capture error, or lost permission never renews the session's locked identity.
    static func selectAutomationWindow(
        requestedID: UInt32,
        expectedIdentity: AutoLevelWindowIdentity,
        expectedFrame: CGRect,
        recovery: AutomationWindowRecoveryContext,
        phase: String,
        actionDeadline: TimeInterval?
    ) async throws -> SCWindow {
        var retry: AutoLevelWindowAvailabilityRetry?
        while true {
            try recovery.checkSessionBoundary()
            if var budget = retry {
                if let reason = budget.validateBoundary(
                    at: ProcessInfo.processInfo.systemUptime,
                    stopRequested: applicationStopRequest.isRequested(stopFileURL: recovery.stopURL)
                ) {
                    try throwWindowRecoveryStop(reason, windowID: requestedID, phase: phase)
                }
                retry = budget
            }
            let candidates = try await mirrorWindowCandidates()
            try recovery.checkSessionBoundary()
            if var budget = retry {
                if let reason = budget.validateBoundary(at: ProcessInfo.processInfo.systemUptime) {
                    try throwWindowRecoveryStop(reason, windowID: requestedID, phase: phase)
                }
                retry = budget
            }
            if let window = candidates.first(where: {
                $0.windowID == requestedID && isEligibleMirrorWindow($0)
            }) {
                guard window.owningApplication?.processID == expectedIdentity.processID,
                      window.windowID == expectedIdentity.windowID else {
                    throw ProbeError.unsafeWindow("the iPhone Mirroring process or window identity changed")
                }
                guard approximatelyEqual(window.frame, expectedFrame, tolerance: 0.5) else {
                    throw ProbeError.unsafeWindow("the iPhone Mirroring window moved or resized during automation")
                }
                if let budget = retry {
                    logWindowAvailability(
                        "recovered", phase: phase, identity: expectedIdentity,
                        candidates: candidates, retry: budget, detail: "sameIdentityAndGeometry=true"
                    )
                }
                return window
            }
            if retry == nil {
                recovery.interruptContinuity()
                retry = AutoLevelWindowAvailabilityRetry(
                    startedAt: ProcessInfo.processInfo.systemUptime,
                    sessionDeadline: recovery.sessionDeadline,
                    actionDeadline: actionDeadline
                )
            }
            guard var budget = retry else { throw ProbeError.requestedWindowNotFound(requestedID) }
            logWindowAvailability(
                "missing", phase: phase, identity: expectedIdentity,
                candidates: candidates, retry: budget, detail: "inputSuspendedDuringRecovery=true"
            )
            let decision = budget.recordMissing(
                at: ProcessInfo.processInfo.systemUptime,
                stopRequested: applicationStopRequest.isRequested(stopFileURL: recovery.stopURL)
            )
            retry = budget
            switch decision {
            case let .retry(_, delaySeconds):
                // Short slices keep STOP responsive without making another capture query.
                let wakeAt = ProcessInfo.processInfo.systemUptime + delaySeconds
                while ProcessInfo.processInfo.systemUptime < wakeAt {
                    try recovery.checkSessionBoundary()
                    try await Task.sleep(for: .seconds(min(
                        0.1, max(0, wakeAt - ProcessInfo.processInfo.systemUptime)
                    )))
                }
            case let .stop(reason):
                logWindowAvailability(
                    "exhausted", phase: phase, identity: expectedIdentity,
                    candidates: candidates, retry: budget, detail: String(describing: reason)
                )
                try throwWindowRecoveryStop(reason, windowID: requestedID, phase: phase)
            }
        }
    }

    static func throwWindowRecoveryStop(
        _ reason: AutoLevelWindowAvailabilityRetryStopReason,
        windowID: UInt32,
        phase: String
    ) throws -> Never {
        switch reason {
        case .stopRequested: throw AutomationCaptureInterruption.stopRequested
        case .sessionExpired: throw AutomationCaptureInterruption.sessionExpired
        default:
            throw ProbeError.unsafeWindow(
                "iPhone Mirroring window ID \(windowID) remained unavailable within the bounded "
                    + "capture recovery; phase=\(phase), reason=\(reason). "
                    + "This does not establish that the window was closed; see windowAvailability diagnostics."
            )
        }
    }

    static func logWindowAvailability(
        _ outcome: String,
        phase: String,
        identity: AutoLevelWindowIdentity,
        candidates: [SCWindow],
        retry: AutoLevelWindowAvailabilityRetry,
        detail: String
    ) {
        let app = NSRunningApplication(processIdentifier: identity.processID)
        let cgWindows = CGWindowListCopyWindowInfo(.optionIncludingWindow, identity.windowID)
            as? [[String: Any]] ?? []
        let exactCGWindow = cgWindows.first {
            ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == identity.windowID
        }
        let diagnostics: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "outcome": outcome, "phase": phase, "attempt": retry.attempt,
            "elapsedMissingSeconds": ProcessInfo.processInfo.systemUptime - retry.startedAt,
            "expectedPID": identity.processID, "expectedWindowID": identity.windowID,
            "targetProcessRunning": app.map { !$0.isTerminated } ?? false,
            "targetApplicationHidden": app.map { $0.isHidden as Any } ?? NSNull(),
            "frontmostPID": ForegroundApplicationFocus.read().processID.map { $0 as Any } ?? NSNull(),
            "windowServerHasExpectedID": exactCGWindow != nil,
            "windowServerOnScreen": exactCGWindow?[kCGWindowIsOnscreen as String] ?? NSNull(),
            "inputWasPostedForThisCapture": phase == "afterPost",
            "detail": detail,
            "candidatesBeforeEligibilityFilter": candidates.map { window -> [String: Any] in [
                "id": window.windowID,
                "pid": window.owningApplication?.processID ?? 0,
                "onScreen": window.isOnScreen, "layer": window.windowLayer,
                "x": window.frame.minX, "y": window.frame.minY,
                "width": window.frame.width, "height": window.frame.height
            ] }
        ]
        if let data = try? JSONSerialization.data(withJSONObject: diagnostics, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            FileHandle.standardError.write(Data("windowAvailability: \(text)\n".utf8))
        }
    }

    static func selectMirrorWindow(requestedID: UInt32?) async throws -> SCWindow {
        let windows = try await mirrorWindows()
        if let requestedID {
            guard let window = windows.first(where: { $0.windowID == requestedID }) else {
                throw ProbeError.requestedWindowNotFound(requestedID)
            }
            return window
        }
        guard !windows.isEmpty else {
            throw ProbeError.noMirrorWindow
        }
        guard windows.count == 1 else {
            throw ProbeError.ambiguousMirrorWindows(windows.map(\.windowID))
        }
        return windows[0]
    }

    static func capture(window: SCWindow) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = max(1, CGFloat(filter.pointPixelScale))
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(filter.contentRect.width * scale))
        configuration.height = max(1, Int(filter.contentRect.height * scale))
        configuration.showsCursor = false
        configuration.scalesToFit = false
        configuration.preservesAspectRatio = true
        configuration.captureResolution = .best
        configuration.ignoreShadowsSingleWindow = true
        configuration.ignoreGlobalClipSingleWindow = true
        configuration.shouldBeOpaque = true
        configuration.pixelFormat = kCVPixelFormatType_32BGRA

        do {
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
        } catch {
            throw ProbeError.captureFailed(error.localizedDescription)
        }
    }
}
