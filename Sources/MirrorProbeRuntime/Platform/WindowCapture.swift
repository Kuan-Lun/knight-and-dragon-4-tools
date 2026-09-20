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

    /// Keep the locked identity through display changes. The recovery selector requires
    /// repeated stable geometry before a fresh capture can provide evidence for later input.
    static func selectAutomationWindow(
        requestedID: UInt32,
        expectedIdentity: AutoLevelWindowIdentity,
        expectedFrame: CGRect,
        recovery: AutomationWindowRecoveryContext,
        phase: String,
        deadline: AutomationCaptureDeadline?
    ) async throws -> SCWindow {
        guard requestedID == expectedIdentity.windowID else {
            throw ProbeError.unsafeWindow("the requested window does not match the locked identity")
        }
        let currentExpectedFrame = recovery.currentFrame ?? expectedFrame
        do {
            return try await AutomationWindowSelectionRecovery.select(
                expectedIdentity: expectedIdentity,
                expectedFrame: currentExpectedFrame,
                recovery: recovery,
                deadline: deadline,
                query: {
                    try await mirrorWindowCandidates().map { window in
                        AutomationWindowSelectionCandidate(
                            window: window,
                            identity: AutoLevelWindowIdentity(
                                processID: window.owningApplication?.processID ?? 0,
                                windowID: window.windowID
                            ),
                            frame: window.frame,
                            isEligible: isEligibleMirrorWindow(window)
                        )
                    }
                },
                diagnostic: { outcome, candidates, retry, detail in
                    logWindowAvailability(
                        outcome, phase: phase, identity: expectedIdentity,
                        expectedFrame: currentExpectedFrame, candidates: candidates.map(\.window),
                        retry: retry, detail: detail
                    )
                }
            )
        } catch ProbeError.unsafeWindow(let reason) {
            throw ProbeError.unsafeWindow("\(reason); phase=\(phase)")
        }
    }

    static func logWindowAvailability(
        _ outcome: String,
        phase: String,
        identity: AutoLevelWindowIdentity,
        expectedFrame: CGRect,
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
            "elapsedRecoverySeconds": ProcessInfo.processInfo.systemUptime - retry.startedAt,
            "expectedPID": identity.processID, "expectedWindowID": identity.windowID,
            "expectedFrame": ["x": expectedFrame.minX, "y": expectedFrame.minY,
                              "width": expectedFrame.width, "height": expectedFrame.height],
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
                "width": window.frame.width, "height": window.frame.height,
                "deltaFromExpectedFrame": [
                    "x": window.frame.minX - expectedFrame.minX,
                    "y": window.frame.minY - expectedFrame.minY,
                    "width": window.frame.width - expectedFrame.width,
                    "height": window.frame.height - expectedFrame.height
                ]
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
