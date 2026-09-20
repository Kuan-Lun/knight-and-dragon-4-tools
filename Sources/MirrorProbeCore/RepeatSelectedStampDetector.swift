import Foundation

/// Pixel evidence from the fixed red stamp area beside the mission-repeat row.
public struct RepeatSelectedStampDetection: Equatable, Sendable {
    public let region: NormalizedRect
    public let redPixelCount: Int
    public let sampledPixelCount: Int
    /// The scrolled-list displacement the stamp area was sampled at; see `VisualResultListOffset`.
    public let listOffset: Double

    public init(
        region: NormalizedRect,
        redPixelCount: Int,
        sampledPixelCount: Int,
        listOffset: Double = 0
    ) {
        self.region = region
        self.redPixelCount = redPixelCount
        self.sampledPixelCount = sampledPixelCount
        self.listOffset = listOffset
    }

    public var redPixelRatio: Double {
        guard sampledPixelCount > 0 else { return 0 }
        return Double(redPixelCount) / Double(sampledPixelCount)
    }

    public var isPresent: Bool {
        isValid && redPixelRatio >= RepeatSelectedStampDetector.minimumRedPixelRatio
    }

    /// A retry of the repeat toggle needs affirmative absence, not merely a stamp too faint
    /// to pass the selected threshold. The tiny allowance is separate from the stamp cutoff.
    public var isClearlyAbsent: Bool {
        isValid && redPixelRatio <= RepeatSelectedStampDetector.maximumAbsentRedPixelRatio
    }

    public var isValid: Bool {
        VisualResultListOffset.isAllowed(listOffset)
            && region == RepeatSelectedStampDetector.measuredRegion(listOffset: listOffset)
            && redPixelCount >= 0
            && sampledPixelCount > 0
            && redPixelCount <= sampledPixelCount
    }
}

public enum RepeatSelectedStampDetectorError: Error, Equatable, Sendable {
    case invalidDimensions
    case insufficientBytes
    case invalidListOffset
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
        // The stamp ends above 0.260. The first dynamic loot row starts near 0.263;
        // the old 0.270 lower edge counted its warm-colored text as partial red ink.
        height: 0.055
    )
    public static let minimumRedPixelRatio = 0.04
    /// Leave the interval above this small noise allowance and below the selected cutoff
    /// ambiguous. Brown separator pixels are excluded by hue before this ratio is computed.
    public static let maximumAbsentRedPixelRatio = 0.001
    public static let evidenceSentinel = "<measured-repeat-selected-red-stamp>"
    public static let absentEvidenceSentinel = "<measured-repeat-unselected-empty-stamp>"

    /// The stamp area moved with a scrolled loot list; see `VisualResultListOffset`.
    public static func measuredRegion(listOffset: Double) -> NormalizedRect {
        listOffset == 0 ? measuredRegion : measuredRegion.offsetY(listOffset)
    }

    public static func detectRGBA(
        _ bytes: [UInt8],
        width: Int,
        height: Int,
        bytesPerRow: Int,
        listOffset: Double = 0
    ) throws -> RepeatSelectedStampDetection {
        guard VisualResultListOffset.isAllowed(listOffset) else {
            throw RepeatSelectedStampDetectorError.invalidListOffset
        }
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

        let region = measuredRegion(listOffset: listOffset)
        let firstX = max(0, min(width - 1, Int(floor(region.x * Double(width)))))
        let lastX = max(
            firstX + 1,
            min(width, Int(ceil((region.x + region.width) * Double(width))))
        )
        let firstY = max(0, min(height - 1, Int(floor(region.y * Double(height)))))
        let lastY = max(
            firstY + 1,
            min(height, Int(ceil((region.y + region.height) * Double(height))))
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
                   // The parchment's brown horizontal rule also has more red than green.
                   // Real selection ink has a much stronger red-to-green difference than
                   // green-to-blue difference, including when blended into the background.
                   red - green >= 2 * (green - blue),
                   green <= 180
                {
                    redPixelCount += 1
                }
                sampledPixelCount += 1
            }
        }

        return RepeatSelectedStampDetection(
            region: region,
            redPixelCount: redPixelCount,
            sampledPixelCount: sampledPixelCount,
            listOffset: listOffset
        )
    }
}
