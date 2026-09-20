import Foundation

public enum VisualBattleMarker: String, Codable, Equatable, Sendable, CaseIterable {
    case skipControl
    case allAutoControl
    case pauseControl
    case retreatControl
}

public struct VisualBattleMatch: Codable, Equatable, Sendable {
    public static let minimumSimilarity = 0.94
    public let marker: VisualBattleMarker
    public let region: NormalizedRect
    public let similarity: Double

    public init(marker: VisualBattleMarker, region: NormalizedRect, similarity: Double) {
        self.marker = marker
        self.region = region
        self.similarity = similarity
    }

    public static func regions(for marker: VisualBattleMarker) -> [NormalizedRect] {
        switch marker {
        case .skipControl:
            // Exclude the changing party/footer border above the glyphs, including
            // the matcher's one-logical-pixel upward registration tolerance.
            [.init(x: 0.075, y: 0.870, width: 0.09, height: 0.023)]
        case .pauseControl:
            [.init(x: 0.84, y: 0.626, width: 0.085, height: 0.024)]
        case .retreatControl:
            [.init(x: 0.84, y: 0.655, width: 0.085, height: 0.024)]
        case .allAutoControl:
            [.init(x: 0.225, y: 0.870, width: 0.14, height: 0.021)]
        }
    }
}

/// The skip and all-auto footer controls establish battle layout. The retreat control
/// makes that page eligible for temporal monitoring; pause is diagnostic only because
/// combat effects can obscure it. Actual progress is established by the temporal monitor.
public enum VisualBattleEvidence {
    public static let identityMarkers: [VisualBattleMarker] = [.skipControl, .allAutoControl]
    public static let measuredRetreatSentinel = "<measured-visual-battle-retreat>"
    public static let measuredRetreatRect = NormalizedRect(
        x: 0.84, y: 0.655, width: 0.085, height: 0.024
    )

    public static func validatedMatch(_ evidence: GameStateEvidence) -> VisualBattleMatch? {
        guard evidence.kind == .battleMarker, evidence.observation == nil,
              evidence.visualMatch == nil, let match = evidence.battleVisualMatch,
              match.region.isValid, VisualBattleMatch.regions(for: match.marker).contains(match.region),
              match.similarity.isFinite,
              (VisualBattleMatch.minimumSimilarity...1).contains(match.similarity)
        else { return nil }
        return match
    }

    public static func hasConsistentVisualEvidence(in classification: GameStateClassification) -> Bool {
        guard classification.state == .battle, classification.allowedActions.isEmpty,
              (identityMarkers.count...VisualBattleMarker.allCases.count).contains(classification.evidence.count),
              classification.evidence.allSatisfy({ validatedMatch($0) != nil })
        else { return false }
        for marker in VisualBattleMarker.allCases {
            let count = classification.evidence.filter { $0.battleVisualMatch?.marker == marker }.count
            guard count <= 1, !identityMarkers.contains(marker) || count == 1 else {
                return false
            }
        }
        return classification.policyGatedActions.isEmpty || hasExactRetreatCandidate(in: classification)
    }

    public static func hasRunningBattleEvidence(in classification: GameStateClassification) -> Bool {
        hasConsistentVisualEvidence(in: classification) && contains(.retreatControl, in: classification)
    }

    public static func hasTrustedRetreat(in classification: GameStateClassification) -> Bool {
        hasRunningBattleEvidence(in: classification) && hasExactRetreatCandidate(in: classification)
    }

    /// A visible retreat on a rejected footer is insufficient to identify a battle or click.
    /// Only BattleRecognitionRecovery may combine it with prior battle and elapsed-time proof.
    public static func hasRecoverableFooterOcclusion(in classification: GameStateClassification) -> Bool {
        guard classification.state == .unknown,
              classification.allowedActions.isEmpty, classification.policyGatedActions.isEmpty,
              classification.evidence.filter({ $0.kind == .battleFooterOcclusion }).count == 1
        else { return false }
        var markers = Set<VisualBattleMarker>()
        for evidence in classification.evidence {
            if let match = validatedMatch(evidence) {
                guard markers.insert(match.marker).inserted else { return false }
            } else {
                guard evidence.kind == .battleFooterOcclusion || evidence.kind == .lowConfidenceMarker,
                      evidence.observation == nil, evidence.visualMatch == nil,
                      evidence.battleVisualMatch == nil
                else { return false }
            }
        }
        return markers.contains(.retreatControl)
            && !identityMarkers.allSatisfy { markers.contains($0) }
    }

    private static func contains(_ marker: VisualBattleMarker, in classification: GameStateClassification) -> Bool {
        classification.evidence.contains { validatedMatch($0)?.marker == marker }
    }

    private static func hasExactRetreatCandidate(in classification: GameStateClassification) -> Bool {
        guard contains(.retreatControl, in: classification),
              classification.policyGatedActions.count == 1,
              let action = classification.policyGatedActions.first,
              action.name == .openBattleRetreatConfirmation,
              action.requirement == .temporalDefeatRecovery,
              action.target.name == .battleRetreat,
              action.target.sourceText == measuredRetreatSentinel,
              action.target.rect == measuredRetreatRect,
              action.target.point == measuredRetreatRect.center
        else { return false }
        return true
    }
}
