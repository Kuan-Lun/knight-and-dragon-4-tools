import CoreGraphics
import Foundation

/// A per-process tag lets passive event observers recognize this program's own clicks.
/// It does not change the event source, coordinates, timing, or delivery route.
enum AutomationInputMarker {
    private static let tag = Int64.random(in: 1...Int64.max)

    static func mark(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: tag)
    }

    static func matches(_ event: CGEvent?) -> Bool {
        event?.getIntegerValueField(.eventSourceUserData) == tag
    }
}
