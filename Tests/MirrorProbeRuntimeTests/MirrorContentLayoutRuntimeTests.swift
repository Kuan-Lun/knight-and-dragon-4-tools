import CoreGraphics
import CryptoKit
import Foundation
import Testing
@testable import MirrorProbeCore
@testable import MirrorProbeRuntime

@Suite("Zoomed mirror windows: canvas recognition and click mapping")
struct MirrorContentLayoutRuntimeTests {
    @Test("A click on a canvas target lands on the same content pixel of the zoomed window")
    func clickPointMapsThroughTheLayout() throws {
        let window = CGRect(x: 5, y: 30, width: 211, height: 468)
        let bytes = syntheticCapture(width: 211, height: 468)
        let layout = try #require(MirrorContentLayout.detect(
            bytes, width: 211, height: 468, bytesPerRow: 211 * 4
        ))
        // Canvas content origin (4, 19) of 204x445 -> captured content origin (7, 38).
        let origin = MirrorProbeRuntime.automationClickPoint(
            canvasPoint: NormalizedPoint(x: 4.0 / 204.0, y: 19.0 / 445.0),
            layout: layout, windowFrame: window
        )
        #expect(abs(origin.x - (5 + 7)) < 1e-9)
        #expect(abs(origin.y - (30 + 38)) < 1e-9)
        // Canvas content far corner -> captured content far corner.
        let corner = MirrorProbeRuntime.automationClickPoint(
            canvasPoint: NormalizedPoint(x: (4.0 + 197.0) / 204.0, y: (19.0 + 422.0) / 445.0),
            layout: layout, windowFrame: window
        )
        #expect(abs(corner.x - (5 + 7 + 197)) < 1e-9)
        #expect(abs(corner.y - (30 + 38 + 422)) < 1e-9)
        // The identity layout (reference size or undetected border) keeps the plain mapping.
        let identity = MirrorContentLayout.identity(width: 406, height: 890)
        let plain = MirrorProbeRuntime.automationClickPoint(
            canvasPoint: NormalizedPoint(x: 0.25, y: 0.5), layout: identity,
            windowFrame: CGRect(x: 100, y: 200, width: 406, height: 890)
        )
        #expect(plain == CGPoint(x: 100 + 406 * 0.25, y: 200 + 890 * 0.5))
    }

    @Test("A Retina window maps canvas points in window points, not backing pixels")
    func retinaWindowMapsInPoints() throws {
        let window = CGRect(x: 0, y: 0, width: 406, height: 890)
        let bytes = syntheticCapture(width: 812, height: 1780, top: 76, bottom: 16, side: 15)
        let layout = try #require(MirrorContentLayout.detect(
            bytes, width: 812, height: 1780, bytesPerRow: 812 * 4
        ))
        #expect(layout.canvasWidth == 810 && layout.canvasContent.x == 14)
        let origin = MirrorProbeRuntime.automationClickPoint(
            canvasPoint: NormalizedPoint(x: 14.0 / 810.0, y: 76.0 / 1780.0),
            layout: layout, windowFrame: window
        )
        #expect(abs(origin.x - 7.5) < 1e-9)
        #expect(abs(origin.y - 38) < 1e-9)
    }

    @Test("analyze-file places a zoomed capture on the canvas and reports the layout")
    func analyzeFileReportsLayout() async throws {
        let directory = try RuntimeTestDirectory()
        defer { directory.remove() }
        let input = try #require(Bundle.module.url(
            forResource: "zoom-loot-result-211x468", withExtension: "png"
        ))
        let output = directory.url.appendingPathComponent("analysis.json")
        try await MirrorProbeRuntime.run(arguments: [
            "analyze-file", "--input", input.path, "--report", output.path,
        ])
        let report = try JSONDecoder().decode(AnalysisReport.self, from: Data(contentsOf: output))
        #expect(report.schemaVersion == 3)
        #expect(report.image.width == 211 && report.image.height == 468)
        let layout = try #require(report.contentLayout)
        #expect(layout.detected)
        #expect(!layout.identity)
        #expect(layout.sourceContentX == 7 && layout.sourceContentY == 38)
        #expect(layout.contentWidth == 197 && layout.contentHeight == 422)
        #expect(layout.canvasWidth == 204 && layout.canvasHeight == 445)
        #expect(layout.canvasContentX == 4 && layout.canvasContentY == 19)
        #expect(report.status == "classified")
        #expect(report.classification.state == .missionCompleteRepeatSelected)
    }

    @Test("A reference-size capture reports an identity layout and unchanged pixels")
    func referenceSizeIsIdentity() throws {
        let bytes = syntheticCapture(width: 406, height: 890)
        let frame = RGBAFrame(bytes: bytes, width: 406, height: 890, bytesPerRow: 406 * 4)
        let normalized = try MirrorProbeRuntime.normalizedMirrorFrame(from: frame)
        #expect(normalized.layout.isIdentity)
        #expect(normalized.rgba.bytes == bytes)
        #expect(normalized.image.width == 406 && normalized.image.height == 890)
        // The same pixels produce the same canvas through a CGImage round trip.
        let viaImage = try MirrorProbeRuntime.normalizedMirrorFrame(from: normalized.image)
        #expect(viaImage.rgba.bytes == bytes)
    }

    @Test("A capture without a detectable border is recognized as captured")
    func undetectedBorderFallsBackToIdentity() throws {
        let bytes = syntheticCapture(width: 300, height: 600, top: 0, bottom: 0, side: 0)
        let frame = RGBAFrame(bytes: bytes, width: 300, height: 600, bytesPerRow: 300 * 4)
        let normalized = try MirrorProbeRuntime.normalizedMirrorFrame(from: frame)
        #expect(normalized.layout == .identity(width: 300, height: 600))
        #expect(normalized.rgba.width == 300 && normalized.rgba.height == 600)
    }

    private func syntheticCapture(
        width: Int, height: Int, top: Int = 38, bottom: Int = 8, side: Int = 7
    ) -> [UInt8] {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in top..<(height - bottom) {
            for x in side..<(width - side) {
                let offset = y * width * 4 + x * 4
                bytes[offset] = UInt8((x * 7 + y * 3) % 200)
                bytes[offset + 1] = UInt8((x * 5 + y * 11) % 200)
                bytes[offset + 2] = UInt8((x + y) % 200)
            }
        }
        return bytes
    }
}
