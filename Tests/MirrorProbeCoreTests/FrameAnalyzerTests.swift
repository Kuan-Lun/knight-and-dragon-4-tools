import Testing
@testable import MirrorProbeCore

@Suite("FrameAnalyzer")
struct FrameAnalyzerTests {
    @Test("A fully black opaque image is rejected")
    func blackFrameIsBlank() throws {
        let pixels = rgbaImage(width: 100, height: 100) { _, _ in (0, 0, 0, 255) }
        let metrics = try FrameAnalyzer.analyzeRGBA(
            pixels,
            width: 100,
            height: 100,
            bytesPerRow: 400
        )

        #expect(metrics.isBlank)
        #expect(metrics.nearBlackRatio == 1)
    }

    @Test("A transparent image is rejected")
    func transparentFrameIsBlank() throws {
        let pixels = rgbaImage(width: 40, height: 40) { _, _ in (255, 255, 255, 0) }
        let metrics = try FrameAnalyzer.analyzeRGBA(
            pixels,
            width: 40,
            height: 40,
            bytesPerRow: 160
        )

        #expect(metrics.isBlank)
        #expect(metrics.alphaCoverage == 0)
    }

    @Test("A varied opaque UI-like image is accepted")
    func variedFrameIsNonBlank() throws {
        let pixels = rgbaImage(width: 120, height: 80) { x, y in
            let red = UInt8((x * 7 + y * 3) % 256)
            let green = UInt8((x * 2 + y * 11) % 256)
            let blue = UInt8((x * 13 + y * 5) % 256)
            return (red, green, blue, 255)
        }
        let metrics = try FrameAnalyzer.analyzeRGBA(
            pixels,
            width: 120,
            height: 80,
            bytesPerRow: 480
        )

        #expect(!metrics.isBlank)
        #expect(metrics.quantizedColorCount > 100)
    }

    @Test("Mean difference reports identical and changed images")
    func meanDifference() throws {
        let black = rgbaImage(width: 10, height: 10) { _, _ in (0, 0, 0, 255) }
        let white = rgbaImage(width: 10, height: 10) { _, _ in (255, 255, 255, 255) }

        let identical = try FrameAnalyzer.meanAbsoluteDifferenceRGBA(
            black,
            black,
            width: 10,
            height: 10,
            bytesPerRow: 40
        )
        let changed = try FrameAnalyzer.meanAbsoluteDifferenceRGBA(
            black,
            white,
            width: 10,
            height: 10,
            bytesPerRow: 40
        )

        #expect(identical == 0)
        #expect(changed == 1)
    }

    private func rgbaImage(
        width: Int,
        height: Int,
        pixel: (_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8)
    ) -> [UInt8] {
        var bytes = Array(repeating: UInt8(0), count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let value = pixel(x, y)
                bytes[offset] = value.0
                bytes[offset + 1] = value.1
                bytes[offset + 2] = value.2
                bytes[offset + 3] = value.3
            }
        }
        return bytes
    }
}
