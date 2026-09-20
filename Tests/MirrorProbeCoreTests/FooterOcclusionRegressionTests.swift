import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
@testable import MirrorProbeCore

@Suite("Battle footer recognition failure from 2026-09-19")
struct FooterOcclusionRegressionTests {
    @Test("Every retained original has limited recovery evidence without classifying it as battle")
    func originalIncidentSequence() throws {
        let frames = try manifest().sequence
        #expect(frames.map(\.captureSequence) == Array(4656...4663))
        #expect(frames.allSatisfy { $0.originalState == .unknown })
        #expect(Set(frames.map(\.pngSHA256)).count == 5)

        for fixture in frames {
            let classification = try classify(load(fixture))
            #expect(classification.state == .unknown)
            #expect(VisualBattleEvidence.hasRecoverableFooterOcclusion(in: classification))
            #expect(classification.allowedActions.isEmpty)
            #expect(classification.policyGatedActions.isEmpty)
            #expect(!VisualBattleEvidence.hasRunningBattleEvidence(in: classification))
            #expect(!VisualBattleEvidence.hasTrustedRetreat(in: classification))
        }
    }

    @Test("Retained incident frames wait beyond the old grace, then a continued occlusion retreats")
    func incidentRecoveryThroughController() throws {
        let frames = try manifest().sequence
        let first = try #require(frames.first)
        let final = try #require(frames.last)
        let identity = AutoLevelWindowIdentity(processID: 1624, windowID: 102)
        let context = BattleWindowContext(
            processID: 1624, windowID: 102, originX: 5, originY: 30, width: 400, height: 878
        )
        let began = first.capturedAtElapsedSeconds
        var controller = AutoLevelController(
            session: .init(sessionID: "footer-incident-replay", startedAt: began - 2, windowIdentity: identity),
            policy: .init(uncertainStateGraceDuration: 15, uncertainStateGraceSnapshots: 8)
        )
        var recovery = BattleRecognitionRecovery()
        func sample(_ classification: GameStateClassification, at time: Double, fingerprint: String)
            -> BattleRecognitionRecoverySample {
            .init(classification: classification,
                  runtime: .init(observedAt: time, windowIdentity: identity,
                                 frameFingerprint: fingerprint, battleSessionID: "incident-battle",
                                 allAutoStatus: .active),
                  context: context, inputGeneration: 0)
        }
        func snapshot(_ sample: BattleRecognitionRecoverySample) -> AutoLevelSnapshot {
            .init(classification: sample.classification, runtime: sample.runtime)
        }
        // The prior battle PNG and intermediate normal captures were not retained. This
        // explicit synthetic baseline models an already confirmed same-battle observation;
        // it is not evidence of its precise time or the unrecorded live 30-second continuation.
        let rect = VisualBattleEvidence.measuredRetreatRect
        let baseline = GameStateClassification(
            state: .battle,
            evidence: [VisualBattleMarker.skipControl, .allAutoControl, .retreatControl].map {
                .init(kind: .battleMarker, observation: nil, detail: "synthetic replay baseline",
                      battleVisualMatch: .init(marker: $0, region: VisualBattleMatch.regions(for: $0)[0], similarity: 1))
            }, allowedActions: [], policyGatedActions: [
                .init(name: .openBattleRetreatConfirmation,
                      target: .init(name: .battleRetreat, sourceText: VisualBattleEvidence.measuredRetreatSentinel,
                                    rect: rect, point: rect.center), requirement: .temporalDefeatRecovery),
            ]
        )
        let initial = sample(baseline, at: began - 1.5, fingerprint: "synthetic-prior-battle")
        #expect(recovery.observe(initial) == nil)
        #expect(controller.consume(snapshot(initial)) == .wait(.battleInProgress))
        for fixture in frames {
            let observation = sample(try classify(load(fixture)), at: fixture.capturedAtElapsedSeconds,
                                     fingerprint: fixture.frameFingerprint)
            let observed = recovery.observe(observation)
            let assessment = try #require(observed)
            #expect(!assessment.isReady)
            #expect(controller.consume(snapshot(observation), battleRecognitionRecovery: assessment)
                == .wait(.battleRecognitionRecovery(remaining: 30 - assessment.elapsedSeconds)))
        }
        let classification = try classify(load(final))
        // Re-use the final pixels at explicit synthetic capture times to test the duration
        // boundary. The original process stopped before this continued sequence existed.
        var time = final.capturedAtElapsedSeconds + 1.5
        while time < began + 30 {
            let observation = sample(classification, at: time, fingerprint: final.frameFingerprint)
            let observed = recovery.observe(observation)
            let assessment = try #require(observed)
            #expect(controller.consume(snapshot(observation), battleRecognitionRecovery: assessment)
                == .wait(.battleRecognitionRecovery(remaining: 30 - assessment.elapsedSeconds)))
            #expect(controller.actionsIssued == 0)
            time += 1.5
        }
        let deadline = sample(classification, at: began + 30, fingerprint: final.frameFingerprint)
        let observed = recovery.observe(deadline)
        let assessment = try #require(observed)
        #expect(assessment.isReady)
        guard case let .requestAction(request) = controller.consume(
            snapshot(deadline), battleRecognitionRecovery: assessment
        ) else { Issue.record("Continued incident must request retreat at 30 seconds"); return }
        #expect(request.intent == .requestRetreat)
        #expect(request.observedState == .unknown)
        #expect(request.target.rect == rect)
        #expect(assessment.canPreflight(sample(classification, at: began + 30.4, fingerprint: final.frameFingerprint)))
        let posted = controller.markActionPosted(request, at: began + 30.5)
        #expect(posted)
        let modal = sample(try classify(loadResource("retreat-two-buttons")), at: began + 31,
                           fingerprint: "retreat-confirmation")
        guard case let .requestAction(confirm) = controller.consume(snapshot(modal)) else {
            Issue.record("Posted recovery retreat must continue through its confirmation"); return
        }
        #expect(confirm.intent == .pressWideModalTopButton)
        #expect(controller.actionsIssued == 2)
    }

    @Test("The previous run's actual iPhone disconnect cannot qualify for retreat recovery")
    func actualDisconnectedMirroring() throws {
        let negatives = try manifest().negativeControls
        #expect(negatives.count == 1)
        for fixture in negatives {
            let classification = try classify(load(fixture))
            #expect(classification.state == .unknown)
            #expect(!VisualBattleEvidence.hasRecoverableFooterOcclusion(in: classification))
            #expect(classification.allowedActions.isEmpty)
            #expect(classification.policyGatedActions.isEmpty)
            #expect(!VisualBattleEvidence.hasRunningBattleEvidence(in: classification))
            #expect(!VisualBattleEvidence.hasTrustedRetreat(in: classification))
        }
    }

    @Test("A covered or dimmed retreat glyph removes the incident's recovery evidence",
          arguments: [0.0, 0.25])
    func untrustedRetreatCannotRecover(scale: Double) throws {
        let fixture = try #require(manifest().sequence.last)
        var image = try load(fixture)
        // Independent native 400x878 bounds cover the retreat glyph and more than
        // the matcher's one-logical-pixel registration margin in every direction.
        // Only the decoded in-memory buffer changes; source PNGs stay unchanged.
        for y in 573..<599 {
            for x in 334..<373 {
                let offset = y * image.bytesPerRow + x * 4
                for channel in 0..<3 {
                    image.bytes[offset + channel] = UInt8(Double(image.bytes[offset + channel]) * scale)
                }
            }
        }
        let classification = try classify(image)
        #expect(classification.state == .unknown)
        #expect(!VisualBattleEvidence.hasRecoverableFooterOcclusion(in: classification))
        #expect(classification.allowedActions.isEmpty)
        #expect(classification.policyGatedActions.isEmpty)
        #expect(!VisualBattleEvidence.hasRunningBattleEvidence(in: classification))
        #expect(!VisualBattleEvidence.hasTrustedRetreat(in: classification))
    }

    @Test("Existing modals and result pages never become footer recovery candidates",
          arguments: [
            "visual-battle-modal-404x874", "battle-event-one-button",
            "battle-intro-one-button", "retreat-two-buttons", "defeat-one-button",
            "visual-result-failure-404x874", "visual-result-failure-selected",
            "visual-result-latest-experience", "visual-result-latest-live-loot",
            "visual-result-live-unselected-loot",
          ])
    func modalAndResultVeto(resource: String) throws {
        let classification = try classify(loadResource(resource))
        #expect(!VisualBattleEvidence.hasRecoverableFooterOcclusion(in: classification))
        #expect(!VisualBattleEvidence.hasRunningBattleEvidence(in: classification))
        #expect(!VisualBattleEvidence.hasTrustedRetreat(in: classification))
    }

    private func classify(_ image: Image) throws -> GameStateClassification {
        try AutoLevelVisualClassifier.classifyRGBA(
            image.bytes, width: image.width, height: image.height, bytesPerRow: image.bytesPerRow
        )
    }

    private func manifest() throws -> Manifest {
        let url = try #require(Bundle.module.url(
            forResource: "footer-occlusion-20260919-sequence", withExtension: "json"
        ))
        return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
    }

    private func load(_ fixture: Fixture) throws -> Image {
        let image = try loadResource(fixture.resource, expectedSHA256: fixture.pngSHA256)
        #expect(image.width == fixture.width && image.height == fixture.height)
        #expect(image.width == 400 && image.height == 878)
        return image
    }

    private func loadResource(_ resource: String, expectedSHA256: String? = nil) throws -> Image {
        let url = try #require(Bundle.module.url(forResource: resource, withExtension: "png"))
        let data = try Data(contentsOf: url)
        if let expectedSHA256 {
            #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == expectedSHA256)
        }
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let bytesPerRow = image.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * image.height)
        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard rendered else { throw FixtureError.cannotRender }
        return .init(bytes: bytes, width: image.width, height: image.height, bytesPerRow: bytesPerRow)
    }

    private struct Manifest: Decodable {
        let sequence: [Fixture]
        let negativeControls: [Fixture]
    }

    private struct Fixture: Decodable {
        let resource: String
        let captureSequence: Int
        let originalState: GameState
        let width: Int
        let height: Int
        let pngSHA256: String
        let capturedAtElapsedSeconds: Double
        let frameFingerprint: String
    }

    private struct Image {
        var bytes: [UInt8]
        let width: Int
        let height: Int
        let bytesPerRow: Int
    }

    private enum FixtureError: Error { case cannotRender }
}
