import Testing
@testable import MirrorProbeCore

@Suite("Frame region difference")
struct FrameRegionDifferenceTests {
    @Test("A change outside the selected battle region is ignored")
    func ignoresStatusClockChange() throws {
        let width = 20
        let height = 20
        let original = rgbaImage(width: width, height: height, value: 0)
        var changed = original
        setPixel(x: 2, y: 1, value: 255, width: width, bytes: &changed)

        let full = try FrameAnalyzer.meanAbsoluteDifferenceRGBA(
            original,
            changed,
            width: width,
            height: height,
            bytesPerRow: width * 4
        )
        let battleOnly = try FrameAnalyzer.meanAbsoluteDifferenceRGBA(
            original,
            changed,
            width: width,
            height: height,
            bytesPerRow: width * 4,
            region: NormalizedRect(x: 0, y: 0.10, width: 1, height: 0.90)
        )

        #expect(full > 0)
        #expect(battleOnly == 0)
    }

    @Test("An explicit exclusion masks a changing pixel inside the outer region")
    func explicitExclusion() throws {
        let width = 20
        let height = 20
        let original = rgbaImage(width: width, height: height, value: 0)
        var changed = original
        setPixel(x: 10, y: 10, value: 255, width: width, bytes: &changed)

        let unmasked = try FrameAnalyzer.meanAbsoluteDifferenceRGBA(
            original,
            changed,
            width: width,
            height: height,
            bytesPerRow: width * 4,
            region: NormalizedRect(x: 0, y: 0, width: 1, height: 1)
        )
        let masked = try FrameAnalyzer.meanAbsoluteDifferenceRGBA(
            original,
            changed,
            width: width,
            height: height,
            bytesPerRow: width * 4,
            region: NormalizedRect(x: 0, y: 0, width: 1, height: 1),
            excluding: [NormalizedRect(x: 0.45, y: 0.45, width: 0.10, height: 0.10)]
        )

        #expect(unmasked > 0)
        #expect(masked == 0)
    }

    @Test("An exclusion covering the entire region is rejected")
    func emptySampleSetIsRejected() {
        let image = rgbaImage(width: 4, height: 4, value: 0)
        #expect(throws: FrameAnalyzerError.invalidCropFraction) {
            try FrameAnalyzer.meanAbsoluteDifferenceRGBA(
                image,
                image,
                width: 4,
                height: 4,
                bytesPerRow: 16,
                region: NormalizedRect(x: 0, y: 0, width: 1, height: 1),
                excluding: [NormalizedRect(x: 0, y: 0, width: 1, height: 1)]
            )
        }
    }

    private func rgbaImage(width: Int, height: Int, value: UInt8) -> [UInt8] {
        var bytes = Array(repeating: value, count: width * height * 4)
        for pixel in 0..<(width * height) {
            bytes[pixel * 4 + 3] = 255
        }
        return bytes
    }

    private func setPixel(
        x: Int,
        y: Int,
        value: UInt8,
        width: Int,
        bytes: inout [UInt8]
    ) {
        let offset = (y * width + x) * 4
        bytes[offset] = value
        bytes[offset + 1] = value
        bytes[offset + 2] = value
    }
}
