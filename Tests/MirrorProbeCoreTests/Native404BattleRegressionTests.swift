import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
@testable import MirrorProbeCore

@Suite("Native 404x874 battle and modal recognition regression")
struct Native404BattleRegressionTests {
    // Original read-only live captures from the startup-failure investigation.
    private let battleSHA256 = "eb49a7ab620b134b3867eec9ad45810bd21e34a6de39d816e1c5431848045097"
    private let modalSHA256 = "40de45701dac83228984b0cef2fa607611f7a45747aa2b08fd5d3eed968252ff"
    private let identity = AutoLevelWindowIdentity(processID: 91507, windowID: 65194)

    @Test("The original battle has trusted footer and retreat pixels without direct input authorization")
    func originalBattlePreservesTemporalRetreatGate() throws {
        let frame = try battleFixture()
        let classification = try classify(frame)
        #expect(classification.state == .battle)
        #expect(classification.allowedActions.isEmpty)
        #expect(classification.evidence.allSatisfy { $0.observation == nil })
        #expect(VisualBattleEvidence.hasConsistentVisualEvidence(in: classification))
        #expect(VisualBattleEvidence.hasRunningBattleEvidence(in: classification))
        #expect(VisualBattleEvidence.hasTrustedRetreat(in: classification))
        let matches = classification.evidence.compactMap(VisualBattleEvidence.validatedMatch)
        for marker in [VisualBattleMarker.skipControl, .allAutoControl, .retreatControl] {
            let match = try #require(matches.first { $0.marker == marker })
            #expect(match.similarity >= VisualBattleMatch.minimumSimilarity)
        }
        // Pause is diagnostic only; transient combat effects need not supply that glyph.
        #expect(classification.policyGatedActions.count == 1)
        let retreat = try #require(classification.policyGatedActions.first)
        #expect(retreat.name == .openBattleRetreatConfirmation)
        #expect(retreat.requirement == .temporalDefeatRecovery)
        #expect(retreat.target.sourceText == VisualBattleEvidence.measuredRetreatSentinel)
        #expect((320.0...392.0).contains(retreat.target.point.x * Double(frame.width)))
        #expect((573.0...596.0).contains(retreat.target.point.y * Double(frame.height)))

        var controller = makeController()
        // These are explicitly simulated observation times for the same captured pixels.
        // No temporal stall proof or actual input is supplied by a single screenshot.
        for time in [1.0, 16.0, 31.0] {
            let observation = snapshot(classification, at: time, fingerprint: battleSHA256)
            #expect(observation.actionCandidates.map(\.intent) == [.requestRetreat])
            #expect(controller.consume(observation) == .wait(.battleInProgress))
        }
        #expect(controller.actionsIssued == 0)
        #expect(controller.completedCycles == 0)
        #expect(controller.pendingActionAcknowledgementDeadline == nil)
    }

    @Test("Covering a required skip, all-auto, or retreat glyph rejects the unified battle path",
          arguments: [VisualBattleMarker.skipControl, .allAutoControl, .retreatControl])
    func missingRequiredGlyphCannotAuthorizeBattleAction(marker: VisualBattleMarker) throws {
        var frame = try battleFixture()
        // Independent pixel bounds measured on the 404x874 original, including each
        // control's glyph and small surrounding margin. Other required glyphs remain intact.
        let bounds: (x: Range<Int>, y: Range<Int>)
        switch marker {
        case .skipControl: bounds = (28..<69, 756..<783)
        case .allAutoControl: bounds = (88..<151, 756..<783)
        case .retreatControl: bounds = (336..<376, 571..<596)
        case .pauseControl: throw FixtureError.unexpectedMarker
        }
        for y in bounds.y {
            for x in bounds.x {
                let offset = y * frame.bytesPerRow + x * 4
                frame.bytes[offset] = 0
                frame.bytes[offset + 1] = 0
                frame.bytes[offset + 2] = 0
                frame.bytes[offset + 3] = 255
            }
        }
        let classification = try classify(frame)
        #expect(classification.state == .unknown)
        #expect(classification.allowedActions.isEmpty)
        #expect(classification.policyGatedActions.isEmpty)
        #expect(!VisualBattleEvidence.hasRunningBattleEvidence(in: classification))
        #expect(!VisualBattleEvidence.hasTrustedRetreat(in: classification))
        let observation = snapshot(classification, at: 1, fingerprint: "synthetic-covered-\(marker)")
        #expect(observation.actionCandidates.isEmpty)
        var controller = makeController()
        #expect(controller.consume(observation)
            == .wait(.transientState(kind: .unknown, observationCount: 1)))
        #expect(controller.actionsIssued == 0)
    }

    @Test("The actual subsequent modal vetoes battle and exposes only its measured close button")
    func actualModalTakesPriorityOverBattleUnderlay() throws {
        let frame = try fixture("visual-battle-modal-404x874", sha256: modalSHA256)
        let battle = try VisualBattleDetector.classifyRGBA(
            frame.bytes, width: frame.width, height: frame.height, bytesPerRow: frame.bytesPerRow
        )
        #expect(battle.state == .unknown)
        #expect(battle.allowedActions.isEmpty)
        #expect(battle.policyGatedActions.isEmpty)
        #expect(!VisualBattleEvidence.hasTrustedRetreat(in: battle))
        #expect(battle.evidence.contains { $0.detail.contains("modalPresent") })

        let modal = try WideModalButtonDetector.detectRGBA(
            frame.bytes, width: frame.width, height: frame.height, bytesPerRow: frame.bytesPerRow
        )
        #expect(modal.layout == .oneButton)
        #expect(modal.buttons.count == 1)
        let classification = try classify(frame)
        #expect(classification.state == .wideModalOneButton)
        #expect(classification.allowedActions.map(\.name) == [.pressWideModalTopButton])
        #expect(classification.policyGatedActions.isEmpty)
        #expect(classification.evidence.allSatisfy { $0.observation == nil })
        #expect(!VisualBattleEvidence.hasTrustedRetreat(in: classification))
        let close = try #require(classification.allowedActions.first)
        #expect(close.target.rect == modal.buttons.first?.rect)
        // The captured modal's close row spans approximately x=44...361, y=469...505.
        #expect((44.0...361.0).contains(close.target.point.x * Double(frame.width)))
        #expect((469.0...505.0).contains(close.target.point.y * Double(frame.height)))
        let observation = snapshot(classification, at: 1, fingerprint: modalSHA256)
        #expect(observation.actionCandidates.map(\.intent) == [.pressWideModalTopButton])
        #expect(!observation.actionCandidates.contains { $0.intent == .requestRetreat })
    }

    private func makeController() -> AutoLevelController {
        .init(session: .init(sessionID: "native-404-battle", startedAt: 0, windowIdentity: identity),
              policy: .init(postActionTimeout: 12))
    }

    private func snapshot(_ classification: GameStateClassification, at time: TimeInterval,
                          fingerprint: String) -> AutoLevelSnapshot {
        .init(classification: classification,
              runtime: .init(observedAt: time, windowIdentity: identity, frameFingerprint: fingerprint,
                             battleSessionID: "native-404-battle", allAutoStatus: .active,
                             battleStatus: .inProgress))
    }

    private func classify(_ frame: Frame) throws -> GameStateClassification {
        try AutoLevelVisualClassifier.classifyRGBA(
            frame.bytes, width: frame.width, height: frame.height, bytesPerRow: frame.bytesPerRow
        )
    }

    private func battleFixture() throws -> Frame {
        try fixture("visual-battle-404x874", sha256: battleSHA256)
    }

    private func fixture(_ name: String, sha256: String) throws -> Frame {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "png"))
        let data = try Data(contentsOf: url)
        #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == sha256)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 404 && image.height == 874)
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
        guard rendered else { throw FixtureError.cannotRender }
        return frame
    }

    private struct Frame {
        var bytes: [UInt8]
        let width: Int
        let height: Int
        var bytesPerRow: Int { width * 4 }
    }

    private enum FixtureError: Error { case cannotRender, unexpectedMarker }
}
