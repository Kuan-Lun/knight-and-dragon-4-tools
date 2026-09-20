import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
@testable import MirrorProbeCore

/// Read-only captures of one single-button battle dialog at the smallest, a middle and the
/// largest iPhone Mirroring zoom level (2026-09-20, 1x display). The dialog detector works from
/// frame proportions, so it only needs the reference canvas to see the same proportions.
@Suite("Battle dialog recognition at mirroring zoom levels")
struct ZoomLevelModalRegressionTests {
    private static let captures: [(name: String, width: Int, height: Int, sha256: String)] = [
        ("zoom-battle-modal-211x468", 211, 468,
         "8e714641f20bb926e346b61b5156b6aee682c06f6253b6b4555c1397a666aba8"),
        ("zoom-battle-modal-328x722", 328, 722,
         "09293aca61d252ecf03eba79364c456878caba2ac75f768e623d1c5d6c0b6eec"),
        ("zoom-battle-modal-439x960", 439, 960,
         "c8dc4d117f0031f12df80572847fb784579ce73e06612b4cce5dc07dbd082572"),
    ]

    @Test("The single dialog button is found at the same canvas position at every zoom level",
          arguments: captures)
    func canvasFindsDialogButton(capture: (name: String, width: Int, height: Int, sha256: String)) throws {
        let frame = try fixture(capture.name, sha256: capture.sha256)
        let layout = try #require(MirrorContentLayout.detect(
            frame.bytes, width: frame.width, height: frame.height, bytesPerRow: frame.bytesPerRow
        ))
        let canvas = try #require(layout.canvasRGBA(
            frame.bytes, width: frame.width, height: frame.height, bytesPerRow: frame.bytesPerRow
        ))
        let classification = try AutoLevelVisualClassifier.classifyRGBA(
            canvas, width: layout.canvasWidth, height: layout.canvasHeight,
            bytesPerRow: layout.canvasWidth * 4
        )
        #expect(classification.state == .wideModalOneButton)
        let action = try #require(classification.allowedActions.first)
        #expect(classification.allowedActions.count == 1)
        #expect(action.name == .pressWideModalTopButton)
        // Measured on the 406x890 reference: the button center sits at x 0.4995, y 0.557.
        #expect(abs(action.target.point.x - 0.4995) < 0.003)
        #expect(abs(action.target.point.y - 0.557) < 0.003)
        // Mapped back, the click lands inside the captured phone content.
        let source = layout.sourceNormalizedPoint(forCanvas: action.target.point)
        let x = source.x * Double(frame.width), y = source.y * Double(frame.height)
        #expect(x > 7 && x < Double(frame.width - 7))
        #expect(y > 38 && y < Double(frame.height - 8))
    }

    private func fixture(_ name: String, sha256: String) throws -> RGBAFixtureFrame {
        try loadRGBAFixture(name, sha256: sha256)
    }
}
