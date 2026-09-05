/// The result of decoding a live, application-level AXFrontmost attribute.
public enum ForegroundFocusFallbackValue: Equatable, Sendable {
    case unavailable
    case invalidType
    case boolean(Bool)
}

/// AppKit supplies a candidate identity, never authority to borrow or restore focus.
/// A fallback requires a successful live AX boolean and an unchanged candidate identity.
public enum ForegroundFocusFallbackValidation {
    public static func confirmedProcessID(
        primaryReturnedNoValue: Bool,
        candidateBefore: Int32?,
        candidateAfter: Int32?,
        frontmostReadSucceeded: Bool,
        frontmostValue: ForegroundFocusFallbackValue
    ) -> Int32? {
        guard primaryReturnedNoValue,
              let candidateBefore,
              candidateBefore > 0,
              candidateAfter == candidateBefore,
              frontmostReadSucceeded,
              frontmostValue == .boolean(true)
        else {
            return nil
        }
        return candidateBefore
    }
}
