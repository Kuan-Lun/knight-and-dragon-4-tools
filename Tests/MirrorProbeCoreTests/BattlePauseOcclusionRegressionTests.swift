import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
@testable import MirrorProbeCore

@Suite("Native battle pause occlusion incident regression")
struct BattlePauseOcclusionRegressionTests {
    @Test("Every retained incident capture remains a running battle beyond uncertainty grace")
    func replayOriginalSequence() throws {
        let frames = try manifest().sequence
        let first = try #require(frames.first), last = try #require(frames.last)
        let policy = AutoLevelPolicy(uncertainStateGraceDuration: 2, uncertainStateGraceSnapshots: 2)
        #expect(frames.map(\.captureSequence) == Array(7542...7549))
        #expect(frames.allSatisfy { $0.originalState == .unknown })
        #expect(frames.count > policy.uncertainStateGraceSnapshots)
        #expect(last.capturedAtElapsedSeconds - first.capturedAtElapsedSeconds
            > policy.uncertainStateGraceDuration)
        #expect(Set(frames.map(\.pngSHA256)).count == 5)
        var controller = AutoLevelController(
            session: .init(sessionID: "pause-occlusion-incident", startedAt: 0, windowIdentity: identity),
            policy: policy
        )

        for fixture in frames {
            let image = try load(fixture)
            let classification = try classify(image)
            #expect(classification.state == .battle)
            #expect(classification.allowedActions.isEmpty)
            #expect(VisualBattleEvidence.hasRunningBattleEvidence(in: classification))
            #expect(VisualBattleEvidence.hasTrustedRetreat(in: classification))
            #expect(classification.evidence.count == 3)
            #expect(classification.evidence.allSatisfy { $0.observation == nil && $0.visualMatch == nil })
            let matches = classification.evidence.compactMap(\.battleVisualMatch)
            #expect(Set(matches.map { $0.marker.rawValue })
                == Set([VisualBattleMarker.skipControl, .allAutoControl, .retreatControl].map(\.rawValue)))
            #expect(matches.allSatisfy { $0.similarity >= VisualBattleMatch.minimumSimilarity })
            let retreat = try #require(classification.policyGatedActions.first)
            #expect(classification.policyGatedActions.count == 1)
            #expect(retreat.name == .openBattleRetreatConfirmation)
            #expect(retreat.requirement == .temporalDefeatRecovery)
            #expect(retreat.target.rect == VisualBattleEvidence.measuredRetreatRect)

            // These runtime facts are explicit replay inputs. The image does not establish
            // automatic mode, actual progress, or permission to recover a temporal stall.
            let snapshot = AutoLevelSnapshot(
                classification: classification,
                runtime: .init(observedAt: fixture.capturedAtElapsedSeconds,
                               windowIdentity: identity, frameFingerprint: fixture.frameFingerprint,
                               battleSessionID: "incident-battle", allAutoStatus: .active,
                               battleStatus: .inProgress)
            )
            #expect(snapshot.actionCandidates.map(\.intent) == [.requestRetreat])
            #expect(controller.consume(snapshot) == .wait(.battleInProgress))
        }
        #expect(controller.actionsIssued == 0)
        #expect(controller.completedCycles == 0)
    }

    @Test("Masking or dimming any required footer or retreat glyph fails closed",
          arguments: [VisualBattleMarker.skipControl, .allAutoControl, .retreatControl], [0.0, 0.25])
    func requiredControlsFailClosed(marker: VisualBattleMarker, scale: Double) throws {
        var image = try finalImage()
        for region in VisualBattleMatch.regions(for: marker) {
            scaleRegion(region, in: &image, by: scale)
        }
        let classification = try classify(image)
        #expect(classification.state == .unknown)
        #expect(!VisualBattleEvidence.hasRunningBattleEvidence(in: classification))
        #expect(!VisualBattleEvidence.hasTrustedRetreat(in: classification))
        #expect(classification.allowedActions.isEmpty && classification.policyGatedActions.isEmpty)
    }

    @Test("Repeated identical native images cannot establish battle progress")
    func staticImageCannotEstablishProgress() throws {
        let image = try finalImage()
        let classification = try classify(image)
        #expect(VisualBattleEvidence.hasRunningBattleEvidence(in: classification))
        let evidence = try BattleActivityFrameEvidence.extractVisual(
            image.bytes, width: image.width, height: image.height,
            bytesPerRow: image.bytesPerRow, classification: classification
        )
        #expect(evidence.hasStrictBattleBackground)
        var detector = BattleActivityProgressDetector()
        #expect(detector.automaticBattleExpected(
            at: 0, battleSessionID: "incident-battle", context: context, inputGeneration: 7
        ) == .awaitingEvidence)
        for time in 1...12 {
            let sample = BattleActivityProgressSample(
                monotonicTime: Double(time), battleSessionID: "incident-battle", context: context,
                inputGeneration: 7, evidence: evidence, battleROIDifferenceFromPrevious: 0
            )
            #expect(detector.observe(sample) == .awaitingEvidence)
        }
    }

    @Test("Recognizing the incident image cannot create a temporal stall authorization")
    func staticImageCannotArmRecovery() throws {
        let classification = try classify(finalImage())
        #expect(VisualBattleEvidence.hasTrustedRetreat(in: classification))
        let evidence = BattleStallFrameEvidence.extractVisual(from: classification)
        #expect(evidence.background.isStrict)
        #expect(evidence.enemyHP == nil && evidence.partyHP.isEmpty && evidence.combatLogSignature.isEmpty)
        #expect(!evidence.hasCompleteDefeatCandidateEvidence)
        var detector = BattleStallDetector()
        _ = detector.automaticBattleEnabled(at: 0, context: context, inputGeneration: 7)
        for time in 1...12 {
            let sample = BattleStallSample(
                monotonicTime: Double(time), context: context, battleScreenConfirmed: true,
                modalPresent: false, paused: false, inputGeneration: 7,
                frameEvidence: evidence, battleROIDifferenceFromPrevious: 0
            )
            #expect(detector.beginVisualConfirmation(from: sample) == nil)
            let assessment = detector.observe(sample)
            #expect(!assessment.isArmed && !assessment.isConfirmedEvidence)
        }

        var controller = AutoLevelController(session: .init(
            sessionID: "pause-occlusion-no-temporal-facts", startedAt: 0, windowIdentity: identity
        ))
        let snapshot = AutoLevelSnapshot(
            classification: classification,
            runtime: .init(observedAt: 1, windowIdentity: identity, frameFingerprint: "same-incident-image",
                           battleSessionID: "incident-battle", allAutoStatus: .active, battleStatus: .unknown)
        )
        #expect(controller.consume(snapshot)
            == .wait(.transientState(kind: .battleMetadataUnknown, observationCount: 1)))
        #expect(controller.actionsIssued == 0)
    }

    private let identity = AutoLevelWindowIdentity(processID: 91507, windowID: 65194)
    private let context = BattleWindowContext(
        processID: 91507, windowID: 65194, originX: 0, originY: 30, width: 406, height: 890
    )

    private func classify(_ image: Image) throws -> GameStateClassification {
        try AutoLevelVisualClassifier.classifyRGBA(
            image.bytes, width: image.width, height: image.height, bytesPerRow: image.bytesPerRow
        )
    }

    private func manifest() throws -> Manifest {
        let url = try #require(Bundle.module.url(forResource: "battle-pause-occlusion-sequence", withExtension: "json"))
        return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
    }

    private func finalImage() throws -> Image {
        try load(#require(manifest().sequence.last))
    }

    private func load(_ fixture: Fixture) throws -> Image {
        let url = try #require(Bundle.module.url(forResource: fixture.resource, withExtension: "png"))
        let data = try Data(contentsOf: url)
        #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == fixture.pngSHA256)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == fixture.width && image.height == fixture.height)
        #expect(image.width == 406 && image.height == 890)
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
        return Image(bytes: bytes, width: image.width, height: image.height, bytesPerRow: bytesPerRow)
    }

    private func scaleRegion(_ region: NormalizedRect, in image: inout Image, by scale: Double) {
        // Only the decoded in-memory buffer changes; native fixture PNGs remain unmodified.
        for y in Int(floor(region.y * Double(image.height)))..<Int(ceil((region.y + region.height) * Double(image.height))) {
            for x in Int(floor(region.x * Double(image.width)))..<Int(ceil((region.x + region.width) * Double(image.width))) {
                let offset = y * image.bytesPerRow + x * 4
                for channel in 0..<3 {
                    image.bytes[offset + channel] = UInt8(Double(image.bytes[offset + channel]) * scale)
                }
            }
        }
    }

    private struct Manifest: Decodable { let sequence: [Fixture] }
    private struct Fixture: Decodable {
        let resource: String
        let captureSequence: Int
        let capturedAtElapsedSeconds: Double
        let originalState: GameState
        let frameFingerprint: String
        let width: Int
        let height: Int
        let pngSHA256: String
    }
    private struct Image {
        var bytes: [UInt8]
        let width: Int
        let height: Int
        let bytesPerRow: Int
    }
    private enum FixtureError: Error { case cannotRender }
}
