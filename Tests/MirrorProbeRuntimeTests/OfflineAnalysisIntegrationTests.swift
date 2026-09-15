import CryptoKit
import Foundation
import Testing
@testable import MirrorProbeRuntime

@Suite("Production offline PNG analysis integration")
struct OfflineAnalysisIntegrationTests {
    @Test("Real command dispatch loads captured pixels, classifies them and persists its report")
    func capturedBattle() async throws {
        let directory = try RuntimeTestDirectory()
        defer { directory.remove() }
        let input = try #require(Bundle.module.url(forResource: "visual-battle-low-auto", withExtension: "png"))
        let output = directory.url.appendingPathComponent("reports/analysis.json")
        let original = try Data(contentsOf: input)

        try await MirrorProbeRuntime.run(arguments: [
            "analyze-file", "--input", input.path, "--report", output.path,
        ])

        let report = try JSONDecoder().decode(AnalysisReport.self, from: Data(contentsOf: output))
        #expect(report.command == "analyze-file")
        #expect(report.status == "classified")
        #expect(report.classification.state == .battle)
        #expect(report.classification.allowedActions.isEmpty)
        #expect(report.image.width == 406)
        #expect(report.image.height == 890)
        #expect(report.image.pngSHA256 == SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined())
        #expect(report.source.kind == "file")
        #expect(report.source.path == input.path)
        #expect(report.source.window == nil)
        #expect(report.recognitionMode == "visualRegions")
        #expect(report.ocr.engine == "none")
        #expect(report.ocr.observations.isEmpty)
        #expect(report.safety.readOnly)
        #expect(report.safety.inputEventsPosted == 0)
        #expect(report.safety.actionAuthorization == "none")
        #expect(try Data(contentsOf: input) == original)
    }

    @Test("A blank PNG is persisted as rejected with no permitted action")
    func blankImage() async throws {
        let directory = try RuntimeTestDirectory()
        defer { directory.remove() }
        let input = directory.url.appendingPathComponent("blank.png")
        let output = directory.url.appendingPathComponent("analysis.json")
        try MirrorProbeRuntime.writePNG(runtimeTestImage(), to: input)

        try await MirrorProbeRuntime.run(arguments: [
            "analyze-file", "--input", input.path, "--report", output.path,
        ])

        let report = try JSONDecoder().decode(AnalysisReport.self, from: Data(contentsOf: output))
        #expect(report.status == "rejected")
        #expect(report.frameMetrics.isBlank)
        #expect(report.classification.state == .unknown)
        #expect(report.classification.allowedActions.isEmpty)
        #expect(report.classification.policyGatedActions.isEmpty)
        #expect(report.safety.inputEventsPosted == 0)
    }

    @Test("Invalid input produces no successful report and propagates an image-load error")
    func invalidPNG() async throws {
        let directory = try RuntimeTestDirectory()
        defer { directory.remove() }
        let input = directory.url.appendingPathComponent("invalid.png")
        let output = directory.url.appendingPathComponent("analysis.json")
        try Data("not an image".utf8).write(to: input)

        await #expect(throws: ProbeError.self) {
            try await MirrorProbeRuntime.run(arguments: [
                "analyze-file", "--input", input.path, "--report", output.path,
            ])
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test("An output alias cannot overwrite the input PNG")
    func inputOutputCollision() async throws {
        let directory = try RuntimeTestDirectory()
        defer { directory.remove() }
        let input = directory.url.appendingPathComponent("input.png")
        try MirrorProbeRuntime.writePNG(runtimeTestImage(), to: input)
        let original = try Data(contentsOf: input)
        let alias = directory.url.path + "/./input.png"
        await #expect(throws: ProbeError.self) {
            try await MirrorProbeRuntime.run(arguments: [
                "analyze-file", "--input", input.path, "--report", alias,
            ])
        }
        #expect(try Data(contentsOf: input) == original)
    }

    @Test("The production loader rejects symbolic links instead of following them")
    func symbolicLinkInput() throws {
        let directory = try RuntimeTestDirectory()
        defer { directory.remove() }
        let input = directory.url.appendingPathComponent("input.png")
        let link = directory.url.appendingPathComponent("link.png")
        try MirrorProbeRuntime.writePNG(runtimeTestImage(), to: input)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: input)
        #expect(throws: ProbeError.self) { try MirrorProbeRuntime.loadPNG(at: link) }
    }
}
