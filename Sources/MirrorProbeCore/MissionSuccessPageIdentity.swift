import Foundation

/// Content identity for the two successful mission-result pages which share one advance arrow.
/// This identifies page evidence only; callers separately validate state and action targets.
public enum MissionSuccessPageIdentity: String, Codable, Equatable, Sendable {
    case experience
    case loot

    public static func resolve(
        in classification: GameStateClassification
    ) -> MissionSuccessPageIdentity? {
        let markers = classification.evidence.filter {
            $0.kind == .missionExperiencePage || $0.kind == .missionLootPage
        }
        guard markers.count == 1,
              let marker = markers.first
        else { return nil }
        if VisualResultEvidence.hasVisualMatches(in: classification) {
            guard VisualResultEvidence.hasConsistentVisualEvidence(in: classification),
                  let match = VisualResultEvidence.validatedMatch(marker)
            else { return nil }
            switch match.marker {
            case .experienceHeader: return .experience
            case .lootHeader: return .loot
            default: return nil
            }
        }
        guard let observation = marker.observation,
              observation.confidence.isFinite,
              (GameStateClassifier.minimumMarkerConfidence...1).contains(observation.confidence),
              observation.rect.isValid,
              (0.70...1.0).contains(observation.rect.center.x),
              (0.12...0.20).contains(observation.rect.center.y)
        else {
            return nil
        }
        let compatible = observation.text.precomposedStringWithCompatibilityMapping
        let scalars = compatible.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }
        let canonical = String(String.UnicodeScalarView(scalars))
        switch (marker.kind, canonical) {
        case (.missionExperiencePage, "獲得經驗值"): return .experience
        case (.missionLootPage, "獲得拾得物"): return .loot
        default: return nil
        }
    }
}
