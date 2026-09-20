import Foundation

/// iPhone Mirroring paints the phone screen inside a window border whose thickness is fixed in
/// points: 38 above, 8 below and 7.5 on each side. Zooming the window (顯示方式 > 放大／縮小)
/// scales only the phone content, so a capture at another zoom level is not proportional to the
/// 406x890 reference capture which calibrated every normalized region in this module.
///
/// Recognition therefore runs on a canvas that places the detected content at the reference
/// proportions. Content pixels are copied unchanged and only the border is regenerated, so a
/// reference-size capture is its own canvas. Action targets stay in canvas coordinates; inputs
/// map them back to the captured window through `sourceNormalizedPoint(forCanvas:)`.
public struct MirrorContentLayout: Equatable, Sendable {
    public struct PixelRect: Equatable, Sendable {
        public let x: Int
        public let y: Int
        public let width: Int
        public let height: Int

        public init(x: Int, y: Int, width: Int, height: Int) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    public static let referenceWidth = 406
    public static let referenceHeight = 890
    /// Measured on the 406x890 reference capture: 38 rows above, 8 below, 7 columns each side.
    public static let referenceContent = PixelRect(x: 7, y: 38, width: 392, height: 844)
    /// Zoom levels round to whole points, so the content aspect ratio drifts by a few
    /// thousandths. The tolerance admits that rounding, not a device with another screen shape.
    public static let maximumContentAspectDeviation = 0.012

    public let sourceWidth: Int
    public let sourceHeight: Int
    public let sourceContent: PixelRect
    public let canvasWidth: Int
    public let canvasHeight: Int
    public let canvasContent: PixelRect
    /// RGBA border color used to regenerate the canvas border.
    public let border: [UInt8]

    /// Window sizes (points) of the iPhone Mirroring zoom levels on a 1x display, smallest to
    /// largest. Glyph rasterization differs between window sizes, and the templates were
    /// sampled at exactly these sizes, so recognition is only calibrated here; a window dragged
    /// to another size is resized to the nearest level before a session starts.
    public static let calibratedWindowSizes: [(width: Double, height: Double)] = [
        (211, 468), (250, 553), (289, 637), (328, 722), (367, 806), (406, 890), (439, 960),
    ]

    /// The calibrated size closest in width to `size`, or nil when `size` already is one.
    public static func nearestCalibratedWindowSize(
        for size: (width: Double, height: Double)
    ) -> (width: Double, height: Double)? {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              let nearest = calibratedWindowSizes.min(by: {
                  abs($0.width - size.width) < abs($1.width - size.width)
              })
        else { return nil }
        let alreadyCalibrated = abs(nearest.width - size.width) <= 0.5
            && abs(nearest.height - size.height) <= 0.5
        return alreadyCalibrated ? nil : nearest
    }

    /// Recognition regions are calibrated on the reference frame, so every detector requires a
    /// frame (or canvas) with the reference proportions and at least half its size.
    public static func hasReferenceProportions(width: Int, height: Int) -> Bool {
        width >= 200 && height >= 400
            && abs(Double(width) / Double(height) - Double(referenceWidth) / Double(referenceHeight)) <= 0.01
    }

    /// A reference-size capture needs no canvas; its bytes are used as captured.
    public var isIdentity: Bool {
        sourceWidth == canvasWidth && sourceHeight == canvasHeight
            && sourceContent == canvasContent
    }

    /// Content pixels per reference pixel on each axis.
    public var scaleX: Double {
        Double(sourceContent.width) / Double(Self.referenceContent.width)
    }

    public var scaleY: Double {
        Double(sourceContent.height) / Double(Self.referenceContent.height)
    }

    public var summary: String {
        "source=\(sourceWidth)x\(sourceHeight), sourceContent=\(describe(sourceContent)), "
            + "canvas=\(canvasWidth)x\(canvasHeight), canvasContent=\(describe(canvasContent)), "
            + "identity=\(isIdentity)"
    }

    /// A frame whose border could not be detected is recognized exactly as captured.
    public static func identity(width: Int, height: Int) -> MirrorContentLayout {
        let whole = PixelRect(x: 0, y: 0, width: width, height: height)
        return .init(
            sourceWidth: width, sourceHeight: height, sourceContent: whole,
            canvasWidth: width, canvasHeight: height, canvasContent: whole,
            border: [0, 0, 0, 255]
        )
    }

    /// Finds the uniform border around the phone content. Every border row and column must
    /// equal the top-left pixel, the four thicknesses must keep the mirroring window's fixed
    /// proportions, and the content must keep the reference aspect ratio. Any other frame,
    /// including a blank or edge-to-edge one, has no detectable layout.
    public static func detect(
        _ bytes: [UInt8], width: Int, height: Int, bytesPerRow: Int
    ) -> MirrorContentLayout? {
        guard width >= 40, height >= 80, width <= 10_000, height <= 10_000,
              bytesPerRow >= width * 4, bytesPerRow <= Int.max / height,
              bytes.count >= bytesPerRow * height
        else { return nil }
        let red = bytes[0], green = bytes[1], blue = bytes[2]
        return bytes.withUnsafeBufferPointer { buffer -> MirrorContentLayout? in
            func isBorder(_ x: Int, _ y: Int) -> Bool {
                let offset = y * bytesPerRow + x * 4
                return buffer[offset] == red && buffer[offset + 1] == green
                    && buffer[offset + 2] == blue
            }
            func rowIsBorder(_ y: Int) -> Bool {
                for x in 0..<width where !isBorder(x, y) { return false }
                return true
            }
            func columnIsBorder(_ x: Int) -> Bool {
                for y in 0..<height where !isBorder(x, y) { return false }
                return true
            }
            let rowLimit = height / 4, columnLimit = width / 4
            var top = 0
            while top < rowLimit, rowIsBorder(top) { top += 1 }
            var bottom = 0
            while bottom < rowLimit, rowIsBorder(height - 1 - bottom) { bottom += 1 }
            var left = 0
            while left < columnLimit, columnIsBorder(left) { left += 1 }
            var right = 0
            while right < columnLimit, columnIsBorder(width - 1 - right) { right += 1 }
            // Reaching a limit means no content edge was found on that side.
            guard top > 0, bottom > 0, left > 0, right > 0,
                  top < rowLimit, bottom < rowLimit, left < columnLimit, right < columnLimit,
                  abs(left - right) <= 1, abs(bottom - left) <= 2
            else { return nil }
            let topToBottom = Double(top) / Double(bottom)
            guard topToBottom >= 4, topToBottom <= 5.5 else { return nil }
            let contentWidth = width - left - right, contentHeight = height - top - bottom
            guard contentWidth >= 100, contentHeight >= 200 else { return nil }
            let referenceAspect = Double(referenceContent.width) / Double(referenceContent.height)
            let aspect = Double(contentWidth) / Double(contentHeight)
            guard abs(aspect - referenceAspect) <= maximumContentAspectDeviation else { return nil }

            let scaleX = Double(contentWidth) / Double(referenceContent.width)
            let scaleY = Double(contentHeight) / Double(referenceContent.height)
            let canvasX = Int((Double(referenceContent.x) * scaleX).rounded())
            let canvasY = Int((Double(referenceContent.y) * scaleY).rounded())
            let canvasWidth = max(Int((Double(referenceWidth) * scaleX).rounded()), canvasX + contentWidth)
            let canvasHeight = max(Int((Double(referenceHeight) * scaleY).rounded()), canvasY + contentHeight)
            return .init(
                sourceWidth: width, sourceHeight: height,
                sourceContent: PixelRect(x: left, y: top, width: contentWidth, height: contentHeight),
                canvasWidth: canvasWidth, canvasHeight: canvasHeight,
                canvasContent: PixelRect(x: canvasX, y: canvasY, width: contentWidth, height: contentHeight),
                border: [red, green, blue, 255]
            )
        }
    }

    /// Builds the canvas (bytesPerRow = canvasWidth * 4) from the frame this layout was detected
    /// on. Returns nil when the frame dimensions differ from the detected source.
    public func canvasRGBA(
        _ bytes: [UInt8], width: Int, height: Int, bytesPerRow: Int
    ) -> [UInt8]? {
        guard width == sourceWidth, height == sourceHeight,
              bytesPerRow >= width * 4, bytesPerRow <= Int.max / height,
              bytes.count >= bytesPerRow * height,
              sourceContent.x >= 0, sourceContent.y >= 0,
              sourceContent.x + sourceContent.width <= width,
              sourceContent.y + sourceContent.height <= height,
              canvasContent.x >= 0, canvasContent.y >= 0,
              canvasContent.width == sourceContent.width,
              canvasContent.height == sourceContent.height,
              canvasContent.x + canvasContent.width <= canvasWidth,
              canvasContent.y + canvasContent.height <= canvasHeight,
              border.count == 4
        else { return nil }
        if isIdentity, bytesPerRow == width * 4 { return bytes }
        let canvasBytesPerRow = canvasWidth * 4
        var canvas = [UInt8](repeating: 0, count: canvasBytesPerRow * canvasHeight)
        canvas.withUnsafeMutableBufferPointer { destination in
            for offset in stride(from: 0, to: destination.count, by: 4) {
                destination[offset] = border[0]
                destination[offset + 1] = border[1]
                destination[offset + 2] = border[2]
                destination[offset + 3] = border[3]
            }
            bytes.withUnsafeBufferPointer { source in
                let rowBytes = sourceContent.width * 4
                for row in 0..<sourceContent.height {
                    let sourceOffset = (sourceContent.y + row) * bytesPerRow + sourceContent.x * 4
                    let destinationOffset = (canvasContent.y + row) * canvasBytesPerRow
                        + canvasContent.x * 4
                    for byte in 0..<rowBytes {
                        destination[destinationOffset + byte] = source[sourceOffset + byte]
                    }
                }
            }
        }
        return canvas
    }

    /// Maps a canvas-normalized point (as produced by recognition) to the captured frame.
    public func sourceNormalizedPoint(forCanvas point: NormalizedPoint) -> NormalizedPoint {
        let x = point.x * Double(canvasWidth) - Double(canvasContent.x) + Double(sourceContent.x)
        let y = point.y * Double(canvasHeight) - Double(canvasContent.y) + Double(sourceContent.y)
        return NormalizedPoint(x: x / Double(sourceWidth), y: y / Double(sourceHeight))
    }

    /// Maps a point in the captured frame to canvas coordinates.
    public func canvasNormalizedPoint(forSource point: NormalizedPoint) -> NormalizedPoint {
        let x = point.x * Double(sourceWidth) - Double(sourceContent.x) + Double(canvasContent.x)
        let y = point.y * Double(sourceHeight) - Double(sourceContent.y) + Double(canvasContent.y)
        return NormalizedPoint(x: x / Double(canvasWidth), y: y / Double(canvasHeight))
    }

    private func describe(_ rect: PixelRect) -> String {
        "[x=\(rect.x),y=\(rect.y),width=\(rect.width),height=\(rect.height)]"
    }
}
