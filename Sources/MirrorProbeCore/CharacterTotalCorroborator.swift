public enum CharacterTotalBoundaryDecision: Equatable, Sendable {
    case rerollRequired
    case thresholdReached
    case unsafeBoundaryConflict
    case unsafeDigitCountMismatch
    case invalidMinimumTotal
}

/// Combines two exact OCR parses with rendered-pixel evidence before a reroll is permitted.
///
/// At the three-digit boundary, matching digit count is sufficient. For a two-digit threshold,
/// both OCR reads must be on the same side; below the threshold they must also have the exact same
/// value. Any disagreement which might conceal a keeper fails closed.
public enum CharacterTotalCorroborator {
    public static func decide(
        fullFrameTotal: Int,
        focusedRead: CharacterFocusedTotalRead,
        renderedDigitCount: Int,
        minimumTotal: Int
    ) -> CharacterTotalBoundaryDecision {
        guard CharacterRerollDetector.supportedMinimumTotalRange.contains(minimumTotal) else {
            return .invalidMinimumTotal
        }
        guard CharacterRerollDetector.supportedTotalRange.contains(fullFrameTotal),
              CharacterRerollDetector.supportedTotalRange.contains(focusedRead.value),
              (1...3).contains(renderedDigitCount)
        else {
            return .unsafeDigitCountMismatch
        }

        let fullFrameDigitCount = String(fullFrameTotal).count
        let focusedValueDigitCount = String(focusedRead.value).count
        guard focusedRead.digitCount == focusedValueDigitCount,
              fullFrameDigitCount == focusedRead.digitCount,
              fullFrameDigitCount == renderedDigitCount
        else {
            if fullFrameTotal >= minimumTotal
                || focusedRead.value >= minimumTotal
                || (renderedDigitCount == 3 && minimumTotal <= 100)
            {
                return .unsafeBoundaryConflict
            }
            return .unsafeDigitCountMismatch
        }

        let fullFrameReached = fullFrameTotal >= minimumTotal
        let focusedReached = focusedRead.value >= minimumTotal
        guard fullFrameReached == focusedReached else {
            return .unsafeBoundaryConflict
        }
        if fullFrameReached {
            return .thresholdReached
        }

        // At 100, every one- or two-digit total is safely below the boundary, so per-digit OCR
        // disagreements do not affect the action. At lower thresholds, every low-side value must
        // agree exactly; there are no exceptions which can weaken the fail-closed contract.
        if minimumTotal == 100 {
            return .rerollRequired
        }
        guard fullFrameTotal == focusedRead.value else {
            return .unsafeBoundaryConflict
        }
        return .rerollRequired
    }
}
