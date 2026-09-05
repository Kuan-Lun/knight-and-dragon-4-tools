import Foundation

public struct CharacterFullFrameTotalRead: Equatable, Sendable {
    public let value: Int
    public let digitCount: Int

    public init(value: Int, digitCount: Int) {
        self.value = value
        self.digitCount = digitCount
    }
}

public enum CharacterFullFrameTotalResolution: Equatable, Sendable {
    case exact(CharacterFullFrameTotalRead)
    /// A TOTAL-like row was present but it was not exactly one credible read. Valid reads remain
    /// available only as sticky keeper evidence; a contaminated result can never authorize a
    /// reroll.
    case contaminated(credibleReads: [CharacterFullFrameTotalRead])
    case unavailable
}

/// Extracts boundary evidence from the full-frame `total` row independently of the other page
/// anchors. This lets a credible keeper value remain sticky even when unrelated OCR briefly fails.
public enum CharacterFullFrameTotalResolver {
    public static func resolve(
        observations: [OCRTextObservation]
    ) -> CharacterFullFrameTotalResolution {
        let candidates = observations.filter {
            canonicalText($0.text).hasPrefix("TOTAL") && rowGate.contains($0.rect)
        }
        let credibleReads = candidates.compactMap(credibleRead)
        guard !candidates.isEmpty else { return .unavailable }
        guard candidates.count == 1, let read = credibleReads.first else {
            return .contaminated(credibleReads: credibleReads)
        }
        return .exact(read)
    }

    private static func credibleRead(
        _ candidate: OCRTextObservation
    ) -> CharacterFullFrameTotalRead? {
        guard candidate.rect.isValid,
              candidate.confidence.isFinite,
              (minimumConfidence...1).contains(candidate.confidence),
              rowGate.contains(candidate.rect)
        else {
            return nil
        }
        let row = canonicalText(candidate.text)
        let prefix = "TOTAL:"
        guard row.hasPrefix(prefix) else {
            return nil
        }
        let digits = String(row.dropFirst(prefix.count))
        guard (1...3).contains(digits.count),
              digits == "0" || !digits.hasPrefix("0"),
              digits.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }),
              let value = Int(digits),
              CharacterRerollDetector.supportedTotalRange.contains(value)
        else {
            return nil
        }
        return CharacterFullFrameTotalRead(value: value, digitCount: digits.count)
    }

    private static let minimumConfidence = 0.30
    private static let rowGate = RegionGate(x: 0.75...0.98, y: 0.29...0.36)

    private struct RegionGate {
        let x: ClosedRange<Double>
        let y: ClosedRange<Double>

        func contains(_ rect: NormalizedRect) -> Bool {
            rect.isValid
                && x.contains(rect.x)
                && x.contains(rect.x + rect.width)
                && y.contains(rect.y)
                && y.contains(rect.y + rect.height)
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
