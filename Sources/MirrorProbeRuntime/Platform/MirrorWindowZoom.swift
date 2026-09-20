import ApplicationServices
import CoreGraphics
import Foundation
import MirrorProbeCore
import ScreenCaptureKit

extension MirrorProbeRuntime {
    /// The mirroring window can be dragged to any size, but glyph rasterization only matches
    /// the templates at the zoom-level sizes (MirrorContentLayout.calibratedWindowSizes), and
    /// only when the level is chosen through the app's own 顯示方式 menu: setting the size through
    /// Accessibility rounds the height differently (250x552 instead of 250x553) and scores below
    /// the floor. Before a session locks the window geometry, step a dragged window to the
    /// nearest level through that menu (zoom out to the smallest level, then zoom in), and
    /// return the window as the window server reports it afterwards.
    static func snapMirrorWindowToCalibratedSize(_ window: SCWindow) async throws -> SCWindow {
        let frame = window.frame
        guard let target = MirrorContentLayout.nearestCalibratedWindowSize(
            for: (frame.width, frame.height)
        ) else { return window }
        guard let processID = window.owningApplication?.processID, processID > 0 else {
            throw ProbeError.unsafeWindow("could not resolve the iPhone Mirroring process for resizing")
        }
        let describe = { (rect: CGRect) in
            "[x=\(rect.minX),y=\(rect.minY),width=\(rect.width),height=\(rect.height)]"
        }
        let menu = try mirrorZoomMenu(processID: processID)
        let levelIndex = MirrorContentLayout.calibratedWindowSizes.firstIndex {
            $0.width == target.width && $0.height == target.height
        } ?? 0
        var zoomOutPresses = 0
        while try menu.isEnabled(menu.zoomOut), zoomOutPresses < 12 {
            try menu.press(menu.zoomOut)
            zoomOutPresses += 1
            try await Task.sleep(for: .milliseconds(500))
        }
        for _ in 0..<levelIndex {
            guard try menu.isEnabled(menu.zoomIn) else { break }
            try menu.press(menu.zoomIn)
            try await Task.sleep(for: .milliseconds(500))
        }
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(300))
            let windows = try await mirrorWindows()
            if let updated = windows.first(where: { $0.windowID == window.windowID }),
               abs(updated.frame.width - target.width) <= 0.5,
               abs(updated.frame.height - target.height) <= 0.5
            {
                let line = "mirrorWindowResized: from=\(describe(frame)) to=\(describe(updated.frame)), "
                    + "zoomLevel=\(levelIndex + 1)\n"
                FileHandle.standardError.write(Data(line.utf8))
                return updated
            }
        }
        throw ProbeError.unsafeWindow(
            "the iPhone Mirroring window did not reach the calibrated "
                + "\(Int(target.width))x\(Int(target.height)) zoom level from \(describe(frame)); "
                + "choose a zoom level from 顯示方式 manually"
        )
    }

    /// The zoom items of the mirroring app's View menu, found by their ⌘+ and ⌘- shortcuts so
    /// the lookup does not depend on the menu's language.
    private struct MirrorZoomMenu {
        let zoomIn: AXUIElement
        let zoomOut: AXUIElement

        func isEnabled(_ item: AXUIElement) throws -> Bool {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(item, kAXEnabledAttribute as CFString, &value)
                == .success
            else { throw ProbeError.unsafeWindow("could not read a 顯示方式 menu item state") }
            return (value as? Bool) ?? false
        }

        func press(_ item: AXUIElement) throws {
            let error = AXUIElementPerformAction(item, kAXPressAction as CFString)
            guard error == .success else {
                throw ProbeError.unsafeWindow(
                    "could not press a 顯示方式 zoom menu item; AXError=\(error.rawValue)"
                )
            }
        }
    }

    private static func mirrorZoomMenu(processID: Int32) throws -> MirrorZoomMenu {
        let application = AXUIElementCreateApplication(processID)
        guard let menuBar = accessibilityElement(application, attribute: kAXMenuBarAttribute) else {
            throw ProbeError.unsafeWindow(
                "could not read the iPhone Mirroring menu bar through Accessibility; "
                    + "check the Accessibility permission"
            )
        }
        var zoomIn: AXUIElement?
        var zoomOut: AXUIElement?
        for barItem in accessibilityChildren(menuBar) {
            for menu in accessibilityChildren(barItem) {
                for item in accessibilityChildren(menu) {
                    guard let command = accessibilityString(item, attribute: kAXMenuItemCmdCharAttribute),
                          accessibilityModifiers(item) == 0
                    else { continue }
                    if command == "+" { zoomIn = item }
                    if command == "-" { zoomOut = item }
                }
            }
        }
        guard let zoomIn, let zoomOut else {
            throw ProbeError.unsafeWindow(
                "the iPhone Mirroring 顯示方式 menu has no ⌘+ / ⌘- zoom items"
            )
        }
        return MirrorZoomMenu(zoomIn: zoomIn, zoomOut: zoomOut)
    }

    private static func accessibilityElement(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func accessibilityChildren(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
            == .success, let children = value as? [AXUIElement]
        else { return [] }
        return children
    }

    private static func accessibilityString(_ element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    private static func accessibilityModifiers(_ element: AXUIElement) -> Int {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXMenuItemCmdModifiersAttribute as CFString, &value
        ) == .success else { return -1 }
        return (value as? Int) ?? -1
    }
}
