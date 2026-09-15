import AppKit
import ScreenCaptureKit

extension MirrorProbeRuntime {
    @MainActor
    static func establishAppKitConnection() {
        // ScreenCaptureKit needs an AppKit/WindowServer connection. Commands that only
        // analyze an existing image deliberately avoid registering as a GUI application.
        _ = NSApplication.shared
    }

    static func windowReport(_ window: SCWindow) -> WindowReport {
        let app = window.owningApplication
        return WindowReport(
            windowID: window.windowID,
            processID: app?.processID ?? 0,
            applicationName: app?.applicationName ?? "",
            bundleIdentifier: app?.bundleIdentifier ?? "",
            title: window.title ?? "",
            x: window.frame.origin.x,
            y: window.frame.origin.y,
            width: window.frame.width,
            height: window.frame.height,
            onScreen: window.isOnScreen,
            active: window.isActive
        )
    }
}
