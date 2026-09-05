import Foundation

/// Pixel evidence from the fixed red stamp area beside the mission-repeat row.
public struct RepeatSelectedStampDetection: Equatable, Sendable {
    public let region: NormalizedRect
    public let redPixelCount: Int
    public let sampledPixelCount: Int

    public init(
        region: NormalizedRect,
        redPixelCount: Int,
        sampledPixelCount: Int
    ) {
        self.region = region
        self.redPixelCount = redPixelCount
        self.sampledPixelCount = sampledPixelCount
    }

    public var redPixelRatio: Double {
        guard sampledPixelCount > 0 else { return 0 }
        return Double(redPixelCount) / Double(sampledPixelCount)
    }

    public var isPresent: Bool {
        isValid && redPixelRatio >= RepeatSelectedStampDetector.minimumRedPixelRatio
    }

    public var isValid: Bool {
        region == RepeatSelectedStampDetector.measuredRegion
            && redPixelCount >= 0
            && sampledPixelCount > 0
            && redPixelCount <= sampledPixelCount
    }
}

public enum RepeatSelectedStampDetectorError: Error, Equatable, Sendable {
    case invalidDimensions
    case insufficientBytes
}

/// Detects whether the fixed result-page stamp area contains the game's red selection ink.
///
/// This deliberately does not recognize the word `SELECTED`. Vision has emitted several
/// spellings for the same rendered stamp. The result classifier still has to establish the
/// unique mission title and repeat row before this pixel signal can authorize anything.
public enum RepeatSelectedStampDetector {
    public static let measuredRegion = NormalizedRect(
        x: 0.33,
        y: 0.205,
        width: 0.37,
        height: 0.065
    )
    public static let minimumRedPixelRatio = 0.04
    public static let evidenceSentinel = "<measured-repeat-selected-red-stamp>"

    public static func detectRGBA(
        _ bytes: [UInt8],
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) throws -> RepeatSelectedStampDetection {
        guard width > 0,
              height > 0,
              width <= Int.max / 4,
              bytesPerRow >= width * 4,
              bytesPerRow <= Int.max / height
        else {
            throw RepeatSelectedStampDetectorError.invalidDimensions
        }
        guard bytes.count >= bytesPerRow * height else {
            throw RepeatSelectedStampDetectorError.insufficientBytes
        }

        let firstX = max(0, min(width - 1, Int(floor(measuredRegion.x * Double(width)))))
        let lastX = max(
            firstX + 1,
            min(width, Int(ceil((measuredRegion.x + measuredRegion.width) * Double(width))))
        )
        let firstY = max(0, min(height - 1, Int(floor(measuredRegion.y * Double(height)))))
        let lastY = max(
            firstY + 1,
            min(height, Int(ceil((measuredRegion.y + measuredRegion.height) * Double(height))))
        )

        var redPixelCount = 0
        var sampledPixelCount = 0
        for y in firstY..<lastY {
            for x in firstX..<lastX {
                let offset = y * bytesPerRow + x * 4
                let red = Int(bytes[offset])
                let green = Int(bytes[offset + 1])
                let blue = Int(bytes[offset + 2])
                let alpha = Int(bytes[offset + 3])
                if alpha >= 200,
                   red >= 90,
                   red - green >= 18,
                   red - blue >= 10,
                   green <= 180
                {
                    redPixelCount += 1
                }
                sampledPixelCount += 1
            }
        }

        return RepeatSelectedStampDetection(
            region: measuredRegion,
            redPixelCount: redPixelCount,
            sampledPixelCount: sampledPixelCount
        )
    }
}
