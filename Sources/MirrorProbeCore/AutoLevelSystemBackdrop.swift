import Foundation

/// Recognizes only known system background surfaces whose WindowServer rectangles can cover
/// the mirror without owning the input point. This filter is not an input authorization:
/// callers must still validate the locked window, geometry, focus, deadlines, and window order.
public enum AutoLevelSystemBackdrop {
    public static func isNonOccluding(
        ownerBundleIdentifier: String?,
        layer: Int,
        name: String?,
        frame: AutoLevelWindowGeometry,
        expectedWindowFrame: AutoLevelWindowGeometry,
        displayFrames: [AutoLevelWindowGeometry],
        hitProcessID: Int32?,
        hitError: Int32,
        expectedProcessID: Int32
    ) -> Bool {
        guard expectedProcessID > 0,
              hitError == 0,
              hitProcessID == expectedProcessID,
              frame.isValid,
              expectedWindowFrame.isValid,
              contains(frame, expectedWindowFrame)
        else {
            return false
        }

        switch ownerBundleIdentifier {
        case "com.apple.dock":
            // Preserve the established Dock signature independently of display discovery.
            return layer == 20 && name == "Dock"
        case "com.apple.notificationcenterui":
            // A notification or side panel is not this full-display background surface.
            // Use WindowServer display coordinates, including offsets on other displays.
            return layer == 21 && displayFrames.contains { $0.isValid && $0 == frame }
        default:
            return false
        }
    }

    private static func contains(
        _ outer: AutoLevelWindowGeometry,
        _ inner: AutoLevelWindowGeometry
    ) -> Bool {
        outer.x <= inner.x && outer.y <= inner.y
            && outer.x + outer.width >= inner.x + inner.width
            && outer.y + outer.height >= inner.y + inner.height
    }
}
