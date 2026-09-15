import Testing
@testable import MirrorProbeCore

@Suite("Frame analysis buffer boundaries")
struct FrameAnalyzerBoundaryTests {
    @Test("Every frame analysis path rejects invalid or overflowing layouts before accessing bytes")
    func rejectsInvalidLayouts() {
        let layouts: [(width: Int, height: Int, stride: Int)] = [
            (0, 1, 4), (-1, 1, 4), (1, 0, 4), (1, -1, 4),
            (1, 1, -4), (2, 1, 7),
            (Int.max, 1, Int.max), (Int.max / 4 + 1, 1, Int.max),
            (1, 2, Int.max), (1, Int.max, 4),
        ]
        for layout in layouts {
            #expect(throws: FrameAnalyzerError.invalidDimensions) {
                try FrameAnalyzer.analyzeRGBA(
                    [], width: layout.width, height: layout.height, bytesPerRow: layout.stride
                )
            }
            #expect(throws: FrameAnalyzerError.invalidDimensions) {
                try FrameAnalyzer.meanAbsoluteDifferenceRGBA(
                    [], [], width: layout.width, height: layout.height, bytesPerRow: layout.stride
                )
            }
            #expect(throws: FrameAnalyzerError.invalidDimensions) {
                try FrameAnalyzer.meanAbsoluteDifferenceRGBA(
                    [], [], width: layout.width, height: layout.height,
                    bytesPerRow: layout.stride, region: fullRegion
                )
            }
        }
    }

    @Test("A representable large layout reports missing bytes without overflowing")
    func representableLayoutStillChecksBufferLength() {
        let width = Int.max / 4
        #expect(throws: FrameAnalyzerError.insufficientBytes) {
            try FrameAnalyzer.analyzeRGBA([], width: width, height: 1, bytesPerRow: width * 4)
        }
        #expect(throws: FrameAnalyzerError.insufficientBytes) {
            try FrameAnalyzer.meanAbsoluteDifferenceRGBA(
                [], [], width: width, height: 1, bytesPerRow: width * 4
            )
        }
        #expect(throws: FrameAnalyzerError.insufficientBytes) {
            try FrameAnalyzer.meanAbsoluteDifferenceRGBA(
                [], [], width: width, height: 1, bytesPerRow: width * 4, region: fullRegion
            )
        }
    }

    @Test("Each comparison input must contain every row, including its declared padding")
    func rejectsTruncatedBuffers() {
        let valid = [UInt8](repeating: 255, count: 24)
        let short = Array(valid.dropLast())
        #expect(throws: FrameAnalyzerError.insufficientBytes) {
            try FrameAnalyzer.analyzeRGBA(short, width: 2, height: 2, bytesPerRow: 12)
        }
        for (lhs, rhs) in [(short, valid), (valid, short)] {
            #expect(throws: FrameAnalyzerError.insufficientBytes) {
                try FrameAnalyzer.meanAbsoluteDifferenceRGBA(
                    lhs, rhs, width: 2, height: 2, bytesPerRow: 12
                )
            }
            #expect(throws: FrameAnalyzerError.insufficientBytes) {
                try FrameAnalyzer.meanAbsoluteDifferenceRGBA(
                    lhs, rhs, width: 2, height: 2, bytesPerRow: 12, region: fullRegion
                )
            }
        }
    }

    @Test("Row padding does not become image content and RGB comparisons ignore alpha")
    func paddedRowsRetainPixelSemantics() throws {
        let compact: [UInt8] = [
            0, 30, 90, 255, 255, 60, 120, 255,
            90, 120, 180, 255, 30, 150, 210, 255,
        ]
        let padded = Array(compact[..<8]) + [1, 2, 3, 4]
            + Array(compact[8...]) + [5, 6, 7, 8]
        let compactMetrics = try FrameAnalyzer.analyzeRGBA(
            compact, width: 2, height: 2, bytesPerRow: 8
        )
        let paddedMetrics = try FrameAnalyzer.analyzeRGBA(
            padded, width: 2, height: 2, bytesPerRow: 12
        )
        #expect(compactMetrics == paddedMetrics)
        #expect(paddedMetrics.sampledPixels == 4)

        var changed = padded
        for index in [3, 7, 8, 9, 10, 11, 15, 19, 20, 21, 22, 23] {
            changed[index] = 0
        }
        #expect(try FrameAnalyzer.meanAbsoluteDifferenceRGBA(
            padded, changed, width: 2, height: 2, bytesPerRow: 12
        ) == 0)
        #expect(try FrameAnalyzer.meanAbsoluteDifferenceRGBA(
            padded, changed, width: 2, height: 2, bytesPerRow: 12, region: fullRegion
        ) == 0)

        changed[18] = 255
        let expectedDifference = 45.0 / (4 * 3 * 255)
        #expect(try FrameAnalyzer.meanAbsoluteDifferenceRGBA(
            padded, changed, width: 2, height: 2, bytesPerRow: 12
        ) == expectedDifference)
        #expect(try FrameAnalyzer.meanAbsoluteDifferenceRGBA(
            padded, changed, width: 2, height: 2, bytesPerRow: 12, region: fullRegion
        ) == expectedDifference)
        #expect(try FrameAnalyzer.meanAbsoluteDifferenceRGBA(
            padded, changed, width: 2, height: 2, bytesPerRow: 12,
            region: .init(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        ) == 45.0 / (3 * 255))
    }

    @Test("Invalid crops fail before pixel conversion", arguments: [Double.nan, .infinity, -0.1, 0.5])
    func rejectsInvalidCrops(crop: Double) {
        #expect(throws: FrameAnalyzerError.invalidCropFraction) {
            try FrameAnalyzer.analyzeRGBA(
                [0, 0, 0, 255], width: 1, height: 1, bytesPerRow: 4, cropFraction: crop
            )
        }
    }

    private let fullRegion = NormalizedRect(x: 0, y: 0, width: 1, height: 1)
}
