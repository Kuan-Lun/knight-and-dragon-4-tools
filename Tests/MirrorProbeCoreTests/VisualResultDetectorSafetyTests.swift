import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import MirrorProbeCore

@Suite("Visual result detector rejects obscured or unrelated pixels")
struct VisualResultDetectorSafetyTests {
    @Test("The untouched captured result has visual evidence and the calibrated upper target")
    func baselineRemainsActionable() throws {
        let frame = try capturedResult()
        let classification = try classify(frame)
        #expect(classification.state == .missionCompleteRepeatSelected)
        #expect(MissionSuccessPageIdentity.resolve(in: classification) == .loot)
        #expect(classification.evidence.allSatisfy { $0.observation == nil })
        #expect(VisualResultEvidence.hasConsistentVisualEvidence(in: classification))
        #expect(classification.allowedActions.map(\.name) == [.advanceMissionComplete])
        #expect(classification.allowedActions.first?.target.rect
                == MissionResultTopActionResolver.measuredTopAdvanceRect)
    }

    @Test("A dimmed result under an overlay cannot pass brightness-invariant correlation alone",
          arguments: [0.85, 0.65, 0.35])
    func dimmedBackgroundIsRejected(factor: Double) throws {
        var frame = try capturedResult()
        for offset in stride(from: 0, to: frame.bytes.count, by: 4) {
            for channel in 0..<3 {
                frame.bytes[offset + channel] = UInt8(Double(frame.bytes[offset + channel]) * factor)
            }
        }
        assertNoResultAction(try classify(frame))
    }

    @Test("Flat white, black, and transparent images provide no result authorization")
    func flatAndTransparentFramesAreRejected() throws {
        let original = try capturedResult()
        for luminance: UInt8 in [0, 255] {
            var flat = original
            for offset in stride(from: 0, to: flat.bytes.count, by: 4) {
                flat.bytes[offset] = luminance
                flat.bytes[offset + 1] = luminance
                flat.bytes[offset + 2] = luminance
                flat.bytes[offset + 3] = 255
            }
            assertNoResultAction(try classify(flat))
        }
        var transparent = original
        for offset in stride(from: 3, to: transparent.bytes.count, by: 4) {
            transparent.bytes[offset] = 0
        }
        assertNoResultAction(try classify(transparent))
    }

    @Test("Covering any required result anchor removes all result actions",
          arguments: [VisualResultMarker.successTitle, .lootHeader, .repeatOption])
    func occludedMarkerCannotBorrowOtherScaffold(marker: VisualResultMarker) throws {
        var frame = try capturedResult()
        fill(&frame, region: VisualResultMatch.region(for: marker), red: 0, green: 0, blue: 0)
        assertNoResultAction(try classify(frame))
    }

    @Test("Transparent marker pixels cannot authorize a result even when stored RGB still matches",
          arguments: [VisualResultMarker.successTitle, .lootHeader, .repeatOption])
    func markerAlphaIsRequired(marker: VisualResultMarker) throws {
        var frame = try capturedResult()
        let region = VisualResultMatch.region(for: marker)
        for y in pixelRange(region.y, region.height, limit: frame.height) {
            for x in pixelRange(region.x, region.width, limit: frame.width) {
                frame.bytes[y * frame.bytesPerRow + x * 4 + 3] = 0
            }
        }
        assertNoResultAction(try classify(frame))
    }

    @Test("Changing the clock and dynamic result body leaves fixed result evidence unchanged")
    func dynamicRegionsAreExcluded() throws {
        var frame = try capturedResult()
        let original = try classify(frame)
        fill(&frame, region: .init(x: 0.1, y: 0.045, width: 0.8, height: 0.045),
             red: 20, green: 80, blue: 170)
        fill(&frame, region: .init(x: 0, y: 0.30, width: 1, height: 0.70),
             red: 100, green: 150, blue: 180)
        let changed = try classify(frame)
        #expect(changed == original)
    }

    @Test("A supplied measured modal vetoes a matching result before any result action is created",
          arguments: [WideModalLayout.oneButton, .twoButtons, .unsupportedButtonCount])
    func modalHasPriority(layout: WideModalLayout) throws {
        let frame = try capturedResult()
        let result = try VisualResultDetector.detectRGBA(
            frame.bytes, width: frame.width, height: frame.height, bytesPerRow: frame.bytesPerRow,
            modalDetection: .init(buttons: [], layout: layout, dialogRect: nil)
        )
        #expect(!result.isResultCandidate)
        assertNoResultAction(result.classification)
        #expect(result.classification.evidence.first?.detail.contains("modalPresent") == true)
    }

    @Test("Changing the aspect ratio or using a thumbnail cannot authorize calibrated coordinates")
    func unsupportedGeometryIsRejected() throws {
        for (width, height) in [(600, 600), (199, 436), (812, 1600)] {
            let frame = Frame(bytes: [UInt8](repeating: 255, count: width * height * 4),
                              width: width, height: height)
            assertNoResultAction(try classify(frame))
        }
    }

    @Test("Malformed dimensions and truncated buffers fail before sampling")
    func malformedBuffersThrow() throws {
        let dimensions: [(Int, Int, Int)] = [
            (0, 890, 0), (406, 0, 1624), (-1, 890, 1624), (1, 1, 4),
            (10_001, 890, 40_004), (406, 10_001, 1624),
            (10_000, 10_000, 40_000), (406, 890, 1623), (406, 890, Int.max),
        ]
        for (width, height, stride) in dimensions {
            #expect(throws: VisualResultDetectorError.invalidDimensions) {
                try VisualResultDetector.classifyRGBA([], width: width, height: height, bytesPerRow: stride)
            }
        }
        #expect(throws: VisualResultDetectorError.insufficientBytes) {
            try VisualResultDetector.classifyRGBA([0], width: 406, height: 890, bytesPerRow: 1624)
        }
    }

    private func assertNoResultAction(_ classification: GameStateClassification) {
        #expect(classification.state == .unknown)
        #expect(classification.allowedActions.isEmpty)
        #expect(classification.policyGatedActions.isEmpty)
    }

    private func classify(_ frame: Frame) throws -> GameStateClassification {
        try VisualResultDetector.classifyRGBA(frame.bytes, width: frame.width,
                                              height: frame.height, bytesPerRow: frame.bytesPerRow)
    }

    private func capturedResult() throws -> Frame {
        let url = try #require(Bundle.module.url(forResource: "low-result-title-loot-final", withExtension: "png"))
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var frame = Frame(bytes: [UInt8](repeating: 0, count: image.width * image.height * 4),
                          width: image.width, height: image.height)
        let width = frame.width, height = frame.height, bytesPerRow = frame.bytesPerRow
        let rendered = frame.bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        #expect(rendered)
        return frame
    }

    private func fill(_ frame: inout Frame, region: NormalizedRect,
                      red: UInt8, green: UInt8, blue: UInt8) {
        for y in pixelRange(region.y, region.height, limit: frame.height) {
            for x in pixelRange(region.x, region.width, limit: frame.width) {
                let offset = y * frame.bytesPerRow + x * 4
                frame.bytes[offset] = red
                frame.bytes[offset + 1] = green
                frame.bytes[offset + 2] = blue
                frame.bytes[offset + 3] = 255
            }
        }
    }

    private func pixelRange(_ start: Double, _ length: Double, limit: Int) -> Range<Int> {
        max(0, Int(floor(start * Double(limit))))..<min(limit, Int(ceil((start + length) * Double(limit))))
    }

    private struct Frame {
        var bytes: [UInt8]
        let width: Int
        let height: Int
        var bytesPerRow: Int { width * 4 }
    }
}
