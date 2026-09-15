import Foundation

public struct FrameMetrics: Codable, Equatable, Sendable {
    public let sampledPixels: Int
    public let alphaCoverage: Double
    public let nearBlackRatio: Double
    public let meanLuminance: Double
    public let luminanceStandardDeviation: Double
    public let luminanceP05: Double
    public let luminanceP95: Double
    public let quantizedColorCount: Int

    public var isBlank: Bool {
        alphaCoverage < 0.995
            || nearBlackRatio >= 0.98
            || (luminanceP95 - luminanceP05 < 3.0 / 255.0 && quantizedColorCount <= 3)
    }

    public var health: String {
        isBlank ? "blank" : "non_blank"
    }
}

public enum FrameAnalyzerError: Error, Equatable {
    case invalidDimensions
    case invalidCropFraction
    case insufficientBytes
}

public enum FrameAnalyzer {
    /// Analyzes RGBA8888 pixels. A small outer crop ignores rounded corners and shadows.
    public static func analyzeRGBA(
        _ bytes: [UInt8],
        width: Int,
        height: Int,
        bytesPerRow: Int,
        cropFraction: Double = 0.05,
        maximumSamples: Int = 200_000
    ) throws -> FrameMetrics {
        let requiredCount = try requiredRGBAByteCount(
            width: width, height: height, bytesPerRow: bytesPerRow
        )
        guard cropFraction >= 0, cropFraction < 0.5 else {
            throw FrameAnalyzerError.invalidCropFraction
        }
        guard bytes.count >= requiredCount else {
            throw FrameAnalyzerError.insufficientBytes
        }

        let insetX = Int(Double(width) * cropFraction)
        let insetY = Int(Double(height) * cropFraction)
        let minX = min(insetX, width - 1)
        let maxX = max(minX + 1, width - insetX)
        let minY = min(insetY, height - 1)
        let maxY = max(minY + 1, height - insetY)

        let croppedPixelCount = max(1, (maxX - minX) * (maxY - minY))
        let sampleStride = max(
            1,
            Int(ceil(sqrt(Double(croppedPixelCount) / Double(max(1, maximumSamples)))))
        )

        var sampledPixels = 0
        var alphaPixels = 0
        var nearBlackPixels = 0
        var luminanceSum = 0.0
        var luminanceSquaredSum = 0.0
        var luminanceHistogram = Array(repeating: 0, count: 256)
        var quantizedColors = Set<UInt16>()

        var y = minY
        while y < maxY {
            var x = minX
            while x < maxX {
                let offset = y * bytesPerRow + x * 4
                let red = Int(bytes[offset])
                let green = Int(bytes[offset + 1])
                let blue = Int(bytes[offset + 2])
                let alpha = Int(bytes[offset + 3])

                let luminanceByte = min(255, max(0, Int(
                    0.2126 * Double(red)
                        + 0.7152 * Double(green)
                        + 0.0722 * Double(blue)
                )))
                let luminance = Double(luminanceByte) / 255.0

                sampledPixels += 1
                alphaPixels += alpha > 250 ? 1 : 0
                nearBlackPixels += max(red, max(green, blue)) <= 5 ? 1 : 0
                luminanceSum += luminance
                luminanceSquaredSum += luminance * luminance
                luminanceHistogram[luminanceByte] += 1

                let quantized = UInt16((red >> 4) << 8 | (green >> 4) << 4 | (blue >> 4))
                quantizedColors.insert(quantized)

                x += sampleStride
            }
            y += sampleStride
        }

        let count = Double(max(1, sampledPixels))
        let mean = luminanceSum / count
        let variance = max(0, luminanceSquaredSum / count - mean * mean)

        return FrameMetrics(
            sampledPixels: sampledPixels,
            alphaCoverage: Double(alphaPixels) / count,
            nearBlackRatio: Double(nearBlackPixels) / count,
            meanLuminance: mean,
            luminanceStandardDeviation: sqrt(variance),
            luminanceP05: percentile(0.05, histogram: luminanceHistogram, total: sampledPixels),
            luminanceP95: percentile(0.95, histogram: luminanceHistogram, total: sampledPixels),
            quantizedColorCount: quantizedColors.count
        )
    }

    public static func meanAbsoluteDifferenceRGBA(
        _ lhs: [UInt8],
        _ rhs: [UInt8],
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) throws -> Double {
        let requiredCount = try requiredRGBAByteCount(
            width: width, height: height, bytesPerRow: bytesPerRow
        )
        guard lhs.count >= requiredCount, rhs.count >= requiredCount else {
            throw FrameAnalyzerError.insufficientBytes
        }

        var difference = 0.0
        var channelCount = 0
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                for channel in 0..<3 {
                    difference += abs(Double(lhs[offset + channel]) - Double(rhs[offset + channel]))
                    channelCount += 1
                }
            }
        }
        return difference / (Double(channelCount) * 255.0)
    }

    /// Validate the layout before multiplying caller-supplied dimensions. Shared by whole-frame
    /// and regional analysis so malformed images produce an error instead of an overflow trap.
    static func requiredRGBAByteCount(width: Int, height: Int, bytesPerRow: Int) throws -> Int {
        guard width > 0,
              height > 0,
              width <= Int.max / 4,
              bytesPerRow >= width * 4,
              bytesPerRow <= Int.max / height
        else {
            throw FrameAnalyzerError.invalidDimensions
        }
        return bytesPerRow * height
    }

    private static func percentile(
        _ percentile: Double,
        histogram: [Int],
        total: Int
    ) -> Double {
        guard total > 0 else { return 0 }
        let threshold = Int(ceil(Double(total) * percentile))
        var cumulative = 0
        for (value, count) in histogram.enumerated() {
            cumulative += count
            if cumulative >= threshold {
                return Double(value) / 255.0
            }
        }
        return 1
    }
}
