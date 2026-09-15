import Foundation

public extension FrameAnalyzer {
    /// Measures RGB difference inside one normalized region while omitting any normalized
    /// exclusion regions. Coordinates use the same top-left convention as OCR observations.
    ///
    /// This overload is intended for temporal UI checks where changing chrome (for example,
    /// the iPhone status clock) must not keep an otherwise-stationary game frame alive.
    static func meanAbsoluteDifferenceRGBA(
        _ lhs: [UInt8],
        _ rhs: [UInt8],
        width: Int,
        height: Int,
        bytesPerRow: Int,
        region: NormalizedRect,
        excluding exclusionRegions: [NormalizedRect] = [],
        maximumSamples: Int = 1_000_000
    ) throws -> Double {
        let requiredCount = try requiredRGBAByteCount(
            width: width, height: height, bytesPerRow: bytesPerRow
        )
        guard maximumSamples > 0 else {
            throw FrameAnalyzerError.invalidDimensions
        }
        guard region.isValid, exclusionRegions.allSatisfy(\.isValid) else {
            throw FrameAnalyzerError.invalidCropFraction
        }

        guard lhs.count >= requiredCount, rhs.count >= requiredCount else {
            throw FrameAnalyzerError.insufficientBytes
        }

        let minX = max(0, min(width - 1, Int(floor(region.x * Double(width)))))
        let maxX = max(minX + 1, min(width, Int(ceil((region.x + region.width) * Double(width)))))
        let minY = max(0, min(height - 1, Int(floor(region.y * Double(height)))))
        let maxY = max(minY + 1, min(height, Int(ceil((region.y + region.height) * Double(height)))))

        let regionWidth = maxX - minX
        let regionHeight = maxY - minY
        guard regionWidth <= Int.max / regionHeight else {
            throw FrameAnalyzerError.invalidDimensions
        }
        let regionPixelCount = max(1, regionWidth * regionHeight)
        let sampleStride = max(
            1,
            Int(ceil(sqrt(Double(regionPixelCount) / Double(maximumSamples))))
        )

        var difference = 0.0
        var channelCount = 0
        var y = minY
        while y < maxY {
            var x = minX
            while x < maxX {
                let normalizedX = (Double(x) + 0.5) / Double(width)
                let normalizedY = (Double(y) + 0.5) / Double(height)
                let isExcluded = exclusionRegions.contains {
                    normalizedX >= $0.x
                        && normalizedX <= $0.x + $0.width
                        && normalizedY >= $0.y
                        && normalizedY <= $0.y + $0.height
                }

                if !isExcluded {
                    let offset = y * bytesPerRow + x * 4
                    for channel in 0..<3 {
                        difference += abs(
                            Double(lhs[offset + channel]) - Double(rhs[offset + channel])
                        )
                        channelCount += 1
                    }
                }
                x += sampleStride
            }
            y += sampleStride
        }

        guard channelCount > 0 else {
            throw FrameAnalyzerError.invalidCropFraction
        }
        return difference / (Double(channelCount) * 255.0)
    }
}
