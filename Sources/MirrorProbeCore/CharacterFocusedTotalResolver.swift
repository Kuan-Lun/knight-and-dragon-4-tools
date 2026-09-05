import Foundation

public struct CharacterFocusedTotalRead: Equatable, Sendable {
    public let value: Int
    public let digitCount: Int

    public init(value: Int, digitCount: Int) {
        self.value = value
        self.digitCount = digitCount
    }
}

public enum CharacterFocusedTotalResolution: Equatable, Sendable {
    case exact(CharacterFocusedTotalRead)
    case contaminated(credibleReads: [CharacterFocusedTotalRead])
    case unavailable
}

/// Resolves the focused `total` row whether Vision returns one merged observation or splits the
/// fixed label and digits into adjacent observations. Geometry and grammar remain fail-closed.
public enum CharacterFocusedTotalResolver {
    public static func resolve(
        observations: [OCRTextObservation]
    ) -> CharacterFocusedTotalRead? {
        guard case let .exact(read) = resolveEvidence(observations: observations) else {
            return nil
        }
        return read
    }

    /// Retains credible subrows as veto-only evidence when extra or malformed OCR contaminates
    /// the focused total crop. A contaminated resolution can never authorize a reroll.
    public static func resolveEvidence(
        observations: [OCRTextObservation]
    ) -> CharacterFocusedTotalResolution {
        let candidates = observations.filter { rowGate.contains($0.rect) }
            .sorted { lhs, rhs in
                if lhs.rect.x == rhs.rect.x {
                    return lhs.rect.y < rhs.rect.y
                }
                return lhs.rect.x < rhs.rect.x
            }
        guard !candidates.isEmpty else { return .unavailable }
        if let exact = resolveCandidates(candidates) {
            return .exact(exact)
        }

        var credibleReads: [CharacterFocusedTotalRead] = []
        for start in candidates.indices {
            let maximumEnd = min(candidates.count, start + 3)
            for end in (start + 1)...maximumEnd {
                guard let read = resolveCandidates(Array(candidates[start..<end])),
                      !credibleReads.contains(read)
                else {
                    continue
                }
                credibleReads.append(read)
            }
        }
        return .contaminated(credibleReads: credibleReads)
    }

    private static func resolveCandidates(
        _ candidates: [OCRTextObservation]
    ) -> CharacterFocusedTotalRead? {
        guard (1...3).contains(candidates.count),
              candidates.allSatisfy({ observation in
                  observation.rect.isValid
                      && observation.confidence.isFinite
                      && observation.confidence >= 0.50
                      && observation.confidence <= 1
              }),
              let first = candidates.first,
              let last = candidates.last,
              (0.79...0.85).contains(first.rect.x),
              (0.93...0.98).contains(last.rect.x + last.rect.width)
        else {
            return nil
        }

        let firstCenterY = first.rect.y + first.rect.height / 2
        for (left, right) in zip(candidates, candidates.dropFirst()) {
            let gap = right.rect.x - (left.rect.x + left.rect.width)
            let centerY = right.rect.y + right.rect.height / 2
            guard gap >= -0.005,
                  gap <= 0.03,
                  abs(centerY - firstCenterY) <= 0.01
            else {
                return nil
            }
        }

        let row = candidates.map { canonicalText($0.text) }.joined()
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
        return CharacterFocusedTotalRead(value: value, digitCount: digits.count)
    }

    private static let rowGate = RegionGate(x: 0.78...0.98, y: 0.305...0.35)

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
