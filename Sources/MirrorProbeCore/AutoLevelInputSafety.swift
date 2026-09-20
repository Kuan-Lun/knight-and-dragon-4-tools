import Foundation

/// WindowServer geometry bound to the fresh preflight for an input. Equality is deliberately
/// exact: a last-moment move or resize must invalidate an input authorization.
public struct AutoLevelWindowGeometry: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// WindowServer uses global display coordinates, so negative origins are valid. Dimensions
    /// and computed edges must remain finite and describe a nonempty window.
    public var isValid: Bool {
        x.isFinite && y.isFinite
            && width.isFinite && height.isFinite
            && width > 0 && height > 0
            && (x + width).isFinite && (y + height).isFinite
    }
}

public enum AutoLevelInputMode: String, Codable, Equatable, Sendable {
    /// A normal HID click. The mirror must be frontmost and visually topmost at the point.
    case foreground
    /// A process-routed click. Other applications may be frontmost, but the locked mirror must
    /// remain the topmost window belonging to the destination process at the point.
    case process
}

/// Facts sampled immediately before an automation input is posted.
public struct AutoLevelInputSnapshot: Equatable, Sendable {
    public let windowIdentity: AutoLevelWindowIdentity?
    public let windowGeometry: AutoLevelWindowGeometry?
    public let frontmostProcessID: Int32?
    public let topmostWindowIdentity: AutoLevelWindowIdentity?
    public let targetProcessTopmostWindowIdentity: AutoLevelWindowIdentity?

    public init(
        windowIdentity: AutoLevelWindowIdentity?,
        windowGeometry: AutoLevelWindowGeometry?,
        frontmostProcessID: Int32?,
        topmostWindowIdentity: AutoLevelWindowIdentity?,
        targetProcessTopmostWindowIdentity: AutoLevelWindowIdentity? = nil
    ) {
        self.windowIdentity = windowIdentity
        self.windowGeometry = windowGeometry
        self.frontmostProcessID = frontmostProcessID
        self.topmostWindowIdentity = topmostWindowIdentity
        self.targetProcessTopmostWindowIdentity = targetProcessTopmostWindowIdentity
    }
}

public enum AutoLevelInputRejection: Equatable, Sendable {
    case stopRequested
    case invalidTiming
    case actionAuthorizationExpired
    case sessionRuntimeExpired
    case windowUnavailable
    case windowIdentityChanged
    case windowGeometryChanged
    case applicationNotFrontmost
    case clickPointObscured
}

/// Pure, fail-closed validation for the final boundary between observation and input.
/// Unlimited sessions omit their deadline; every input still requires an unexpired action.
public enum AutoLevelInputSafety {
    public static func rejection(
        expectedWindowIdentity: AutoLevelWindowIdentity,
        expectedWindowGeometry: AutoLevelWindowGeometry,
        inputMode: AutoLevelInputMode = .foreground,
        snapshot: AutoLevelInputSnapshot,
        now: TimeInterval,
        actionDeadline: TimeInterval,
        sessionDeadline: TimeInterval? = nil,
        stopRequested: Bool
    ) -> AutoLevelInputRejection? {
        guard !stopRequested else {
            return .stopRequested
        }
        guard now.isFinite,
              actionDeadline.isFinite,
              sessionDeadline?.isFinite != false,
              now >= 0,
              actionDeadline >= 0,
              sessionDeadline.map({ $0 >= 0 }) != false
        else {
            return .invalidTiming
        }
        if let sessionDeadline, now >= sessionDeadline {
            return .sessionRuntimeExpired
        }
        guard now < actionDeadline else {
            return .actionAuthorizationExpired
        }
        guard let windowIdentity = snapshot.windowIdentity,
              let windowGeometry = snapshot.windowGeometry
        else {
            return .windowUnavailable
        }
        guard expectedWindowIdentity.processID > 0,
              expectedWindowIdentity.windowID > 0,
              windowIdentity == expectedWindowIdentity
        else {
            return .windowIdentityChanged
        }
        guard expectedWindowGeometry.isValid,
              windowGeometry.isValid,
              windowGeometry == expectedWindowGeometry
        else {
            return .windowGeometryChanged
        }
        switch inputMode {
        case .foreground:
            guard snapshot.frontmostProcessID == expectedWindowIdentity.processID else {
                return .applicationNotFrontmost
            }
            guard snapshot.topmostWindowIdentity == expectedWindowIdentity else {
                return .clickPointObscured
            }
        case .process:
            guard snapshot.targetProcessTopmostWindowIdentity == expectedWindowIdentity else {
                return .clickPointObscured
            }
        }
        return nil
    }
}
