import Foundation

/// Selects the fixed upper continuation control on a fully classified, repeat-selected result.
/// The lower decorative control is never a candidate, and arrow-glyph OCR is deliberately ignored.
public enum MissionResultTopActionResolver {
    public static let measuredTopAdvanceSentinel = "<measured-result-top-advance>"
    public static let measuredTopAdvanceRect = NormalizedRect(
        x: 0.024630541297208562,
        y: 0.19775280880149815,
        width: 0.04433497536945812,
        height: 0.011235955056179803
    )

    public static func resolve(
        classification: GameStateClassification
    ) -> GameStateClassification {
        let titleKind: GameEvidenceKind
        switch classification.state {
        case .missionCompleteRepeatSelected:
            titleKind = .missionCompleteTitle
            let pageIdentities = classification.evidence.filter {
                $0.kind == .missionExperiencePage || $0.kind == .missionLootPage
            }
            guard pageIdentities.count == 1 else { return withoutResultAction(classification) }
        case .missionFailedRepeatSelected:
            titleKind = .missionFailedTitle
        default:
            return classification
        }

        guard classification.policyGatedActions.isEmpty,
              classification.evidence.filter({ $0.kind == titleKind }).count == 1,
              classification.evidence.filter({ $0.kind == .missionRepeatOption }).count == 1,
              classification.evidence.filter({ $0.kind == .repeatSelectedMarker }).count == 1,
              !classification.evidence.contains(where: {
                  $0.kind == .invalidObservation
                      || $0.kind == .lowConfidenceMarker
                      || $0.kind == .conflictingStateMarkers
              })
        else {
            return withoutResultAction(classification)
        }

        let action = AllowedGameAction(
            name: .advanceMissionComplete,
            target: NamedGameTarget(
                name: .missionCompleteAdvance,
                sourceText: measuredTopAdvanceSentinel,
                rect: measuredTopAdvanceRect,
                point: measuredTopAdvanceRect.center
            )
        )
        let measuredEvidence = GameStateEvidence(
            kind: .missionResultAdvanceMeasuredFallback,
            observation: nil,
            detail: measuredTopAdvanceSentinel
        )
        return GameStateClassification(
            state: classification.state,
            evidence: classification.evidence.filter {
                $0.kind != .missionCompleteAdvance
                    && $0.kind != .missionCompleteAdvanceMeasuredFallback
                    && $0.kind != .missionResultAdvanceMeasuredFallback
            } + [measuredEvidence],
            allowedActions: [action],
            policyGatedActions: []
        )
    }

    private static func withoutResultAction(
        _ classification: GameStateClassification
    ) -> GameStateClassification {
        GameStateClassification(
            state: classification.state,
            evidence: classification.evidence,
            allowedActions: [],
            policyGatedActions: classification.policyGatedActions
        )
    }
}
