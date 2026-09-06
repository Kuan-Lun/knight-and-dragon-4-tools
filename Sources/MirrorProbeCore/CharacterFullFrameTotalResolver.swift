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
/// anchors. Vision may merge the row or split its adjacent label and digits. This lets a credible
/// keeper value remain sticky even when unrelated OCR briefly fails.
public enum CharacterFullFrameTotalResolver {
    public static func resolve(
        observations: [OCRTextObservation]
    ) -> CharacterFullFrameTotalResolution {
        let candidates = observations.filter { rowGate.contains($0.rect) }
            .sorted { lhs, rhs in
                if lhs.rect.x == rhs.rect.x {
                    return lhs.rect.y < rhs.rect.y
                }
                return lhs.rect.x < rhs.rect.x
            }
        guard candidates.contains(where: { canonicalText($0.text).hasPrefix("TOTAL") }) else {
            return .unavailable
        }
        if let read = resolveCandidates(candidates) {
            return .exact(read)
        }

        // Extra row text must not disappear when a valid split is assembled. Retain any exact
        // subrow only as veto evidence; the whole contaminated row can never authorize a click.
        var credibleReads: [CharacterFullFrameTotalRead] = []
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
    ) -> CharacterFullFrameTotalRead? {
        guard (1...3).contains(candidates.count),
              candidates.allSatisfy({ candidate in
                  candidate.rect.isValid
                      && candidate.confidence.isFinite
                      && (minimumConfidence...1).contains(candidate.confidence)
              }),
              let first = candidates.first,
              let last = candidates.last
        else {
            return nil
        }
        if candidates.count > 1 {
            // Match the measured focused-row geometry while retaining the full-frame confidence
            // floor. A slight overlap is a measured Vision segmentation artifact, not a gap to
            // bridge by guessing missing text.
            guard candidates.allSatisfy({ splitRowGate.contains($0.rect) }),
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
        return CharacterFullFrameTotalRead(value: value, digitCount: digits.count)
    }

    private static let minimumConfidence = 0.30
    private static let rowGate = RegionGate(x: 0.75...0.98, y: 0.29...0.36)
    private static let splitRowGate = RegionGate(x: 0.78...0.98, y: 0.305...0.35)

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
