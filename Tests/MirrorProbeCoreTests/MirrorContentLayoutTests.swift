import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import MirrorProbeCore

@Suite("Mirror window content layout detection and canvas mapping")
struct MirrorContentLayoutTests {
    /// A synthetic mirroring capture: uniform border with textured content that never repeats
    /// the border color, so every content row and column is detectable.
    private func syntheticFrame(
        width: Int, height: Int, top: Int, bottom: Int, left: Int, right: Int,
        border: (UInt8, UInt8, UInt8) = (255, 255, 255)
    ) -> RGBAFixtureFrame {
        var frame = RGBAFixtureFrame(bytes: [UInt8](repeating: 0, count: width * height * 4),
                          width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * frame.bytesPerRow + x * 4
                let inContent = x >= left && x < width - right && y >= top && y < height - bottom
                if inContent {
                    frame.bytes[offset] = UInt8((x * 7 + y * 3) % 200)
                    frame.bytes[offset + 1] = UInt8((x * 5 + y * 11) % 200)
                    frame.bytes[offset + 2] = UInt8((x + y) % 200)
                } else {
                    frame.bytes[offset] = border.0
                    frame.bytes[offset + 1] = border.1
                    frame.bytes[offset + 2] = border.2
                }
                frame.bytes[offset + 3] = 255
            }
        }
        return frame
    }

    private func detect(_ frame: RGBAFixtureFrame) -> MirrorContentLayout? {
        MirrorContentLayout.detect(
            frame.bytes, width: frame.width, height: frame.height, bytesPerRow: frame.bytesPerRow
        )
    }

    @Test("The reference capture is its own canvas")
    func referenceCaptureIsIdentity() throws {
        let frame = syntheticFrame(width: 406, height: 890, top: 38, bottom: 8, left: 7, right: 7)
        let layout = try #require(detect(frame))
        #expect(layout.isIdentity)
        #expect(layout.sourceContent == MirrorContentLayout.referenceContent)
        #expect(layout.canvasContent == MirrorContentLayout.referenceContent)
        #expect(layout.scaleX == 1 && layout.scaleY == 1)
        let canvas = try #require(layout.canvasRGBA(
            frame.bytes, width: frame.width, height: frame.height, bytesPerRow: frame.bytesPerRow
        ))
        #expect(canvas == frame.bytes)
        let point = NormalizedPoint(x: 0.3, y: 0.7)
        #expect(layout.sourceNormalizedPoint(forCanvas: point) == point)
    }

    @Test("The smallest zoom level keeps its fixed-point border and halves the content",
          arguments: [(211, 468, 204, 445, 4, 19), (250, 553, 244, 535, 4, 23),
                      (289, 637, 285, 623, 5, 27), (328, 722, 325, 713, 6, 30),
                      (367, 806, 366, 801, 6, 34), (439, 960, 440, 964, 8, 41)])
    func zoomLevelsProduceReferenceProportionedCanvases(
        width: Int, height: Int, canvasWidth: Int, canvasHeight: Int, canvasX: Int, canvasY: Int
    ) throws {
        let frame = syntheticFrame(width: width, height: height, top: 38, bottom: 8, left: 7, right: 7)
        let layout = try #require(detect(frame))
        #expect(!layout.isIdentity)
        #expect(layout.sourceContent == .init(x: 7, y: 38, width: width - 14, height: height - 46))
        #expect(layout.canvasWidth == canvasWidth)
        #expect(layout.canvasHeight == canvasHeight)
        #expect(layout.canvasContent == .init(x: canvasX, y: canvasY, width: width - 14, height: height - 46))
        // The canvas keeps the reference aspect ratio which every detector requires.
        #expect(abs(Double(canvasWidth) / Double(canvasHeight) - 406.0 / 890.0) <= 0.01)

        let canvas = try #require(layout.canvasRGBA(
            frame.bytes, width: width, height: height, bytesPerRow: frame.bytesPerRow
        ))
        #expect(canvas.count == canvasWidth * canvasHeight * 4)
        // Content bytes are copied unchanged; the border is regenerated in the border color.
        for row in 0..<layout.sourceContent.height {
            let source = (38 + row) * frame.bytesPerRow + 7 * 4
            let destination = (canvasY + row) * canvasWidth * 4 + canvasX * 4
            let length = layout.sourceContent.width * 4
            #expect(canvas[destination..<destination + length] == frame.bytes[source..<source + length])
        }
        #expect(canvas[0..<4] == [255, 255, 255, 255])
        #expect(canvas[(canvasHeight * canvasWidth - 1) * 4..<canvasHeight * canvasWidth * 4] == [255, 255, 255, 255])
        // A canvas is a stable fixed point: detecting it again yields the same canvas geometry.
        let again = try #require(MirrorContentLayout.detect(
            canvas, width: canvasWidth, height: canvasHeight, bytesPerRow: canvasWidth * 4
        ))
        #expect(again.canvasWidth == canvasWidth && again.canvasHeight == canvasHeight)
        #expect(again.canvasContent == layout.canvasContent)
        #expect(again.isIdentity)
    }

    @Test("Canvas points map back to the captured content, not to the whole window")
    func canvasPointsMapToSourceContent() throws {
        let frame = syntheticFrame(width: 211, height: 468, top: 38, bottom: 8, left: 7, right: 7)
        let layout = try #require(detect(frame))
        // The canvas content origin maps exactly to the source content origin.
        let canvasOrigin = NormalizedPoint(x: 4.0 / 204.0, y: 19.0 / 445.0)
        let sourceOrigin = layout.sourceNormalizedPoint(forCanvas: canvasOrigin)
        #expect(abs(sourceOrigin.x * 211 - 7) < 1e-9)
        #expect(abs(sourceOrigin.y * 468 - 38) < 1e-9)
        // The measured retreat control center on the reference layout lands inside the
        // proportionally scaled content, offset by the fixed border. Whole-pixel canvas
        // placement keeps the click within one captured pixel of the exact position.
        let retreat = VisualBattleEvidence.measuredRetreatRect.center
        let mapped = layout.sourceNormalizedPoint(forCanvas: retreat)
        let expectedX = (7 + (retreat.x * 406 - 7) * layout.scaleX) / 211
        let expectedY = (38 + (retreat.y * 890 - 38) * layout.scaleY) / 468
        #expect(abs(mapped.x - expectedX) < 1.0 / 211)
        #expect(abs(mapped.y - expectedY) < 1.0 / 468)
        // Round trip.
        let back = layout.canvasNormalizedPoint(forSource: mapped)
        #expect(abs(back.x - retreat.x) < 1e-9 && abs(back.y - retreat.y) < 1e-9)
        // The identity layout maps every point to itself.
        let identity = MirrorContentLayout.identity(width: 211, height: 468)
        #expect(identity.isIdentity)
        #expect(identity.sourceNormalizedPoint(forCanvas: retreat) == retreat)
    }

    @Test("A Retina capture doubles the border in pixels and still detects the layout")
    func retinaCaptureDetectsDoubledBorder() throws {
        let frame = syntheticFrame(width: 812, height: 1780, top: 76, bottom: 16, left: 15, right: 15)
        let layout = try #require(detect(frame))
        #expect(layout.sourceContent == .init(x: 15, y: 76, width: 782, height: 1688))
        #expect(layout.canvasWidth == 810 && layout.canvasHeight == 1780)
        #expect(layout.canvasContent == .init(x: 14, y: 76, width: 782, height: 1688))
    }

    @Test("Frames without the mirroring border have no layout",
          arguments: ["edgeToEdge", "blank", "letterboxed", "asymmetric", "wrongAspect", "shallowTop"])
    func unsupportedFramesHaveNoLayout(kind: String) {
        let frame: RGBAFixtureFrame
        switch kind {
        case "edgeToEdge":
            frame = syntheticFrame(width: 406, height: 890, top: 0, bottom: 0, left: 0, right: 0)
        case "blank":
            frame = syntheticFrame(width: 406, height: 890, top: 445, bottom: 445, left: 203, right: 203)
        case "letterboxed":
            // Content is much wider than the phone screen.
            frame = syntheticFrame(width: 406, height: 890, top: 200, bottom: 42, left: 7, right: 7)
        case "asymmetric":
            frame = syntheticFrame(width: 406, height: 890, top: 38, bottom: 8, left: 7, right: 20)
        case "wrongAspect":
            frame = syntheticFrame(width: 406, height: 890, top: 38, bottom: 60, left: 7, right: 7)
        default:
            frame = syntheticFrame(width: 406, height: 890, top: 12, bottom: 8, left: 7, right: 7)
        }
        #expect(detect(frame) == nil)
    }

    @Test("Real captures at 404x874, 400x878, 402x882 and 812x1780 detect the fixed border",
          arguments: [("visual-battle-404x874", 404, 874, 7, 38),
                      ("footer-occlusion-20260919-capture-4656", 400, 878, 7, 38),
                      ("native-402-battle-capture-0013", 402, 882, 7, 38),
                      ("visual-battle-native-2x", 812, 1780, 15, 76)])
    func realCapturesDetectBorder(name: String, width: Int, height: Int, left: Int, top: Int) throws {
        let frame = try fixture(name)
        #expect(frame.width == width && frame.height == height)
        let layout = try #require(detect(frame))
        #expect(layout.sourceContent.x == left && layout.sourceContent.y == top)
        #expect(layout.sourceContent.width == width - 2 * left)
        #expect(layout.border == [255, 255, 255, 255])
    }

    private func fixture(_ name: String) throws -> RGBAFixtureFrame {
        try loadRGBAFixture(name)
    }
}
