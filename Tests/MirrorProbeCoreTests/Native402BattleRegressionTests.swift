import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
@testable import MirrorProbeCore

@Suite("Native 402x882 battle after modal acknowledgement regression")
struct Native402BattleRegressionTests {
    @Test("All eight original battle captures acknowledge the modal and remain safe past its deadline")
    func originalSequenceAcknowledgesModalWithoutFurtherInput() throws {
        let incident = try manifest()
        let first = try #require(incident.sequence.first)
        let last = try #require(incident.sequence.last)
        #expect(incident.sequence.map(\.captureSequence) == Array(13...20))
        #expect(incident.sequence.allSatisfy { $0.originalState == .unknown })
        #expect(first.role == "calibration")
        #expect(incident.sequence.dropFirst().allSatisfy { $0.role == "heldOut" })
        #expect(Set(incident.sequence.map(\.pngSHA256)).count == 8)

        let policy = AutoLevelPolicy(postActionTimeout: 12,
                                     uncertainStateGraceDuration: 2,
                                     uncertainStateGraceSnapshots: 2)
        var controller = AutoLevelController(
            session: .init(sessionID: "native-402-modal-replay", startedAt: 0, windowIdentity: identity),
            policy: policy
        )
        // The modal PNG was not retained. Only this origin classification is synthetic,
        // reconstructed from the report's target and fingerprint; every battle is original.
        let origin = incident.syntheticModalOrigin
        let modal = WideModalActionResolver.resolve(
            classification: .init(state: .unknown, evidence: [], allowedActions: []),
            detection: .init(buttons: [.init(rect: origin.target.rect)], layout: .oneButton,
                             dialogRect: nil)
        )
        #expect(modal.state == origin.state)
        let decision = controller.consume(.init(
            classification: modal,
            runtime: .init(observedAt: origin.observedAt, windowIdentity: identity,
                           frameFingerprint: origin.frameFingerprint)
        ))
        guard case let .requestAction(request) = decision else {
            Issue.record("The reconstructed modal must issue exactly one close request")
            return
        }
        #expect(request.intent == .pressWideModalTopButton)
        #expect(request.target == origin.target)
        // The report lacks the exact mouse-post timestamp. This post time is an explicit
        // replay input, rather than the later actionPosted result-capture timestamp.
        let markedPosted = controller.markActionPosted(request, at: origin.observedAt)
        #expect(markedPosted)
        let oldDeadline = try #require(controller.pendingActionAcknowledgementDeadline)
        #expect(first.capturedAtElapsedSeconds < oldDeadline)
        #expect(last.capturedAtElapsedSeconds > oldDeadline)

        for fixture in incident.sequence {
            let classification = try classify(load(fixture))
            #expect(classification.state == .battle)
            #expect(classification.allowedActions.isEmpty)
            #expect(VisualBattleEvidence.hasRunningBattleEvidence(in: classification))
            #expect(VisualBattleEvidence.hasTrustedRetreat(in: classification))
            #expect(classification.evidence.allSatisfy { $0.observation == nil && $0.visualMatch == nil })
            let matches = classification.evidence.compactMap(VisualBattleEvidence.validatedMatch)
            for marker in [VisualBattleMarker.skipControl, .allAutoControl, .retreatControl] {
                #expect(matches.contains { $0.marker == marker })
            }
            #expect(matches.allSatisfy { $0.similarity >= VisualBattleMatch.minimumSimilarity })
            #expect(classification.policyGatedActions.count == 1)
            let retreat = try #require(classification.policyGatedActions.first)
            #expect(retreat.name == .openBattleRetreatConfirmation)
            #expect(retreat.requirement == .temporalDefeatRecovery)
            #expect(retreat.target.rect == VisualBattleEvidence.measuredRetreatRect)

            // These temporal runtime facts are explicit replay inputs, not claims that a
            // static image proves automatic mode, actual progress, or a recoverable stall.
            let observation = AutoLevelSnapshot(
                classification: classification,
                runtime: .init(observedAt: fixture.capturedAtElapsedSeconds, windowIdentity: identity,
                               frameFingerprint: fixture.frameFingerprint,
                               battleSessionID: "native-402-battle", allAutoStatus: .active,
                               battleStatus: .inProgress)
            )
            #expect(observation.actionCandidates.map(\.intent) == [.requestRetreat])
            #expect(controller.consume(observation) == .wait(.battleInProgress))
            #expect(controller.pendingActionAcknowledgementDeadline == nil)
            #expect(controller.actionsIssued == 1)
        }
        #expect(controller.completedCycles == 0)
    }

    @Test("Masking or dimming each required 402-pixel battle glyph fails closed",
          arguments: [VisualBattleMarker.skipControl, .allAutoControl, .retreatControl], [0.0, 0.25])
    func requiredControlsFailClosed(marker: VisualBattleMarker, scale: Double) throws {
        var image = try finalImage()
        alterControl(marker, in: &image, by: scale)
        let classification = try classify(image)
        #expect(classification.state == .unknown)
        #expect(!VisualBattleEvidence.hasRunningBattleEvidence(in: classification))
        #expect(!VisualBattleEvidence.hasTrustedRetreat(in: classification))
        #expect(classification.allowedActions.isEmpty && classification.policyGatedActions.isEmpty)
        let observation = AutoLevelSnapshot(
            classification: classification,
            runtime: .init(observedAt: 1, windowIdentity: identity,
                           frameFingerprint: "synthetic-covered-\(marker)-\(scale)")
        )
        #expect(observation.actionCandidates.isEmpty)
        var controller = AutoLevelController(session: .init(
            sessionID: "native-402-covered-glyph", startedAt: 0, windowIdentity: identity
        ))
        #expect(controller.consume(observation)
            == .wait(.transientState(kind: .unknown, observationCount: 1)))
        #expect(controller.actionsIssued == 0)
    }

    @Test("The diagnostic pause glyph remains optional at 402x882")
    func obscuredPausePreservesOnlyTemporalRetreatCandidate() throws {
        var image = try finalImage()
        alterControl(.pauseControl, in: &image, by: 0)
        let classification = try classify(image)
        #expect(classification.state == .battle)
        #expect(VisualBattleEvidence.hasTrustedRetreat(in: classification))
        #expect(classification.allowedActions.isEmpty)
        #expect(classification.policyGatedActions.map(\.name) == [.openBattleRetreatConfirmation])
        #expect(!classification.evidence.contains { $0.battleVisualMatch?.marker == .pauseControl })
    }

    @Test("Recognizing the new native geometry cannot invent temporal battle progress")
    func staticImageCannotAuthorizeRecovery() throws {
        let image = try finalImage()
        let classification = try classify(image)
        #expect(VisualBattleEvidence.hasTrustedRetreat(in: classification))
        let evidence = try BattleActivityFrameEvidence.extractVisual(
            image.bytes, width: image.width, height: image.height,
            bytesPerRow: image.bytesPerRow, classification: classification
        )
        let context = BattleWindowContext(
            processID: identity.processID, windowID: identity.windowID,
            originX: 2, originY: 30, width: 402, height: 882
        )
        var detector = BattleActivityProgressDetector()
        #expect(detector.automaticBattleExpected(
            at: 0, battleSessionID: "native-402-battle", context: context, inputGeneration: 1
        ) == .awaitingEvidence)
        for time in 1...12 {
            #expect(detector.observe(.init(
                monotonicTime: Double(time), battleSessionID: "native-402-battle", context: context,
                inputGeneration: 1, evidence: evidence, battleROIDifferenceFromPrevious: 0
            )) == .awaitingEvidence)
        }
        var controller = AutoLevelController(session: .init(
            sessionID: "native-402-no-temporal-proof", startedAt: 0, windowIdentity: identity
        ))
        #expect(controller.consume(.init(
            classification: classification,
            runtime: .init(observedAt: 1, windowIdentity: identity, frameFingerprint: "same-image",
                           battleSessionID: "native-402-battle", allAutoStatus: .active,
                           battleStatus: .unknown)
        )) == .wait(.transientState(kind: .battleMetadataUnknown, observationCount: 1)))
        #expect(controller.actionsIssued == 0)
    }

    private let identity = AutoLevelWindowIdentity(processID: 64266, windowID: 6656)

    private func classify(_ image: Image) throws -> GameStateClassification {
        try AutoLevelVisualClassifier.classifyRGBA(
            image.bytes, width: image.width, height: image.height, bytesPerRow: image.bytesPerRow
        )
    }

    private func manifest() throws -> Manifest {
        let url = try #require(Bundle.module.url(forResource: "native-402-battle-sequence", withExtension: "json"))
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
        #expect(image.width == 402 && image.height == 882)
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

    private func alterControl(_ marker: VisualBattleMarker, in image: inout Image, by scale: Double) {
        // Independent 402x882 native bounds include the glyph and registration margin.
        // Only decoded memory changes; the retained PNGs remain byte-for-byte original.
        let bounds: (x: Range<Int>, y: Range<Int>)
        switch marker {
        case .skipControl: bounds = (28..<69, 765..<790)
        case .allAutoControl: bounds = (88..<151, 765..<790)
        case .pauseControl: bounds = (335..<374, 549..<576)
        case .retreatControl: bounds = (335..<374, 575..<602)
        }
        for y in bounds.y {
            for x in bounds.x {
                let offset = y * image.bytesPerRow + x * 4
                for channel in 0..<3 {
                    image.bytes[offset + channel] = UInt8(Double(image.bytes[offset + channel]) * scale)
                }
            }
        }
    }

    private struct Manifest: Decodable {
        let syntheticModalOrigin: ModalOrigin
        let sequence: [Fixture]
    }
    private struct ModalOrigin: Decodable {
        let observedAt: Double
        let frameFingerprint: String
        let state: GameState
        let target: AutoLevelActionTarget
    }
    private struct Fixture: Decodable {
        let resource: String
        let captureSequence: Int
        let capturedAtElapsedSeconds: Double
        let originalState: GameState
        let frameFingerprint: String
        let width: Int
        let height: Int
        let pngSHA256: String
        let role: String
    }
    private struct Image {
        var bytes: [UInt8]
        let width: Int
        let height: Int
        let bytesPerRow: Int
    }
    private enum FixtureError: Error { case cannotRender }
}
