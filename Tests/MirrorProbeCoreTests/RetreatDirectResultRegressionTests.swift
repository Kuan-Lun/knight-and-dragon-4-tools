import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
@testable import MirrorProbeCore

@Suite("Native retreat to mission result regression")
struct RetreatDirectResultRegressionTests {
    @Test("Posted retreat accepts the recorded result and continues exactly once", arguments: [
        ("retreat-direct-failure", [182, 183], GameState.missionFailed,
         AutoLevelCycleOutcome.failure, GameActionName.selectMissionRepeat, AutoLevelActionIntent.selectMissionRepeat),
        ("retreat-direct-success", [1052, 1053], GameState.missionCompleteRepeatSelected,
         AutoLevelCycleOutcome.success, GameActionName.advanceMissionComplete, AutoLevelActionIntent.advanceMissionSuccess),
    ])
    func replayNativeTransition(
        resourcePrefix: String, captureSequences: [Int], resultState: GameState,
        outcome: AutoLevelCycleOutcome, nextAction: GameActionName, nextIntent: AutoLevelActionIntent
    ) throws {
        let manifestURL = try #require(Bundle.module.url(
            forResource: resourcePrefix + "-sequence", withExtension: "json"
        ))
        let fixtures = try JSONDecoder().decode(
            Manifest.self, from: Data(contentsOf: manifestURL)
        ).sequence
        #expect(fixtures.map(\.captureSequence) == captureSequences)
        let before = try #require(fixtures.first), final = try #require(fixtures.last)
        let beforeState = try classify(before), finalState = try classify(final)
        #expect(beforeState.state == .battle)
        #expect(VisualBattleEvidence.hasTrustedRetreat(in: beforeState))
        #expect(finalState.state == resultState)
        #expect(finalState.allowedActions.map(\.name) == [nextAction])

        let identity = AutoLevelWindowIdentity(processID: 91507, windowID: 65194)
        var controller = AutoLevelController(
            session: .init(sessionID: resourcePrefix, startedAt: 0, windowIdentity: identity),
            policy: .init(actionCooldown: 0)
        )
        // Each manifest records the source event that confirmed progress and a dense stall.
        // Replay supplies that runtime fact; a single fixture never establishes retreat proof.
        let beforeSnapshot = AutoLevelSnapshot(
            classification: beforeState,
            runtime: .init(observedAt: before.capturedAtElapsedSeconds, windowIdentity: identity,
                           frameFingerprint: before.frameFingerprint, battleSessionID: "incident-battle",
                           allAutoStatus: .active, battleStatus: .stalledAfterDefeat)
        )
        let retreat = try action(controller.consume(beforeSnapshot))
        #expect(retreat.intent == .requestRetreat)
        #expect(retreat.target.rect == VisualBattleEvidence.measuredRetreatRect)
        // The report has capture times but no exact mouse timestamp. Use a synthetic posting
        // time strictly between those captures to exercise acknowledgement without new input.
        let postedAt = before.capturedAtElapsedSeconds + 0.01
        #expect(postedAt < final.capturedAtElapsedSeconds)
        let posted = controller.markActionPosted(retreat, at: postedAt)
        #expect(posted)

        let result = AutoLevelSnapshot(
            classification: finalState,
            runtime: .init(observedAt: final.capturedAtElapsedSeconds, windowIdentity: identity,
                           frameFingerprint: final.frameFingerprint)
        )
        #expect(controller.consume(result, allowNewActions: false) == .completedCycle(
            .init(count: 1, outcome: outcome)
        ))
        #expect(controller.pendingActionAcknowledgementDeadline == nil)
        #expect(controller.actionsIssued == 1)
        let reposted = controller.markActionPosted(retreat, at: final.capturedAtElapsedSeconds)
        #expect(!reposted)
        #expect(controller.consume(result, allowNewActions: false) == .wait(.freshObservationRequired))
        #expect(controller.completedCycles == 1)
        #expect(controller.actionsIssued == 1)

        let continuation = try action(controller.consume(result))
        #expect(continuation.intent == nextIntent)
        #expect(continuation.target == AutoLevelActionTarget(
            try #require(finalState.allowedActions.first).target
        ))
        #expect(continuation.requestID == retreat.requestID + 1)
        #expect(controller.completedCycles == 1)
        #expect(controller.actionsIssued == 2)
    }

    private func action(_ decision: AutoLevelDecision) throws -> AutoLevelActionRequest {
        guard case let .requestAction(request) = decision else {
            Issue.record("Expected action, got \(decision)")
            throw FixtureError.expectedAction
        }
        return request
    }

    private func classify(_ fixture: Fixture) throws -> GameStateClassification {
        let url = try #require(Bundle.module.url(forResource: fixture.resource, withExtension: "png"))
        let png = try Data(contentsOf: url)
        let hash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        #expect(hash == fixture.pngSHA256)
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == fixture.width && image.height == fixture.height)
        let bytesPerRow = image.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * image.height)
        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let address = buffer.baseAddress,
                  let context = CGContext(
                    data: address, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                        | CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        try #require(rendered)
        return try AutoLevelVisualClassifier.classifyRGBA(
            bytes, width: image.width, height: image.height, bytesPerRow: bytesPerRow
        )
    }

    private struct Manifest: Decodable { let sequence: [Fixture] }
    private struct Fixture: Decodable {
        let resource: String
        let captureSequence: Int
        let capturedAtElapsedSeconds: Double
        let frameFingerprint: String
        let width: Int
        let height: Int
        let pngSHA256: String
    }
    private enum FixtureError: Error { case expectedAction }
}
