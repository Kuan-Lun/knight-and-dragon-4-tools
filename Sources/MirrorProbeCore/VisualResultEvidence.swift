import Foundation

/// Template identities for the fixed result header and repeat row. These are pixel matches,
/// not OCR observations; their similarity must never be reported as text confidence.
public enum VisualResultMarker: String, Codable, Equatable, Sendable {
    case successTitle
    case failureTitle
    case experienceHeader
    case lootHeader
    case repeatOption
}

public struct VisualResultMatch: Codable, Equatable, Sendable {
    public static let minimumSimilarity = 0.94

    public let marker: VisualResultMarker
    public let region: NormalizedRect
    public let similarity: Double
    /// Vertical displacement of the scrolled list block this match was found at. Only the
    /// repeat row may carry one; the fixed title and page header are always zero.
    public let listOffset: Double

    public init(
        marker: VisualResultMarker, region: NormalizedRect, similarity: Double,
        listOffset: Double = 0
    ) {
        self.marker = marker
        self.region = region
        self.similarity = similarity
        self.listOffset = listOffset
    }

    private enum CodingKeys: String, CodingKey {
        case marker, region, similarity, listOffset
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        marker = try container.decode(VisualResultMarker.self, forKey: .marker)
        region = try container.decode(NormalizedRect.self, forKey: .region)
        similarity = try container.decode(Double.self, forKey: .similarity)
        listOffset = try container.decodeIfPresent(Double.self, forKey: .listOffset) ?? 0
    }

    public static func region(for marker: VisualResultMarker) -> NormalizedRect {
        switch marker {
        case .successTitle, .failureTitle:
            .init(x: 0.38, y: 0.10, width: 0.24, height: 0.034)
        case .experienceHeader, .lootHeader:
            .init(x: 0.775, y: 0.145, width: 0.20, height: 0.026)
        case .repeatOption:
            .init(x: 0.022, y: 0.234, width: 0.29, height: 0.025)
        }
    }

    /// A scrolled repeat row is held to `VisualResultListOffset.minimumSimilarity`.
    public static func minimumSimilarity(for marker: VisualResultMarker, listOffset: Double) -> Double {
        marker == .repeatOption && listOffset != 0
            ? VisualResultListOffset.minimumSimilarity : minimumSimilarity
    }

    /// The calibrated region moved with the scrolled list; only the repeat row moves.
    public static func region(for marker: VisualResultMarker, listOffset: Double) -> NormalizedRect {
        let base = region(for: marker)
        guard marker == .repeatOption, listOffset != 0 else { return base }
        return base.offsetY(listOffset)
    }
}

/// A long loot list can be scrolled a little, which moves the ">>" control, the repeat row
/// and its stamp together while the title and page header stay fixed: three runs at 211x468
/// (logs/auto-level-20260920-224537 after 55 cycles, -232356 after 31, and 20260921-001348 at
/// startup) sat seven canvas rows high and stayed unknown. Recognition follows that block
/// within this bounded range and every result target moves with it; a page scrolled further
/// stays unknown, so the user scrolls it back to the top.
public enum VisualResultListOffset {
    public static let range: ClosedRange<Double> = -0.032...0.006

    /// A scrolled row shows the same glyphs downscaled at another phone-pixel phase, so it
    /// correlated only 0.77 to 0.87 with the calibrated samples (0.998 with its own sample,
    /// which is included). The other text inside the search window scored at most 0.45.
    public static let minimumSimilarity = 0.75

    /// One reference-canvas row per step (890 rows at 406x890, 445 at 211x468); the region
    /// matcher's own one-row sub-search covers the gaps. Nearest offsets first.
    public static let candidates: [Double] = {
        let step = 2.0 / 890.0
        var offsets: [Double] = []
        for multiple in 1...14 {
            let up = -Double(multiple) * step, down = Double(multiple) * step
            if range.contains(up) { offsets.append(up) }
            if range.contains(down) { offsets.append(down) }
        }
        return offsets
    }()

    public static func isAllowed(_ offset: Double) -> Bool {
        offset.isFinite && range.contains(offset)
    }
}

extension NormalizedRect {
    public func offsetY(_ delta: Double) -> NormalizedRect {
        NormalizedRect(x: x, y: y + delta, width: width, height: height)
    }
}

/// Validates serialized visual evidence at the same boundaries that previously required OCR.
/// The OCR branches retain compatibility with recorded reports and existing offline fixtures.
public enum VisualResultEvidence {
    public static let measuredRepeatOptionSentinel = "<measured-result-repeat-option>"

    public static func validatedMatch(_ evidence: GameStateEvidence) -> VisualResultMatch? {
        guard evidence.observation == nil, evidence.battleVisualMatch == nil,
              let match = evidence.visualMatch,
              expectedMarker(for: evidence.kind) == match.marker,
              match.marker == .repeatOption
                  ? VisualResultListOffset.isAllowed(match.listOffset) : match.listOffset == 0,
              match.region.isValid,
              match.region == VisualResultMatch.region(for: match.marker, listOffset: match.listOffset),
              match.similarity.isFinite,
              (VisualResultMatch.minimumSimilarity(for: match.marker, listOffset: match.listOffset)...1)
                  .contains(match.similarity)
        else { return nil }
        return match
    }

    /// The scrolled-list displacement the classification's repeat row was matched at: zero
    /// for an unscrolled page and for OCR-based evidence.
    public static func listOffset(in classification: GameStateClassification) -> Double {
        let rows = classification.evidence.filter { $0.kind == .missionRepeatOption }
        guard rows.count == 1, let match = validatedMatch(rows[0]) else { return 0 }
        return match.listOffset
    }

    public static func hasVisualMatches(in classification: GameStateClassification) -> Bool {
        classification.evidence.contains { $0.visualMatch != nil }
    }

    /// Once a result uses visual matching, its semantic anchors must all use valid visual
    /// evidence. An OCR marker cannot silently fill a missing, weak, or mismatched template.
    public static func hasConsistentVisualEvidence(in classification: GameStateClassification) -> Bool {
        guard hasVisualMatches(in: classification),
              classification.policyGatedActions.isEmpty,
              classification.evidence.allSatisfy({ $0.battleVisualMatch == nil }),
              !classification.evidence.contains(where: {
                  $0.kind == .invalidObservation || $0.kind == .lowConfidenceMarker
                      || $0.kind == .conflictingStateMarkers
              })
        else { return false }

        for evidence in classification.evidence {
            if expectedMarker(for: evidence.kind) != nil || evidence.visualMatch != nil {
                guard validatedMatch(evidence) != nil else { return false }
            } else {
                guard evidence.observation == nil else { return false }
                switch evidence.kind {
                case .repeatSelectedMarker:
                    guard evidence.detail == RepeatSelectedStampDetector.evidenceSentinel
                        || evidence.detail.hasPrefix(RepeatSelectedStampDetector.evidenceSentinel + ";")
                    else { return false }
                case .repeatUnselectedMarker:
                    guard evidence.detail == RepeatSelectedStampDetector.absentEvidenceSentinel else {
                        return false
                    }
                case .missionResultAdvanceMeasuredFallback:
                    guard evidence.detail == MissionResultTopActionResolver.measuredTopAdvanceSentinel else {
                        return false
                    }
                default:
                    return false
                }
            }
        }
        let groups: [[GameEvidenceKind]] = [
            [.missionCompleteTitle, .missionFailedTitle],
            [.missionExperiencePage, .missionLootPage],
            [.missionRepeatOption],
            [.repeatSelectedMarker, .repeatUnselectedMarker],
        ]
        return groups.allSatisfy { kinds in
            classification.evidence.filter { kinds.contains($0.kind) }.count == 1
        }
    }

    public static func trustedTitle(
        in classification: GameStateClassification,
        expectedKind: GameEvidenceKind
    ) -> Bool {
        guard expectedKind == .missionCompleteTitle || expectedKind == .missionFailedTitle else {
            return false
        }
        let titles = classification.evidence.filter {
            $0.kind == .missionCompleteTitle || $0.kind == .missionFailedTitle
        }
        guard titles.count == 1, let title = titles.first, title.kind == expectedKind else {
            return false
        }
        if hasVisualMatches(in: classification) {
            return hasConsistentVisualEvidence(in: classification) && validatedMatch(title) != nil
        }
        guard let observation = title.observation,
              isTrusted(observation), observation.rect.center.y <= 0.25
        else { return false }
        let text = expectedKind == .missionCompleteTitle ? "任務完成" : "任務失敗"
        return [text, text + "!"].contains(canonical(observation.text))
    }

    public static func trustedRepeatRect(in classification: GameStateClassification) -> NormalizedRect? {
        let repeats = classification.evidence.filter { $0.kind == .missionRepeatOption }
        guard repeats.count == 1, let row = repeats.first else { return nil }
        if hasVisualMatches(in: classification) {
            guard hasConsistentVisualEvidence(in: classification), let match = validatedMatch(row) else {
                return nil
            }
            return match.region
        }
        guard let observation = row.observation,
              isTrusted(observation), canonical(observation.text) == "重複進行此任務",
              (0.08...0.45).contains(observation.rect.center.y)
        else { return nil }
        return observation.rect
    }

    private static func expectedMarker(for kind: GameEvidenceKind) -> VisualResultMarker? {
        switch kind {
        case .missionCompleteTitle: .successTitle
        case .missionFailedTitle: .failureTitle
        case .missionExperiencePage: .experienceHeader
        case .missionLootPage: .lootHeader
        case .missionRepeatOption: .repeatOption
        default: nil
        }
    }

    private static func isTrusted(_ observation: OCRTextObservation) -> Bool {
        observation.rect.isValid && observation.confidence.isFinite
            && (GameStateClassifier.minimumMarkerConfidence...1).contains(observation.confidence)
    }

    private static func canonical(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.filter { !$0.isWhitespace }
    }
}
