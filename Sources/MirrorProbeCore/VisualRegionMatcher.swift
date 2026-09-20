import Foundation

/// Shared fixed-region pixel matcher. Correlation preserves glyph shape while absolute
/// luminance agreement rejects dimmed or obscured controls. Registration tolerance never
/// changes an action target.
public enum VisualRegionMatcher {
    public static func bestSimilarity(
        region: NormalizedRect, templates: [[UInt8]], sampleWidth: Int, sampleHeight: Int,
        bytes: [UInt8], width: Int, height: Int, bytesPerRow: Int
    ) -> Double {
        guard region.isValid, sampleWidth > 0, sampleWidth <= 512,
              sampleHeight > 0, sampleHeight <= 512,
              width > 1, height > 1, width <= 10_000, height <= 10_000,
              bytesPerRow >= width * 4,
              bytesPerRow <= Int.max / height, bytes.count >= bytesPerRow * height
        else { return -1 }
        var best = -1.0
        // Native window sizes can place glyphs between the reference pixel centers.
        // Sample quarter-pixel offsets too, keeping the same one-pixel search radius:
        // 404×874 result labels need half offsets and the retreat glyph needs a quarter.
        let offsets = [-1.0, -0.75, -0.5, -0.25, 0, 0.25, 0.5, 0.75, 1.0]
        for yOffset in offsets {
            for xOffset in offsets {
                guard let sample = sample(
                    bytes, width: width, height: height, bytesPerRow: bytesPerRow,
                    region: region, dx: xOffset / 406.0, dy: yOffset / 890.0,
                    sampleWidth: sampleWidth, sampleHeight: sampleHeight
                ) else { continue }
                for template in templates {
                    best = max(best, similarity(sample, template: template))
                }
            }
        }
        return best
    }

    private static func sample(
        _ bytes: [UInt8], width: Int, height: Int, bytesPerRow: Int,
        region: NormalizedRect, dx: Double, dy: Double, sampleWidth: Int, sampleHeight: Int
    ) -> [Double]? {
        func luminance(_ x: Int, _ y: Int) -> Double? {
            let offset = y * bytesPerRow + x * 4
            guard bytes[offset + 3] >= 250 else { return nil }
            return Double((77 * Int(bytes[offset]) + 150 * Int(bytes[offset + 1])
                           + 29 * Int(bytes[offset + 2])) >> 8)
        }
        var result: [Double] = []
        result.reserveCapacity(sampleWidth * sampleHeight)
        for row in 0..<sampleHeight {
            let y = (region.y + (Double(row) + 0.5) * region.height
                     / Double(sampleHeight) + dy) * Double(height) - 0.5
            let y0 = Int(floor(y)), ty = y - floor(y)
            for column in 0..<sampleWidth {
                let x = (region.x + (Double(column) + 0.5) * region.width
                         / Double(sampleWidth) + dx) * Double(width) - 0.5
                let x0 = Int(floor(x)), tx = x - floor(x)
                guard x0 >= 0, y0 >= 0, x0 + 1 < width, y0 + 1 < height,
                      let a = luminance(x0, y0), let b = luminance(x0 + 1, y0),
                      let c = luminance(x0, y0 + 1), let d = luminance(x0 + 1, y0 + 1)
                else { return nil }
                result.append((1 - ty) * ((1 - tx) * a + tx * b) + ty * ((1 - tx) * c + tx * d))
            }
        }
        return result
    }

    private static func similarity(_ sample: [Double], template: [UInt8]) -> Double {
        guard sample.count == template.count, !sample.isEmpty else { return -1 }
        let count = Double(sample.count)
        let sampleMean = sample.reduce(0, +) / count
        let templateMean = template.reduce(0.0) { $0 + Double($1) } / count
        var covariance = 0.0, sampleVariance = 0.0, templateVariance = 0.0, error = 0.0
        for index in sample.indices {
            let pixel = sample[index], expected = Double(template[index])
            let a = pixel - sampleMean, b = expected - templateMean
            covariance += a * b
            sampleVariance += a * a
            templateVariance += b * b
            error += abs(pixel - expected)
        }
        guard sampleVariance > 1, templateVariance > 1 else { return -1 }
        let correlation = covariance / sqrt(sampleVariance * templateVariance)
        let absoluteAgreement = 1 - error / (count * 255)
        return min(1, min(correlation, absoluteAgreement))
    }
}
