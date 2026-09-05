public enum CharacterTotalBoundaryEvidenceResolver {
    public static func resolve(
        fullFrame: CharacterFullFrameTotalResolution,
        focused: CharacterFocusedTotalResolution,
        renderedDigitDetection: CharacterTotalDigitDetection,
        minimumTotal: Int
    ) -> CharacterTotalBoundaryEvidence {
        guard CharacterRerollDetector.supportedMinimumTotalRange.contains(minimumTotal) else {
            return .boundaryConflict
        }

        let credibleFullReads: [CharacterFullFrameTotalRead]
        let exactFullRead: CharacterFullFrameTotalRead?
        let fullFrameIsContaminated: Bool
        switch fullFrame {
        case let .exact(read):
            credibleFullReads = [read]
            exactFullRead = read
            fullFrameIsContaminated = false
        case let .contaminated(reads):
            credibleFullReads = reads
            exactFullRead = nil
            fullFrameIsContaminated = true
        case .unavailable:
            credibleFullReads = []
            exactFullRead = nil
            fullFrameIsContaminated = false
        }
        let credibleFocusedReads: [CharacterFocusedTotalRead]
        let exactFocusedRead: CharacterFocusedTotalRead?
        let focusedIsContaminated: Bool
        switch focused {
        case let .exact(read):
            credibleFocusedReads = [read]
            exactFocusedRead = read
            focusedIsContaminated = false
        case let .contaminated(reads):
            credibleFocusedReads = reads
            exactFocusedRead = nil
            focusedIsContaminated = true
        case .unavailable:
            credibleFocusedReads = []
            exactFocusedRead = nil
            focusedIsContaminated = false
        }
        guard credibleFullReads.allSatisfy({
            $0.digitCount == String($0.value).count
        }), credibleFocusedReads.allSatisfy({
            $0.digitCount == String($0.value).count
        }) else {
            return .boundaryConflict
        }
        if renderedDigitDetection == .boundaryAmbiguous
            || renderedDigitDetection == .unsafe
        {
            return .boundaryConflict
        }
        let renderedDigitCount: Int?
        if case let .digitCount(count) = renderedDigitDetection {
            renderedDigitCount = count
        } else {
            renderedDigitCount = nil
        }
        let hasCredibleHighEvidence = credibleFullReads.contains {
            $0.value >= minimumTotal
        } || credibleFocusedReads.contains {
            $0.value >= minimumTotal
        }
            || renderedDigitCount == 3

        // A second or malformed TOTAL-like row could be an unparseable keeper reading (for
        // example 9O or a low-confidence 100). Treat all contamination as terminal instead of
        // allowing a later clean-looking low sample to erase it at any supported threshold.
        if fullFrameIsContaminated || focusedIsContaminated {
            return .boundaryConflict
        }

        guard let exactFullRead, let exactFocusedRead, let renderedDigitCount else {
            return hasCredibleHighEvidence ? .boundaryConflict : .unavailable
        }

        switch CharacterTotalCorroborator.decide(
            fullFrameTotal: exactFullRead.value,
            focusedRead: exactFocusedRead,
            renderedDigitCount: renderedDigitCount,
            minimumTotal: minimumTotal
        ) {
        case .rerollRequired:
            return .belowThreshold
        case .thresholdReached:
            return .thresholdReached
        case .unsafeBoundaryConflict:
            return .boundaryConflict
        case .unsafeDigitCountMismatch:
            return hasCredibleHighEvidence ? .boundaryConflict : .unavailable
        case .invalidMinimumTotal:
            return .boundaryConflict
        }
    }
}
