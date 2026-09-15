import Foundation

public enum VisualBattleActivityError: Error, Equatable, Sendable {
    case invalidDimensions
    case insufficientBytes
    case transparentActivityRegion
}

/// Only fixed party-HP text rows and the battle log contribute progress. Enemy sprites,
/// floating combat panels, the status clock, right-side controls, and skill tray are excluded.
public enum VisualBattleActivityRegion: String, CaseIterable, Equatable, Sendable {
    case partyTopLeft
    case partyTopMiddle
    case partyTopRight
    case partyBottomLeft
    case partyBottomMiddle
    case partyBottomRight
    case combatLog

    public var rect: NormalizedRect {
        switch self {
        case .partyTopLeft: .init(x: 0.185, y: 0.746, width: 0.145, height: 0.020)
        case .partyTopMiddle: .init(x: 0.505, y: 0.746, width: 0.145, height: 0.020)
        case .partyTopRight: .init(x: 0.825, y: 0.746, width: 0.145, height: 0.020)
        case .partyBottomLeft: .init(x: 0.185, y: 0.828, width: 0.145, height: 0.020)
        case .partyBottomMiddle: .init(x: 0.505, y: 0.828, width: 0.145, height: 0.020)
        case .partyBottomRight: .init(x: 0.825, y: 0.828, width: 0.145, height: 0.020)
        case .combatLog: .init(x: 0.035, y: 0.628, width: 0.725, height: 0.065)
        }
    }

    fileprivate var sampleWidth: Int { self == .combatLog ? 96 : 48 }
    fileprivate var sampleHeight: Int { self == .combatLog ? 24 : 8 }
}

/// Actual normalized luminance samples from one captured image, with no recognized text or
/// invented HP values. Matching grid identities and source geometry are mandatory for comparison.
public struct VisualBattleActivityEvidence: Equatable, Sendable {
    public static let minimumMeanAbsoluteDifference = 0.015
    public static let minimumChangedPixelRatio = 0.08
    public static let minimumChangedPixelDifference = 12.0 / 255.0

    public let sourceWidth: Int
    public let sourceHeight: Int
    private let samples: [[Double]]

    private init(sourceWidth: Int, sourceHeight: Int, samples: [[Double]]) {
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.samples = samples
    }

    public static func extractRGBA(
        _ bytes: [UInt8], width: Int, height: Int, bytesPerRow: Int
    ) throws -> VisualBattleActivityEvidence {
        try validateBuffer(bytes, width: width, height: height, bytesPerRow: bytesPerRow)
        var regions: [[Double]] = []
        for region in VisualBattleActivityRegion.allCases {
            var sampled: [Double] = []
            sampled.reserveCapacity(region.sampleWidth * region.sampleHeight)
            for row in 0..<region.sampleHeight {
                let y = (region.rect.y + (Double(row) + 0.5) * region.rect.height
                         / Double(region.sampleHeight)) * Double(height) - 0.5
                let y0 = Int(floor(y)), ty = y - floor(y)
                for column in 0..<region.sampleWidth {
                    let x = (region.rect.x + (Double(column) + 0.5) * region.rect.width
                             / Double(region.sampleWidth)) * Double(width) - 0.5
                    let x0 = Int(floor(x)), tx = x - floor(x)
                    guard x0 >= 0, y0 >= 0, x0 + 1 < width, y0 + 1 < height else {
                        throw VisualBattleActivityError.invalidDimensions
                    }
                    func luminance(_ column: Int, _ row: Int) throws -> Double {
                        let offset = row * bytesPerRow + column * 4
                        guard bytes[offset + 3] >= 250 else {
                            throw VisualBattleActivityError.transparentActivityRegion
                        }
                        let red = 77 * Int(bytes[offset])
                        let green = 150 * Int(bytes[offset + 1])
                        let blue = 29 * Int(bytes[offset + 2])
                        let grayscale = (red + green + blue) >> 8
                        return Double(grayscale) / 255.0
                    }
                    let a = try luminance(x0, y0), b = try luminance(x0 + 1, y0)
                    let c = try luminance(x0, y0 + 1), d = try luminance(x0 + 1, y0 + 1)
                    sampled.append((1 - ty) * ((1 - tx) * a + tx * b)
                                   + ty * ((1 - tx) * c + tx * d))
                }
            }
            regions.append(sampled)
        }
        return VisualBattleActivityEvidence(sourceWidth: width, sourceHeight: height, samples: regions)
    }

    public static func validateBuffer(
        _ bytes: [UInt8], width: Int, height: Int, bytesPerRow: Int
    ) throws {
        guard width >= 200, height >= 400, width <= 10_000, height <= 10_000,
              width * height <= 25_000_000,
              abs(Double(width) / Double(height) - 406.0 / 890.0) <= 0.01,
              bytesPerRow >= width * 4, bytesPerRow <= Int.max / height
        else { throw VisualBattleActivityError.invalidDimensions }
        guard bytes.count >= bytesPerRow * height else {
            throw VisualBattleActivityError.insufficientBytes
        }
    }

    public func hasSignificantChange(from previous: VisualBattleActivityEvidence) -> Bool {
        guard sourceWidth == previous.sourceWidth, sourceHeight == previous.sourceHeight,
              samples.count == VisualBattleActivityRegion.allCases.count,
              previous.samples.count == samples.count
        else { return false }
        for index in samples.indices {
            let old = previous.samples[index], new = samples[index]
            guard old.count == new.count, !new.isEmpty else { return false }
            let count = Double(new.count)
            let oldMean = old.reduce(0, +) / count
            let newMean = new.reduce(0, +) / count
            var rawDifference = 0.0, centeredDifference = 0.0, changedPixels = 0
            for sampleIndex in new.indices {
                rawDifference += abs(new[sampleIndex] - old[sampleIndex])
                // A uniform brightness shift must not masquerade as changing digits or log
                // content. Require both raw and mean-corrected local structural differences.
                let difference = abs((new[sampleIndex] - newMean) - (old[sampleIndex] - oldMean))
                centeredDifference += difference
                if difference >= Self.minimumChangedPixelDifference { changedPixels += 1 }
            }
            if min(rawDifference, centeredDifference) / count >= Self.minimumMeanAbsoluteDifference,
               Double(changedPixels) / count >= Self.minimumChangedPixelRatio {
                return true
            }
        }
        return false
    }
}
