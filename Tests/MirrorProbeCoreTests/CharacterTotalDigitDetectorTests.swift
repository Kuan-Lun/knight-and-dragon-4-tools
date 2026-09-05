import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import MirrorProbeCore

@Suite("Character total digit pixel detector")
struct CharacterTotalDigitDetectorTests {
    @Test("One, two, and three right-aligned glyphs are counted", arguments: [1, 2, 3])
    func countsGlyphs(count: Int) {
        let frame = makeFrame(glyphCount: count)

        #expect(CharacterTotalDigitDetector.detectRGBA(
            frame.bytes,
            width: frame.width,
            height: frame.height,
            bytesPerRow: frame.bytesPerRow
        ) == .digitCount(count))
    }

    @Test("Tiny texture specks do not invent another digit")
    func ignoresTinyNoise() {
        var frame = makeFrame(glyphCount: 2)
        setPixel(x: 389, y: 285, value: 220, frame: &frame)
        setPixel(x: 390, y: 285, value: 220, frame: &frame)

        #expect(detect(frame) == .digitCount(2))
    }

    @Test("Even a sub-threshold narrow mark in the hundreds slot fails closed")
    func faintLeadingOneFailsClosed() {
        var frame = makeFrame(glyphCount: 2)
        setPixel(x: 370, y: 287, value: 90, frame: &frame)
        setPixel(x: 370, y: 288, value: 90, frame: &frame)

        #expect(detect(frame) == .boundaryAmbiguous)
    }

    @Test("A narrow but complete leading one is counted as the third digit")
    func narrowLeadingOneIsCounted() {
        var frame = makeFrame(glyphCount: 2)
        drawRect(x: 371, y: 287, width: 2, height: 9, frame: &frame)

        #expect(detect(frame) == .digitCount(3))
    }

    @Test("The thresholded live total 73 pixel mask is two digits")
    func measuredLiveTotalMask() {
        // Extracted from DevelopmentFixtures/CharacterReroll/total-73-glyph.png.
        let foregroundPoints = [
            (375,287),(376,287),(377,287),(378,287),(379,287),(382,287),(383,287),(384,287),(385,287),
            (376,288),(377,288),(378,288),(382,288),(383,288),(385,288),
            (377,289),(378,289),(381,289),(382,289),
            (377,290),(378,290),(381,290),(382,290),(383,290),(384,290),
            (377,291),(381,291),(382,291),(383,291),(384,291),(385,291),
            (376,292),(377,292),(381,292),(382,292),(385,292),
            (376,293),(377,293),(382,293),(385,293),
            (376,294),(377,294),(382,294),(383,294),(384,294),(385,294),
            (376,295),(377,295),(383,295),(384,295),
        ]
        var frame = makeFrame(glyphCount: 0)
        for (x, y) in foregroundPoints {
            setPixel(x: x, y: y, value: 180, frame: &frame)
        }

        #expect(detect(frame) == .digitCount(2))
    }

    @Test("Durable live 69, 73, 76, and 97 PNGs remain valid two-digit frames")
    func durableLivePNGs() throws {
        for name in [
            "total-69.png",
            "total-73-glyph.png",
            "total-76.png",
            "total-97-full-reads-91.png",
        ] {
            let frame = try loadDurableFrame(name)
            #expect(detect(frame) == .digitCount(2), Comment(rawValue: name))
        }
    }

    @Test("Missing, oversized, excessive, or shifted components fail closed")
    func invalidGeometryFailsClosed() {
        let missing = makeFrame(glyphCount: 0)

        var oversized = makeFrame(glyphCount: 0)
        drawRect(x: 374, y: 287, width: 10, height: 9, frame: &oversized)

        var excessive = makeFrame(glyphCount: 0)
        for x in [368, 374, 380, 386] {
            drawRect(x: x, y: 287, width: 3, height: 9, frame: &excessive)
        }

        var shifted = makeFrame(glyphCount: 0)
        drawRect(x: 374, y: 287, width: 5, height: 9, frame: &shifted)

        for frame in [missing, oversized, excessive, shifted] {
            #expect(detect(frame) == .unsafe)
        }
    }

    @Test("Invalid byte layouts fail closed")
    func invalidFrameFailsClosed() {
        #expect(CharacterTotalDigitDetector.detectRGBA(
            [],
            width: 406,
            height: 890,
            bytesPerRow: 406 * 4
        ) == .unsafe)
        #expect(CharacterTotalDigitDetector.detectRGBA(
            [UInt8](repeating: 0, count: 16),
            width: 0,
            height: 1,
            bytesPerRow: 4
        ) == .unsafe)

        let distorted = TestFrame(width: 406, height: 800, background: 50)
        #expect(detect(distorted) == .unsafe)
    }

    private func detect(_ frame: TestFrame) -> CharacterTotalDigitDetection {
        CharacterTotalDigitDetector.detectRGBA(
            frame.bytes,
            width: frame.width,
            height: frame.height,
            bytesPerRow: frame.bytesPerRow
        )
    }

    private func makeFrame(glyphCount: Int) -> TestFrame {
        var frame = TestFrame(width: 406, height: 890, background: 50)
        guard glyphCount > 0 else { return frame }
        let firstX = 381 - (glyphCount - 1) * 6
        for index in 0..<glyphCount {
            drawRect(x: firstX + index * 6, y: 287, width: 5, height: 9, frame: &frame)
        }
        return frame
    }

    private func loadDurableFrame(_ name: String) throws -> TestFrame {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repositoryRoot
            .appendingPathComponent("DevelopmentFixtures", isDirectory: true)
            .appendingPathComponent("CharacterReroll", isDirectory: true)
            .appendingPathComponent(name)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo
                  )
            else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        #expect(rendered)
        return TestFrame(
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            bytes: bytes
        )
    }

    private func drawRect(
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        frame: inout TestFrame
    ) {
        for pixelY in y..<(y + height) {
            for pixelX in x..<(x + width) {
                setPixel(x: pixelX, y: pixelY, value: 200, frame: &frame)
            }
        }
    }

    private func setPixel(x: Int, y: Int, value: UInt8, frame: inout TestFrame) {
        let offset = y * frame.bytesPerRow + x * 4
        frame.bytes[offset] = value
        frame.bytes[offset + 1] = value
        frame.bytes[offset + 2] = value
        frame.bytes[offset + 3] = 255
    }
}

private struct TestFrame {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    var bytes: [UInt8]

    init(width: Int, height: Int, background: UInt8) {
        self.width = width
        self.height = height
        bytesPerRow = width * 4
        bytes = [UInt8](repeating: background, count: bytesPerRow * height)
        for index in stride(from: 3, to: bytes.count, by: 4) {
            bytes[index] = 255
        }
    }

    init(width: Int, height: Int, bytesPerRow: Int, bytes: [UInt8]) {
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.bytes = bytes
    }
}
