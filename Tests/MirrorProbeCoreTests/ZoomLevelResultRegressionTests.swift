import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
@testable import MirrorProbeCore

/// Read-only captures of one loot result page at every iPhone Mirroring zoom level on a 1x
/// display (顯示方式 > 縮小 through 放大), taken on 2026-09-20 with the window at the top-left of
/// the screen. Only 406x890 is proportional to the calibrated regions; the others keep the
/// fixed-point border and must be placed on the reference canvas before recognition.
@Suite("Loot result recognition at every mirroring zoom level")
struct ZoomLevelResultRegressionTests {
    private static let captures: [(name: String, width: Int, height: Int, sha256: String)] = [
        ("zoom-loot-result-211x468", 211, 468,
         "a4967f96a47bb65db6417ea4e69f879892c970b9899f8b38b9abf6f4eb84217c"),
        ("zoom-loot-result-250x553", 250, 553,
         "cb2dc55400148743d7b3014c7f46e20bd91eeb5ec5f884ed9749b3c1bcdbc6b3"),
        ("zoom-loot-result-289x637", 289, 637,
         "064a1adc3991678ee5ed1f89dd9c05374229599ddb64bcd3b13a77f378eb2c4a"),
        ("zoom-loot-result-328x722", 328, 722,
         "d36a5a4abb835b588d78f338478e582bc157a92dcd2e2e6e38027c5082535e7e"),
        ("zoom-loot-result-367x806", 367, 806,
         "c20e1ce669fbff846881434058a265db46d9c47a1c1b61ad916c699fa12bcacd"),
        ("zoom-loot-result-406x890", 406, 890,
         "cb5d3d872c27b8e7504a70dae9009f0844f24255be4b5331ceff576e6197642c"),
        ("zoom-loot-result-439x960", 439, 960,
         "3c88379c20c35d71344f02785004b867c1083a9b4ce6c5add36fb247906a234f"),
    ]

    /// The experience result page at every level, captured while the runner sat on it at
    /// 211x468 with `experienceHeader` at 0.844 before its zoom samples existed.
    private static let experienceCaptures: [(name: String, width: Int, height: Int, sha256: String)] = [
        ("zoom-experience-result-211x468", 211, 468,
         "9b8024f9db01168b9e2904dee71a1ab6107f6066211e14ff15672c114be139fa"),
        ("zoom-experience-result-250x553", 250, 553,
         "e98f0b6c4657f4a282cc6d56898778f5f1b835aec91c6a436058b49a64996044"),
        ("zoom-experience-result-289x637", 289, 637,
         "b781d44f97c0439a6ab479326503722f3088c6f9e4c0b2bf97f9ddf412f736d9"),
        ("zoom-experience-result-328x722", 328, 722,
         "4d3c55b9fd73fd75ec7872a080a539e7baddb7e147a2b28f4e73f174a6a71496"),
        ("zoom-experience-result-367x806", 367, 806,
         "40a2c6683ea3d2234f4ba992945270bc3223749eee7c356e50aa842117aa0ae5"),
        ("zoom-experience-result-406x890", 406, 890,
         "bfb82d01944203694fc0d9a5479efbe8e3b49b8dc83bc13312e38dde73dbd832"),
        ("zoom-experience-result-439x960", 439, 960,
         "70ff6bbae7de9797b1953404b21dc572a3d64894954794f4294304ad3719f39c"),
    ]

    @Test("Every zoom level recognizes the selected-repeat loot page on the reference canvas",
          arguments: captures)
    func canvasRecognizesLootPage(capture: (name: String, width: Int, height: Int, sha256: String)) throws {
        try canvasRecognizesResultPage(capture: capture, pageMarker: .lootHeader)
    }

    @Test("Every zoom level recognizes the selected-repeat experience page on the reference canvas",
          arguments: experienceCaptures)
    func canvasRecognizesExperiencePage(capture: (name: String, width: Int, height: Int, sha256: String)) throws {
        try canvasRecognizesResultPage(capture: capture, pageMarker: .experienceHeader)
    }

    private func canvasRecognizesResultPage(
        capture: (name: String, width: Int, height: Int, sha256: String), pageMarker: VisualResultMarker
    ) throws {
        let frame = try fixture(capture.name, sha256: capture.sha256)
        #expect(frame.width == capture.width && frame.height == capture.height)
        let layout = try #require(MirrorContentLayout.detect(
            frame.bytes, width: frame.width, height: frame.height, bytesPerRow: frame.bytesPerRow
        ))
        #expect(layout.sourceContent.x == 7 && layout.sourceContent.y == 38)
        #expect(layout.isIdentity == (capture.width == 406))
        let canvas = try #require(layout.canvasRGBA(
            frame.bytes, width: frame.width, height: frame.height, bytesPerRow: frame.bytesPerRow
        ))
        let classification = try AutoLevelVisualClassifier.classifyRGBA(
            canvas, width: layout.canvasWidth, height: layout.canvasHeight,
            bytesPerRow: layout.canvasWidth * 4
        )
        #expect(classification.state == .missionCompleteRepeatSelected)
        #expect(classification.allowedActions.map(\.name) == [.advanceMissionComplete])
        for marker in [VisualResultMarker.successTitle, pageMarker, .repeatOption] {
            let match = try #require(classification.evidence.compactMap(\.visualMatch)
                .first { $0.marker == marker })
            #expect(match.similarity >= VisualResultMatch.minimumSimilarity)
        }
        // The advance target is canvas-normalized; mapped back it lands inside the captured
        // phone content rather than on the window border.
        let target = try #require(classification.allowedActions.first?.target)
        let source = layout.sourceNormalizedPoint(forCanvas: target.point)
        let sourceX = source.x * Double(frame.width), sourceY = source.y * Double(frame.height)
        #expect(sourceX > Double(layout.sourceContent.x))
        #expect(sourceX < Double(layout.sourceContent.x + layout.sourceContent.width))
        #expect(sourceY > Double(layout.sourceContent.y))
        #expect(sourceY < Double(layout.sourceContent.y + layout.sourceContent.height))
    }

    @Test("Without the canvas, only the reference size recognizes the page", arguments: captures)
    func rawFramesRequireTheCanvas(capture: (name: String, width: Int, height: Int, sha256: String)) throws {
        let frame = try fixture(capture.name, sha256: capture.sha256)
        let classification = try AutoLevelVisualClassifier.classifyRGBA(
            frame.bytes, width: frame.width, height: frame.height, bytesPerRow: frame.bytesPerRow
        )
        if capture.width == 406 {
            #expect(classification.state == .missionCompleteRepeatSelected)
        } else {
            #expect(classification.state == .unknown)
            #expect(classification.allowedActions.isEmpty)
        }
    }

    private func fixture(_ name: String, sha256: String) throws -> RGBAFixtureFrame {
        try loadRGBAFixture(name, sha256: sha256)
    }
}
