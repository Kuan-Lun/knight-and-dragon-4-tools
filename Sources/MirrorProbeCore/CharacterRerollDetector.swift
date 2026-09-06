import Foundation

/// The only control which a verified custom-character snapshot may authorize.
public struct CharacterRerollTarget: Codable, Equatable, Sendable {
    public let sourceText: String
    public let rect: NormalizedRect
    public let point: NormalizedPoint

    public init(sourceText: String, rect: NormalizedRect, point: NormalizedPoint) {
        self.sourceText = sourceText
        self.rect = rect
        self.point = point
    }
}

/// Canonical values which identify one generated allocation independently of Vision's choice to
/// split or merge adjacent text observations.
public struct CharacterRoll: Codable, Equatable, Sendable {
    public let name: String
    public let total: Int

    public init(
        name: String,
        total: Int
    ) {
        self.name = name
        self.total = total
    }
}

public enum CharacterRerollUnsafeReason: String, Codable, Equatable, Error, Sendable {
    case invalidMinimumTotal
    case invalidObservation
    case incompleteOrAmbiguousAnchor
    case lowConfidenceAnchor
    case misplacedAnchor
    case incompleteOrAmbiguousIdentity
    case lowConfidenceIdentity
    case misplacedIdentity
    case malformedIdentity
    case malformedTotal
    case totalOutOfRange
    case totalCorroborationMismatch
    case totalGlyphDetectionFailed
    case totalDigitCountMismatch
    case totalBoundaryConflict
}

/// A detector result never exposes a click target unless every measured page anchor, the generated
/// name, and the exact total agree in the same OCR snapshot.
public enum CharacterRerollDecision: Codable, Equatable, Sendable {
    case rerollRequired(roll: CharacterRoll, target: CharacterRerollTarget)
    case thresholdReached(roll: CharacterRoll)
    case unsafe(reason: CharacterRerollUnsafeReason)
}

/// Fail-closed recognition for the custom-character page.
///
/// The layout gates are calibrated from the 406 x 890 iPhone Mirroring capture. Coordinates are
/// normalized, so the same gates remain valid when the mirror is scaled without changing aspect
/// ratio. Runtime input additionally requires focused OCR and rendered-pixel digit-count evidence;
/// a single full-frame OCR result can never authorize a click.
public enum CharacterRerollDetector {
    public static let supportedTotalRange = 0...125
    /// Lower thresholds use two exact OCR reads plus raw digit count. At 100, raw glyph count also
    /// independently protects the two-to-three digit boundary.
    public static let supportedMinimumTotalRange = 90...100
    public static let measuredRandomButtonRect = NormalizedRect(
        x: 0.793_103_448_3,
        y: 0.101_123_595_5,
        width: 0.174_876_847_3,
        height: 0.033_707_865_2
    )
    public static let measuredRandomButtonPoint = measuredRandomButtonRect.center

    public static func detect(
        observations: [OCRTextObservation],
        minimumTotal: Int
    ) -> CharacterRerollDecision {
        guard supportedMinimumTotalRange.contains(minimumTotal) else {
            return .unsafe(reason: .invalidMinimumTotal)
        }

        let indexed = observations.map(IndexedObservation.init)
        guard !indexed.isEmpty,
              indexed.allSatisfy({ $0.isValid })
        else {
            return .unsafe(reason: .invalidObservation)
        }

        let title = resolveAnchor(
            in: indexed,
            matching: { $0 == "姓名/種族/信仰" },
            gate: titleGate,
            minimumConfidence: minimumStrongAnchorConfidence
        )
        guard title.value != nil else {
            return .unsafe(reason: title.reason ?? .incompleteOrAmbiguousAnchor)
        }

        let random = resolveAnchor(
            in: indexed,
            matching: { $0 == "隨機" },
            gate: randomGate,
            minimumConfidence: minimumMeasuredAnchorConfidence
        )
        guard let randomObservation = random.value else {
            return .unsafe(reason: random.reason ?? .incompleteOrAmbiguousAnchor)
        }

        let status = resolveAnchor(
            in: indexed,
            matching: { $0 == "狀態" },
            gate: statusGate,
            minimumConfidence: minimumStrongAnchorConfidence
        )
        guard status.value != nil else {
            return .unsafe(reason: status.reason ?? .incompleteOrAmbiguousAnchor)
        }

        let distribute = resolveAnchor(
            in: indexed,
            matching: { $0 == "請分配點數" },
            gate: distributeGate,
            minimumConfidence: minimumMeasuredAnchorConfidence
        )
        guard distribute.value != nil else {
            return .unsafe(reason: distribute.reason ?? .incompleteOrAmbiguousAnchor)
        }

        let decide = resolveAnchor(
            in: indexed,
            matching: { $0 == "決定" },
            gate: decideGate,
            minimumConfidence: minimumMeasuredAnchorConfidence
        )
        guard decide.value != nil else {
            return .unsafe(reason: decide.reason ?? .incompleteOrAmbiguousAnchor)
        }

        let reset = resolveAnchor(
            in: indexed,
            matching: { $0 == "重置" },
            gate: resetGate,
            minimumConfidence: minimumMeasuredAnchorConfidence
        )
        guard reset.value != nil else {
            return .unsafe(reason: reset.reason ?? .incompleteOrAmbiguousAnchor)
        }

        let name = resolveIdentity(
            IdentitySpecification(prefix: "姓名:", gate: nameGate),
            in: indexed
        )
        guard let nameValue = name.value else {
            return .unsafe(
                reason: name.reason ?? .incompleteOrAmbiguousIdentity
            )
        }

        let totalCandidates = indexed.filter {
            $0.canonicalText.hasPrefix("TOTAL")
        }
        guard totalCandidates.count == 1, let totalObservation = totalCandidates.first else {
            return .unsafe(reason: .incompleteOrAmbiguousAnchor)
        }
        // Runtime accepts this provisional full-frame reading only after a separate focused
        // Vision request and raw rendered-glyph count agree with it. Live Vision revision 3
        // assigns a stable 0.30 confidence to some otherwise exact total rows (for example 66),
        // so requiring the 0.50 control-anchor floor here would reject valid corroborated rolls.
        guard totalObservation.observation.confidence >= minimumFullFrameTotalConfidence else {
            return .unsafe(reason: .lowConfidenceAnchor)
        }
        guard totalGate.contains(totalObservation.observation.rect) else {
            return .unsafe(reason: .misplacedAnchor)
        }
        // Use the same row assembly as boundary evidence: Vision may split `total:` and its
        // digits into adjacent observations. The preliminary decision must not reject a row
        // which that resolver has already established as complete, or ignore extra row text.
        guard case let .exact(totalRead) = CharacterFullFrameTotalResolver.resolve(
            observations: observations
        ) else {
            if let total = parseTotal(totalObservation.canonicalText),
               !supportedTotalRange.contains(total)
            {
                return .unsafe(reason: .totalOutOfRange)
            }
            return .unsafe(reason: .malformedTotal)
        }
        let total = totalRead.value

        let roll = CharacterRoll(
            name: nameValue,
            total: total
        )

        if total < minimumTotal {
            let target = CharacterRerollTarget(
                sourceText: randomObservation.observation.text,
                rect: randomObservation.observation.rect,
                point: measuredRandomButtonPoint
            )
            return .rerollRequired(roll: roll, target: target)
        }
        return .thresholdReached(roll: roll)
    }

    private static let minimumStrongAnchorConfidence = 0.60
    private static let minimumMeasuredAnchorConfidence = 0.50
    private static let minimumFullFrameTotalConfidence = 0.30
    private static let minimumIdentityConfidence = 0.30

    private static let titleGate = RegionGate(x: 0.30...0.70, y: 0.08...0.15)
    private static let randomGate = RegionGate(
        x: (measuredRandomButtonRect.x)...(
            measuredRandomButtonRect.x + measuredRandomButtonRect.width
        ),
        y: (measuredRandomButtonRect.y)...(
            measuredRandomButtonRect.y + measuredRandomButtonRect.height
        )
    )
    private static let statusGate = RegionGate(x: 0.40...0.60, y: 0.29...0.36)
    private static let nameGate = RegionGate(x: 0.00...0.70, y: 0.14...0.185)
    private static let totalGate = RegionGate(x: 0.75...0.98, y: 0.29...0.36)
    private static let distributeGate = RegionGate(x: 0.75...0.98, y: 0.34...0.40)
    private static let decideGate = RegionGate(x: 0.40...0.60, y: 0.63...0.68)
    private static let resetGate = RegionGate(x: 0.40...0.60, y: 0.67...0.72)

    private static func resolveAnchor(
        in observations: [IndexedObservation],
        matching predicate: (String) -> Bool,
        gate: RegionGate,
        minimumConfidence: Double
    ) -> Resolution<IndexedObservation> {
        let candidates = observations.filter { predicate($0.canonicalText) }
        guard candidates.count == 1, let candidate = candidates.first else {
            return .failure(.incompleteOrAmbiguousAnchor)
        }
        guard candidate.observation.confidence >= minimumConfidence else {
            return .failure(.lowConfidenceAnchor)
        }
        guard gate.contains(candidate.observation.rect) else {
            return .failure(.misplacedAnchor)
        }
        return .success(candidate)
    }

    private static func resolveIdentity(
        _ specification: IdentitySpecification,
        in observations: [IndexedObservation]
    ) -> Resolution<String> {
        let candidates = observations
            .filter { specification.gate.contains($0.observation.rect) }
            .sorted { lhs, rhs in
                if lhs.observation.rect.x == rhs.observation.rect.x {
                    return lhs.observation.rect.y < rhs.observation.rect.y
                }
                return lhs.observation.rect.x < rhs.observation.rect.x
            }
        guard !candidates.isEmpty else {
            return .failure(.incompleteOrAmbiguousIdentity)
        }
        guard candidates.allSatisfy({
            $0.observation.confidence >= minimumIdentityConfidence
        }) else {
            return .failure(.lowConfidenceIdentity)
        }
        guard let first = candidates.first,
              first.observation.rect.x <= 0.08,
              candidates.allSatisfy({ specification.gate.contains($0.observation.rect) })
        else {
            return .failure(.misplacedIdentity)
        }

        for (left, right) in zip(candidates, candidates.dropFirst()) {
            let gap = right.observation.rect.x
                - (left.observation.rect.x + left.observation.rect.width)
            guard gap <= 0.08 else {
                return .failure(.incompleteOrAmbiguousIdentity)
            }
        }

        let row = candidates.map(\.canonicalText).joined()
        guard row.hasPrefix(specification.prefix) else {
            return .failure(.malformedIdentity)
        }
        let value = String(row.dropFirst(specification.prefix.count))
        guard !value.isEmpty,
              !value.contains(":"),
              value.unicodeScalars.count <= 40
        else {
            return .failure(.malformedIdentity)
        }
        return .success(value)
    }

    private static func parseTotal(_ canonicalText: String) -> Int? {
        let prefix = "TOTAL:"
        guard canonicalText.hasPrefix(prefix) else {
            return nil
        }
        return parseASCIIDigits(String(canonicalText.dropFirst(prefix.count)))
    }

    private static func parseASCIIDigits(_ text: String) -> Int? {
        let scalars = text.unicodeScalars
        guard !scalars.isEmpty,
              text == "0" || !text.hasPrefix("0"),
              scalars.allSatisfy({ (48...57).contains($0.value) })
        else {
            return nil
        }
        return Int(text)
    }

    private struct IndexedObservation {
        let observation: OCRTextObservation
        let canonicalText: String

        init(observation: OCRTextObservation) {
            self.observation = observation
            canonicalText = CharacterRerollDetector.canonicalText(observation.text)
        }

        var isValid: Bool {
            !canonicalText.isEmpty
                && observation.rect.isValid
                && observation.confidence.isFinite
                && (0...1).contains(observation.confidence)
        }
    }

    private struct IdentitySpecification {
        let prefix: String
        let gate: RegionGate
    }

    private struct RegionGate {
        let x: ClosedRange<Double>
        let y: ClosedRange<Double>

        func contains(_ rect: NormalizedRect) -> Bool {
            x.contains(rect.x)
                && x.contains(rect.x + rect.width)
                && y.contains(rect.y)
                && y.contains(rect.y + rect.height)
        }
    }

    private struct Resolution<Value> {
        let value: Value?
        let reason: CharacterRerollUnsafeReason?

        static func success(_ value: Value) -> Self {
            Self(value: value, reason: nil)
        }

        static func failure(_ reason: CharacterRerollUnsafeReason) -> Self {
            Self(value: nil, reason: reason)
        }
    }

    private static func canonicalText(_ text: String) -> String {
        let compatible = text.precomposedStringWithCompatibilityMapping.uppercased()
        let scalars = compatible.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }
        return String(String.UnicodeScalarView(scalars))
            .replacingOccurrences(of: "：", with: ":")
    }
}
