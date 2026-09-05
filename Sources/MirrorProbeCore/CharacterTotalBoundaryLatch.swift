public enum CharacterTotalBoundaryEvidence: Equatable, Sendable {
    case belowThreshold
    case thresholdReached
    case boundaryConflict
    case unavailable
}

public enum CharacterTotalBoundaryLatchDecision: Equatable, Sendable {
    case continueStabilizing
    case terminalVeto
}

/// Prevents a later low OCR sample from erasing earlier evidence that the keeper boundary may
/// already have been reached while a supposedly stable snapshot is assembled.
public struct CharacterTotalBoundaryLatch: Sendable {
    private var thresholdWasObserved = false
    private var terminalWasObserved = false

    public init() {}

    public mutating func observe(
        _ evidence: CharacterTotalBoundaryEvidence
    ) -> CharacterTotalBoundaryLatchDecision {
        guard !terminalWasObserved else { return .terminalVeto }
        switch evidence {
        case .boundaryConflict:
            terminalWasObserved = true
            return .terminalVeto
        case .thresholdReached:
            thresholdWasObserved = true
            return .continueStabilizing
        case .belowThreshold, .unavailable:
            if thresholdWasObserved {
                terminalWasObserved = true
                return .terminalVeto
            }
            return .continueStabilizing
        }
    }
}
