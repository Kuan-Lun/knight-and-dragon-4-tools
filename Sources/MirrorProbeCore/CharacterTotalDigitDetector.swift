import Foundation

/// Pixel evidence for the number of rendered digits at the right edge of the custom-character
/// page's `total` row. This intentionally does not recognize which digits were drawn: its only
/// job is to catch an OCR result which dropped or invented a digit around the `100` boundary.
public enum CharacterTotalDigitDetection: Equatable, Sendable {
    case digitCount(Int)
    /// Faint ink appeared in the calibrated hundreds slot but did not form a normal glyph. This
    /// may be a clipped leading `1`, so later clean-looking two-digit samples must not erase it.
    case boundaryAmbiguous
    case unsafe
}

public enum CharacterTotalDigitDetector {
    /// Calibrated from the 406 x 890 iPhone Mirroring capture. The region excludes the colon on
    /// the left and the decorative vertical rule on the right, leaving only the right-aligned
    /// one-to-three digit value.
    public static let measuredDigitRegion = NormalizedRect(
        x: 0.906,
        y: 0.318,
        width: 0.060,
        height: 0.021
    )

    public static func detectRGBA(
        _ bytes: [UInt8],
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) -> CharacterTotalDigitDetection {
        guard width > 0,
              height > 0,
              width <= Int.max / 4,
              bytesPerRow >= width * 4,
              bytesPerRow <= Int.max / height,
              bytes.count >= bytesPerRow * height
        else {
            return .unsafe
        }

        let region = measuredDigitRegion
        let minX = max(0, min(width - 1, Int(floor(region.x * Double(width)))))
        let maxX = max(
            minX + 1,
            min(width, Int(ceil((region.x + region.width) * Double(width))))
        )
        let minY = max(0, min(height - 1, Int(floor(region.y * Double(height)))))
        let maxY = max(
            minY + 1,
            min(height, Int(ceil((region.y + region.height) * Double(height))))
        )
        let regionWidth = maxX - minX
        let regionHeight = maxY - minY
        guard regionWidth > 0,
              regionHeight > 0,
              regionWidth <= Int.max / regionHeight
        else {
            return .unsafe
        }

        var foreground = Array(repeating: false, count: regionWidth * regionHeight)
        var faintHundredsSlotInk = false
        for localY in 0..<regionHeight {
            for localX in 0..<regionWidth {
                let offset = (minY + localY) * bytesPerRow + (minX + localX) * 4
                let red = Int(bytes[offset])
                let green = Int(bytes[offset + 1])
                let blue = Int(bytes[offset + 2])
                let alpha = Int(bytes[offset + 3])
                let luminance = (54 * red + 183 * green + 19 * blue) >> 8
                foreground[localY * regionWidth + localX] = alpha >= 250 && luminance >= 100
                let normalizedX = (Double(minX + localX) + 0.5) / Double(width)
                if alpha >= 250, normalizedX < 0.919, luminance >= 80 {
                    faintHundredsSlotInk = true
                }
            }
        }

        let horizontalScale = Double(width) / 406.0
        let verticalScale = Double(height) / 890.0
        let referenceScale = min(horizontalScale, verticalScale)
        guard referenceScale >= 0.75, referenceScale <= 4 else {
            return .unsafe
        }
        guard abs(horizontalScale - verticalScale) / referenceScale <= 0.02 else {
            return .unsafe
        }
        let minimumArea = max(3, Int(floor(5 * referenceScale * referenceScale)))
        let maximumArea = max(minimumArea, Int(ceil(50 * referenceScale * referenceScale)))
        let minimumHeight = max(3, Int(floor(6 * referenceScale)))
        let maximumHeight = max(minimumHeight, Int(ceil(12 * referenceScale)))
        let maximumWidth = max(2, Int(ceil(8 * referenceScale)))
        let maximumGap = max(2, Int(ceil(4 * referenceScale)))

        var visited = Array(repeating: false, count: foreground.count)
        var glyphs: [PixelComponent] = []
        for seedY in 0..<regionHeight {
            for seedX in 0..<regionWidth {
                let seedIndex = seedY * regionWidth + seedX
                guard foreground[seedIndex], !visited[seedIndex] else { continue }

                var queue: [(x: Int, y: Int)] = [(seedX, seedY)]
                visited[seedIndex] = true
                var cursor = 0
                var component = PixelComponent(x: seedX, y: seedY)
                while cursor < queue.count {
                    let point = queue[cursor]
                    cursor += 1
                    component.include(x: point.x, y: point.y)

                    for deltaY in -1...1 {
                        for deltaX in -1...1 where deltaX != 0 || deltaY != 0 {
                            let neighborX = point.x + deltaX
                            let neighborY = point.y + deltaY
                            guard neighborX >= 0,
                                  neighborX < regionWidth,
                                  neighborY >= 0,
                                  neighborY < regionHeight
                            else {
                                continue
                            }
                            let neighborIndex = neighborY * regionWidth + neighborX
                            guard foreground[neighborIndex], !visited[neighborIndex] else {
                                continue
                            }
                            visited[neighborIndex] = true
                            queue.append((neighborX, neighborY))
                        }
                    }
                }

                guard component.area >= minimumArea else { continue }
                guard component.area <= maximumArea,
                      component.width <= maximumWidth,
                      component.height >= minimumHeight,
                      component.height <= maximumHeight
                else {
                    return .unsafe
                }
                glyphs.append(component)
            }
        }

        glyphs.sort { $0.minX < $1.minX }
        guard (1...3).contains(glyphs.count), let last = glyphs.last else {
            return .unsafe
        }
        // A narrow or clipped leading `1` can fall below the normal component-area threshold.
        // When reporting only one/two digits, even faint ink in the calibrated hundreds slot is
        // therefore ambiguous and must never be silently discarded.
        guard glyphs.count == 3 || !faintHundredsSlotInk else {
            return .boundaryAmbiguous
        }
        for (left, right) in zip(glyphs, glyphs.dropFirst()) {
            let gap = right.minX - left.maxX - 1
            guard gap >= 0, gap <= maximumGap else {
                return .unsafe
            }
        }

        let normalizedRightEdge = Double(minX + last.maxX + 1) / Double(width)
        guard (0.945...0.960).contains(normalizedRightEdge) else {
            return .unsafe
        }
        return .digitCount(glyphs.count)
    }

    private struct PixelComponent {
        var minX: Int
        var maxX: Int
        var minY: Int
        var maxY: Int
        var area: Int

        init(x: Int, y: Int) {
            minX = x
            maxX = x
            minY = y
            maxY = y
            area = 0
        }

        var width: Int { maxX - minX + 1 }
        var height: Int { maxY - minY + 1 }

        mutating func include(x: Int, y: Int) {
            minX = min(minX, x)
            maxX = max(maxX, x)
            minY = min(minY, y)
            maxY = max(maxY, y)
            area += 1
        }
    }
}
