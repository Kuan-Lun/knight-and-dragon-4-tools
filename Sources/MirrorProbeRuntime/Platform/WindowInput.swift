import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import MirrorProbeCore

extension MirrorProbeRuntime {
    static func postSingleClick(
        at point: CGPoint,
        processID: Int32? = nil,
        validateBeforePost: () throws -> Bool = { true }
    ) throws -> Bool {
        guard let mouseDown = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: point,
            mouseButton: .left
        ), let mouseUp = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else {
            throw ProbeError.unsafeWindow("could not create the mouse events")
        }
        AutomationInputMarker.mark(mouseDown)
        AutomationInputMarker.mark(mouseUp)

        guard try validateBeforePost() else {
            return false
        }
        if let processID {
            mouseDown.postToPid(processID)
        } else {
            mouseDown.post(tap: .cghidEventTap)
        }
        usleep(60_000)
        if let processID {
            mouseUp.postToPid(processID)
        } else {
            mouseUp.post(tap: .cghidEventTap)
        }
        return true
    }

    static func topmostInputWindow(
        at point: CGPoint,
        expectedWindowFrame: CGRect,
        expectedProcessID: Int32,
        windows: [WindowServerWindow]? = nil
    ) -> WindowServerWindow? {
        inputPointWindowSnapshot(
            at: point,
            expectedWindowFrame: expectedWindowFrame,
            expectedProcessID: expectedProcessID,
            windows: windows ?? windowServerWindows() ?? []
        ).window
    }

    static func inputPointWindowSnapshot(
        at point: CGPoint,
        expectedWindowFrame: CGRect,
        expectedProcessID: Int32,
        windows: [WindowServerWindow]
    ) -> (
        window: WindowServerWindow?, hitProcessID: Int32?, hitError: Int32,
        displayFrames: [AutoLevelWindowGeometry]
    ) {
        // A full-display NotificationCenter surface can appear above ordinary windows while
        // AX still hits the mirror. Require actual display bounds, not just a large rectangle.
        let displayFrames = windows.contains {
            $0.ownerBundleIdentifier == "com.apple.notificationcenterui"
                && $0.layer == 21 && $0.alpha > 0.01 && $0.frame.contains(point)
        } ? activeDisplayFrames() : []
        let hit = accessibilityInputHit(at: point)
        let window = windows.first {
            $0.alpha > 0.01
                && $0.frame.contains(point)
                && !AutoLevelSystemBackdrop.isNonOccluding(
                    ownerBundleIdentifier: $0.ownerBundleIdentifier,
                    layer: $0.layer,
                    name: $0.name,
                    frame: automationWindowGeometry($0.frame),
                    expectedWindowFrame: automationWindowGeometry(expectedWindowFrame),
                    displayFrames: displayFrames,
                    hitProcessID: hit.processID,
                    hitError: hit.error,
                    expectedProcessID: expectedProcessID
                )
        }
        return (window, hit.processID, hit.error, displayFrames)
    }

    /// Serialize the exact rejected boundary sample, after input has already been vetoed.
    /// Do not re-query AX or window stacking here: later observations cannot explain this veto.
    static func inputObstructionDetail(
        request: AutoLevelActionRequest,
        inputMode: AutoLevelInputMode,
        attempt: Int,
        point: CGPoint,
        identity: AutoLevelWindowIdentity,
        frontmostProcessID: Int32?,
        topmostWindow: WindowServerWindow?,
        targetProcessTopmostWindow: WindowServerWindow?,
        hitProcessID: Int32?,
        hitError: Int32,
        displayFrames: [AutoLevelWindowGeometry],
        windows: [WindowServerWindow]
    ) -> String {
        func metadata(_ window: WindowServerWindow) -> [String: Any] {
            var result: [String: Any] = [
                "windowID": window.identity.windowID,
                "processID": window.identity.processID,
                "bundleIdentifier": window.ownerBundleIdentifier.map { $0 as Any } ?? NSNull(),
                "layer": window.layer, "alpha": window.alpha,
                "frame": ["x": window.frame.minX, "y": window.frame.minY,
                          "width": window.frame.width, "height": window.frame.height]
            ]
            // Keep system-surface names without collecting other applications' window titles.
            if ["com.apple.dock", "com.apple.notificationcenterui"].contains(
                window.ownerBundleIdentifier ?? ""
            ) {
                result["systemSurfaceName"] = window.name.map { $0 as Any } ?? NSNull()
            }
            return result
        }
        let diagnostic: [String: Any] = [
            "phase": "finalInputBoundary", "result": "clickPointObscured",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "requestID": request.requestID, "action": request.intent.rawValue,
            "inputMode": inputMode.rawValue, "attempt": attempt,
            "maximumAttempts": AutoLevelForegroundActivationRetryState.maximumAttempts,
            "noInputPosted": true,
            "point": ["x": point.x, "y": point.y],
            "expectedPID": identity.processID, "expectedWindowID": identity.windowID,
            "frontmostPID": frontmostProcessID.map { $0 as Any } ?? NSNull(),
            "axHitPID": hitProcessID.map { $0 as Any } ?? NSNull(), "axHitError": hitError,
            "activeDisplayFrames": displayFrames.map {
                ["x": $0.x, "y": $0.y, "width": $0.width, "height": $0.height]
            },
            "topmostWindow": topmostWindow.map { metadata($0) as Any } ?? NSNull(),
            "targetProcessTopmostWindow": targetProcessTopmostWindow.map { metadata($0) as Any } ?? NSNull(),
            "windowsAtPointFrontToBack": windows.filter {
                $0.alpha > 0.01 && $0.frame.contains(point)
            }.prefix(8).map(metadata)
        ]
        let detail: String
        if let data = try? JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            detail = json
        } else {
            detail = "phase=finalInputBoundary, result=clickPointObscured, "
                + "noInputPosted=true, diagnosticsEncodingFailed=true"
        }
        FileHandle.standardError.write(Data("inputBoundaryRejected: \(detail)\n".utf8))
        return detail
    }

    /// Use the same global coordinate system as CGWindowListCopyWindowInfo. Missing data or
    /// inconsistent display counts disable the NotificationCenter backdrop exception.
    static func activeDisplayFrames() -> [AutoLevelWindowGeometry] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success,
              count > 0, count <= 32
        else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        var actualCount: UInt32 = 0
        guard CGGetActiveDisplayList(count, &displays, &actualCount) == .success,
              actualCount == count
        else { return [] }
        return displays.map { automationWindowGeometry(CGDisplayBounds($0)) }
    }

    static func accessibilityInputHit(at point: CGPoint) -> (processID: Int32?, error: Int32) {
        let systemWideElement = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWideElement, 0.25)
        var hitElement: AXUIElement?
        let hitError = AXUIElementCopyElementAtPosition(
            systemWideElement,
            Float(point.x),
            Float(point.y),
            &hitElement
        )
        guard hitError == .success, let hitElement else {
            return (nil, hitError == .success ? AXError.noValue.rawValue : hitError.rawValue)
        }
        var processID: pid_t = 0
        let pidError = AXUIElementGetPid(hitElement, &processID)
        guard pidError == .success, processID > 0 else {
            return (nil, pidError == .success ? AXError.noValue.rawValue : pidError.rawValue)
        }
        return (processID, AXError.success.rawValue)
    }

    static func windowServerWindows() -> [WindowServerWindow]? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        return list.compactMap { entry in
            guard let alpha = (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
                  let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let boundsDictionary = entry[kCGWindowBounds as String] as? [String: Any],
                  let x = (boundsDictionary["X"] as? NSNumber)?.doubleValue,
                  let y = (boundsDictionary["Y"] as? NSNumber)?.doubleValue,
                  let width = (boundsDictionary["Width"] as? NSNumber)?.doubleValue,
                  let height = (boundsDictionary["Height"] as? NSNumber)?.doubleValue,
                  let windowNumber = entry[kCGWindowNumber as String] as? UInt32,
                  let ownerPID = entry[kCGWindowOwnerPID as String] as? Int32
            else {
                return nil
            }
            return WindowServerWindow(
                identity: AutoLevelWindowIdentity(
                    processID: ownerPID,
                    windowID: windowNumber
                ),
                frame: CGRect(x: x, y: y, width: width, height: height),
                alpha: alpha,
                layer: layer,
                name: entry[kCGWindowName as String] as? String,
                ownerBundleIdentifier: NSRunningApplication(
                    processIdentifier: ownerPID
                )?.bundleIdentifier
            )
        }
    }

    static func automationWindowGeometry(_ frame: CGRect) -> AutoLevelWindowGeometry {
        AutoLevelWindowGeometry(
            x: frame.minX,
            y: frame.minY,
            width: frame.width,
            height: frame.height
        )
    }

    static func approximatelyEqual(
        _ lhs: CGRect,
        _ rhs: CGRect,
        tolerance: CGFloat
    ) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }
}
