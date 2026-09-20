import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
@testable import MirrorProbeCore

/// Read-only battle captures at six iPhone Mirroring zoom levels (2026-09-20, 1x display), one
/// per auto-level cycle: the runner was stopped at its first battle observation, the window
/// zoomed, and one capture taken. The five smallest also calibrate the zoom footer templates;
/// 439x960 is held out and matches the reference templates alone.
@Suite("Battle footer recognition at mirroring zoom levels")
struct ZoomLevelBattleRegressionTests {
    private struct Frame {
        var bytes: [UInt8]
        let width: Int
        let height: Int
        var bytesPerRow: Int { width * 4 }
    }

    private static let captures: [(name: String, width: Int, height: Int, sha256: String)] = [
        ("zoom-battle-211x468", 211, 468,
         "9c80d178f382c0b695f8f0c9098e7c9d14d24d7c726541a0b25cbed87a3e4062"),
        ("zoom-battle-250x553", 250, 553,
         "d11a15c1332d82e86eef172f3a7330d730da2b89e79fbbfd33c0df5df151e40b"),
        ("zoom-battle-289x637", 289, 637,
         "14a8877c943e13f85333595df7afe94a72b73ddf5016739e002c81020aa21df9"),
        ("zoom-battle-328x722", 328, 722,
         "c593383157add0225be990163750c4a3fa3ffde22a83229cca59cb848fabe375"),
        ("zoom-battle-367x806", 367, 806,
         "d681c8aa7d311a6b487ebd331302f42fe4a163d81fbb231b33be27ae29a80ae9"),
        ("zoom-battle-439x960", 439, 960,
         "d74ef9689368dd011803ffd6a8524b090af49dda2c7cdc7b4519261f2bb759c1"),
    ]

    @Test("Every zoom level identifies the battle footer with a policy-gated retreat only",
          arguments: captures)
    func canvasRecognizesBattle(capture: (name: String, width: Int, height: Int, sha256: String)) throws {
        let frame = try fixture(capture.name, sha256: capture.sha256)
        #expect(frame.width == capture.width && frame.height == capture.height)
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
        #expect(classification.state == .battle)
        #expect(classification.allowedActions.isEmpty)
        #expect(VisualBattleEvidence.hasRunningBattleEvidence(in: classification))
        #expect(VisualBattleEvidence.hasTrustedRetreat(in: classification))
        let matches = classification.evidence.compactMap(VisualBattleEvidence.validatedMatch)
        for marker in [VisualBattleMarker.skipControl, .allAutoControl, .retreatControl] {
            let match = try #require(matches.first { $0.marker == marker })
            #expect(match.similarity >= VisualBattleMatch.minimumSimilarity)
        }
        #expect(classification.policyGatedActions.count == 1)
        let retreat = try #require(classification.policyGatedActions.first)
        #expect(retreat.name == .openBattleRetreatConfirmation)
        #expect(retreat.target.rect == VisualBattleEvidence.measuredRetreatRect)
        // Mapped back to the capture, the retreat center stays on the proportionally scaled
        // control: 0.8825 x 0.667 of the reference content, inside the fixed border.
        let source = layout.sourceNormalizedPoint(forCanvas: retreat.target.point)
        let x = source.x * Double(frame.width), y = source.y * Double(frame.height)
        let expectedX = 7 + (retreat.target.point.x * 406 - 7) * layout.scaleX
        let expectedY = 38 + (retreat.target.point.y * 890 - 38) * layout.scaleY
        #expect(abs(x - expectedX) <= 1)
        #expect(abs(y - expectedY) <= 1)
    }

    /// Larger levels sit within the registration search of the reference regions, so only
    /// the three smallest demonstrate that the canvas, not a template, is what recognizes them.
    @Test("Without the canvas, the smallest zoomed battle captures stay unknown",
          arguments: Array(captures.prefix(3)))
    func rawFramesAreUnknown(capture: (name: String, width: Int, height: Int, sha256: String)) throws {
        let frame = try fixture(capture.name, sha256: capture.sha256)
        let classification = try AutoLevelVisualClassifier.classifyRGBA(
            frame.bytes, width: frame.width, height: frame.height, bytesPerRow: frame.bytesPerRow
        )
        #expect(classification.state == .unknown)
        #expect(classification.allowedActions.isEmpty)
    }

    private func fixture(_ name: String, sha256: String) throws -> Frame {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "png"))
        let data = try Data(contentsOf: url)
        #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == sha256)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
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
}
