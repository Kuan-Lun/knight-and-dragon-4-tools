import Foundation

/// A wide, centered action row detected from rendered pixels rather than OCR.
public struct WideModalButton: Codable, Equatable, Sendable {
    public let rect: NormalizedRect

    public init(rect: NormalizedRect) {
        self.rect = rect
    }
}

public enum WideModalLayout: String, Codable, Equatable, Sendable {
    case none
    case oneButton
    case twoButtons
    /// Retained for decoding historical reports. New detections classify this compact layout as
    /// an ordinary one-button modal under the current user-authorized policy.
    case returnedPartyManualStop
    case unsupportedButtonCount
}

public struct WideModalButtonDetection: Codable, Equatable, Sendable {
    public let buttons: [WideModalButton]
    public let layout: WideModalLayout
    public let dialogRect: NormalizedRect?

    public init(
        buttons: [WideModalButton],
        layout: WideModalLayout,
        dialogRect: NormalizedRect?
    ) {
        self.buttons = buttons
        self.layout = layout
        self.dialogRect = dialogRect
    }
}

public enum WideModalButtonDetectorError: Error, Equatable, Sendable {
    case invalidDimensions
    case insufficientBytes
}

/// Detects the game's wide modal action rows directly from RGBA8888 pixels.
///
/// Coordinates use a top-left origin. The detector intentionally recognizes only the calibrated
/// centered button skin; ordinary battle controls and result-page text do not match its geometry.
public enum WideModalButtonDetector {
    public static func detectRGBA(
        _ bytes: [UInt8],
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) throws -> WideModalButtonDetection {
        // The detector samples a horizontal neighbour (`x - 1`) inside percentage-based
        // side bands. Real mirror frames are much larger, but reject tiny synthetic buffers
        // explicitly so that those bands can never begin at x == 0.
        guard width >= 10,
              height > 0,
              width <= Int.max / 4,
              bytesPerRow >= width * 4,
              bytesPerRow <= Int.max / height
        else {
            throw WideModalButtonDetectorError.invalidDimensions
        }
        guard bytes.count >= bytesPerRow * height else {
            throw WideModalButtonDetectorError.insufficientBytes
        }

        let image = PixelImage(
            bytes: bytes,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow
        )
        let scanStart = max(1, Int(Double(height) * 0.30))
        let scanEnd = min(height - 1, Int(Double(height) * 0.72))
        guard scanStart <= scanEnd else {
            return WideModalButtonDetection(buttons: [], layout: .none, dialogRect: nil)
        }

        let edgeRows = (scanStart...scanEnd).filter { y in
            image.rowEdgeIntervals(y: y).contains {
                isButtonWidthEdge($0, imageWidth: width)
            }
        }
        let edgeBands = mergeRows(
            edgeRows,
            maximumGap: max(1, Int(round(Double(height) * 0.003)))
        )

        var buttons: [WideModalButton] = []
        for index in 0..<max(0, edgeBands.count - 1) {
            let top = edgeBands[index].center
            let bottom = edgeBands[index + 1].center
            let normalizedHeight = (bottom - top) / Double(height)
            guard (0.032...0.049).contains(normalizedHeight),
                  sideEdgeCoverage(image: image, top: top, bottom: bottom) >= 0.90,
                  !hasForegroundFrameInside(image: image, top: top, bottom: bottom)
            else {
                continue
            }

            buttons.append(WideModalButton(rect: NormalizedRect(
                x: 0.108,
                y: top / Double(height),
                width: 0.783,
                height: normalizedHeight
            )))
        }

        let dialogRect = inferDialog(
            image: image,
            buttons: buttons,
            buttonEdges: edgeBands
        )
        let layout: WideModalLayout
        switch buttons.count {
        case 0:
            layout = .none
        case 1:
            layout = .oneButton
        case 2:
            layout = .twoButtons
        default:
            layout = .unsupportedButtonCount
        }
        return WideModalButtonDetection(
            buttons: buttons,
            layout: layout,
            dialogRect: dialogRect
        )
    }

    private struct PixelImage {
        let bytes: [UInt8]
        let width: Int
        let height: Int
        let bytesPerRow: Int

        func colorDistance(x1: Int, y1: Int, x2: Int, y2: Int) -> Double {
            let lhs = y1 * bytesPerRow + x1 * 4
            let rhs = y2 * bytesPerRow + x2 * 4
            let red = Double(Int(bytes[lhs]) - Int(bytes[rhs]))
            let green = Double(Int(bytes[lhs + 1]) - Int(bytes[rhs + 1]))
            let blue = Double(Int(bytes[lhs + 2]) - Int(bytes[rhs + 2]))
            return sqrt(red * red + green * green + blue * blue)
        }

        func rowEdgeIntervals(y: Int, threshold: Double = 20) -> [ClosedRange<Int>] {
            guard y > 0, y < height else { return [] }
            var ranges: [ClosedRange<Int>] = []
            var start: Int?
            let minimumLength = max(3, Int(round(Double(width) * 0.02)))
            for x in 0..<width {
                let isEdge = colorDistance(x1: x, y1: y, x2: x, y2: y - 1) >= threshold
                if isEdge, start == nil {
                    start = x
                } else if !isEdge, let rangeStart = start {
                    if x - rangeStart >= minimumLength {
                        ranges.append(rangeStart...(x - 1))
                    }
                    start = nil
                }
            }
            if let rangeStart = start, width - rangeStart >= minimumLength {
                ranges.append(rangeStart...(width - 1))
            }
            return ranges
        }
    }

    private struct PixelBand {
        let first: Int
        let last: Int
        var center: Double { (Double(first) + Double(last)) / 2 }
    }

    private static func mergeRows(_ rows: [Int], maximumGap: Int) -> [PixelBand] {
        guard let first = rows.first else { return [] }
        var result: [PixelBand] = []
        var bandStart = first
        var previous = first
        for row in rows.dropFirst() {
            if row <= previous + maximumGap {
                previous = row
            } else {
                result.append(PixelBand(first: bandStart, last: previous))
                bandStart = row
                previous = row
            }
        }
        result.append(PixelBand(first: bandStart, last: previous))
        return result
    }

    private static func isButtonWidthEdge(
        _ range: ClosedRange<Int>,
        imageWidth: Int
    ) -> Bool {
        let left = Double(range.lowerBound) / Double(imageWidth)
        let right = Double(range.upperBound) / Double(imageWidth)
        let width = Double(range.count) / Double(imageWidth)
        return (0.105...0.114).contains(left)
            && (0.883...0.893).contains(right)
            && (0.770...0.790).contains(width)
    }

    private static func sideEdgeCoverage(
        image: PixelImage,
        top: Double,
        bottom: Double
    ) -> Double {
        let inset = max(1, Int(round(Double(image.height) * 0.003)))
        let firstY = Int(ceil(top)) + inset
        let lastY = Int(floor(bottom)) - inset
        guard firstY <= lastY else { return 0 }
        let leftRange = Int(floor(Double(image.width) * 0.102))...Int(ceil(Double(image.width) * 0.130))
        let rightRange = Int(floor(Double(image.width) * 0.870))...Int(ceil(Double(image.width) * 0.900))
        var bothSides = 0
        var rowCount = 0
        for y in firstY...lastY {
            let leftEdge = leftRange.map { x in
                image.colorDistance(x1: x, y1: y, x2: x - 1, y2: y)
            }.max() ?? 0
            let rightEdge = rightRange.map { x in
                image.colorDistance(x1: x, y1: y, x2: x - 1, y2: y)
            }.max() ?? 0
            if leftEdge >= 20, rightEdge >= 20 {
                bothSides += 1
            }
            rowCount += 1
        }
        return rowCount == 0 ? 0 : Double(bothSides) / Double(rowCount)
    }

    /// A defeat popup is layered over the retreat confirmation. Its foreground horizontal frame
    /// crosses the apparent lower rectangle, so that exposed background button is not actionable.
    private static func hasForegroundFrameInside(
        image: PixelImage,
        top: Double,
        bottom: Double
    ) -> Bool {
        let inset = max(1, Int(round(Double(image.height) * 0.004)))
        let firstY = Int(ceil(top)) + inset
        let lastY = Int(floor(bottom)) - inset
        guard firstY <= lastY else { return false }
        for y in firstY...lastY {
            for range in image.rowEdgeIntervals(y: y) {
                let left = Double(range.lowerBound) / Double(image.width)
                let right = Double(range.upperBound) / Double(image.width)
                let width = Double(range.count) / Double(image.width)
                if (0.135...0.250).contains(left),
                   (0.785...0.865).contains(right),
                   (0.540...0.730).contains(width) {
                    return true
                }
            }
        }
        return false
    }

    private static func isDialogEdgeRow(image: PixelImage, y: Int) -> Bool {
        let firstX = Int(round(Double(image.width) * 0.081))
        let lastX = Int(round(Double(image.width) * 0.916))
        let leftWing = Int(round(Double(image.width) * 0.073))...Int(round(Double(image.width) * 0.111))
        let rightWing = Int(round(Double(image.width) * 0.889))...Int(round(Double(image.width) * 0.924))
        var strong = 0
        for x in firstX...lastX where
            image.colorDistance(x1: x, y1: y, x2: x, y2: y - 1) >= 20 {
            strong += 1
        }
        let leftCount = leftWing.filter { x in
            image.colorDistance(x1: x, y1: y, x2: x, y2: y - 1) >= 20
        }.count
        let rightCount = rightWing.filter { x in
            image.colorDistance(x1: x, y1: y, x2: x, y2: y - 1) >= 20
        }.count
        return Double(strong) / Double(lastX - firstX + 1) >= 0.78
            && leftCount >= 6
            && rightCount >= 6
    }

    private static func inferDialog(
        image: PixelImage,
        buttons: [WideModalButton],
        buttonEdges: [PixelBand]
    ) -> NormalizedRect? {
        guard let firstButton = buttons.first, let lastButton = buttons.last else { return nil }
        let firstTop = firstButton.rect.y * Double(image.height)
        let lastBottom = (lastButton.rect.y + lastButton.rect.height) * Double(image.height)
        let frameStart = max(1, Int(Double(image.height) * 0.18))
        let frameEnd = min(image.height, Int(Double(image.height) * 0.75))
        guard frameStart < frameEnd else { return nil }
        let frameRows = (frameStart..<frameEnd).filter {
            isDialogEdgeRow(image: image, y: $0)
        }
        let frameBands = mergeRows(
            frameRows,
            maximumGap: max(1, Int(round(Double(image.height) * 0.003)))
        ).filter { frameBand in
            !buttonEdges.contains { buttonBand in
                frameBand.first <= buttonBand.last + 1
                    && frameBand.last + 1 >= buttonBand.first
            }
        }
        let clearance = Double(image.height) * 0.005
        guard let top = frameBands.last(where: { $0.center < firstTop - clearance }),
              let bottom = frameBands.first(where: { $0.center > lastBottom + clearance })
        else {
            return nil
        }
        return NormalizedRect(
            x: 0.081,
            y: top.center / Double(image.height),
            width: 0.835,
            height: (bottom.center - top.center) / Double(image.height)
        )
    }
}
