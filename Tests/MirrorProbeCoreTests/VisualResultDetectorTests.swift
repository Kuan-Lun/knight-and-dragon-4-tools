import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
@testable import MirrorProbeCore

@Suite("Result-page visual recognition from original captures")
struct VisualResultDetectorTests {
    @Test("Native 1x and 2x captures classify without OCR, including obscured and modal negatives",
          arguments: [
            "mission-repeat-selected-srlected", "mission-repeat-unselected",
            "mission-result-no-modal", "failure-repeat-confirmation-before",
            "failure-repeat-confirmation-final", "visual-result-failure-selected",
            "result-title-occlusion-before", "result-title-occlusion-confirmation",
            "mission-skill-acquired-one-button", "loot-two-buttons",
            "adventurer-two-buttons", "battle-no-modal", "returned-party-manual-stop",
            "low-result-title-startup", "low-result-title-experience",
            "low-result-title-loot-after", "visual-result-latest-experience",
            "visual-result-latest-loot-after", "visual-result-latest-loot-final",
            "visual-result-latest-live-loot", "visual-result-live-unselected-loot",
          ])
    func originalCaptureClassification(resource: String) throws {
        let capture = try load(resource)
        let classification = capture.classification
        #expect(classification.state == capture.fixture.expectedState)
        #expect(classification.policyGatedActions.isEmpty)
        #expect(classification.evidence.allSatisfy { $0.observation == nil })

        guard capture.fixture.expectedState != .unknown else {
            #expect(classification.allowedActions.isEmpty)
            #expect(snapshot(capture, at: 1).actionCandidates.isEmpty)
            return
        }

        #expect(MissionSuccessPageIdentity.resolve(in: classification) == capture.fixture.expectedPage)
        #expect(VisualResultEvidence.hasConsistentVisualEvidence(in: classification))
        let matches = classification.evidence.compactMap(\.visualMatch)
        #expect(matches.count == 3)
        #expect(matches.allSatisfy { $0.similarity >= VisualResultMatch.minimumSimilarity })
        // Native captures of unscrolled pages match at the calibrated positions.
        #expect(matches.allSatisfy { $0.listOffset == 0 })
        #expect(Set(matches.map { $0.marker.rawValue }).count == 3)
        #expect(snapshot(capture, at: 1).actionCandidates.map(\.intent)
            == [try #require(capture.fixture.expectedIntent)])

        let action = try #require(classification.allowedActions.first)
        let target = AutoLevelActionTarget(action.target)
        if capture.fixture.expectedIntent == .selectMissionRepeat {
            #expect(action.name == .selectMissionRepeat)
            #expect(MissionRepeatSelectionProof.page(in: classification, matching: target)
                == capture.fixture.expectedPage)
            #expect(target.sourceText == VisualResultEvidence.measuredRepeatOptionSentinel)
        } else {
            #expect(action.name == .advanceMissionComplete)
            #expect(target.rect == MissionResultTopActionResolver.measuredTopAdvanceRect)
        }
    }

    @Test("The 05:25 run's actual EXP-to-loot image change acknowledges the posted result action")
    func latestCapturedPageChangeAcknowledgesPost() throws {
        let experience = try load("visual-result-latest-experience")
        let loot = try load("visual-result-latest-loot-after")
        let final = try load("visual-result-latest-loot-final")
        var controller = AutoLevelController(
            session: .init(sessionID: "visual-result-page-change", startedAt: 0,
                           windowIdentity: identity),
            policy: .init(actionCooldown: 0.8, postActionTimeout: 12)
        )
        #expect(controller.consume(snapshot(experience, at: 1))
            == .completedCycle(.init(count: 1, outcome: .success)))
        let experienceDecision = controller.consume(snapshot(experience, at: 1))
        let experienceRequest = try action(experienceDecision)
        let experiencePosted = controller.markActionPosted(experienceRequest, at: 2)
        #expect(experiencePosted)
        #expect(controller.pendingActionAcknowledgementDeadline == 14)

        let lootDecision = controller.consume(snapshot(loot, at: 3))
        let lootRequest = try action(lootDecision)
        #expect(lootRequest.requestID == experienceRequest.requestID + 1)
        #expect(lootRequest.intent == .advanceMissionSuccess)
        #expect(lootRequest.target == experienceRequest.target)
        #expect(lootRequest.frameFingerprint != experienceRequest.frameFingerprint)
        #expect(controller.pendingActionAcknowledgementDeadline == nil)
        #expect(controller.completedCycles == 1)
        #expect(controller.actionsIssued == 2)
        let stalePost = controller.markActionPosted(experienceRequest, at: 3.05)
        #expect(!stalePost)

        let lootPosted = controller.markActionPosted(lootRequest, at: 3.1)
        #expect(lootPosted)
        #expect(controller.consume(snapshot(final, at: 4))
            == .wait(.awaitingStateChange(intent: .advanceMissionSuccess)))
        #expect(controller.completedCycles == 1)
        #expect(controller.actionsIssued == 2)
    }

    @Test("The visual corpus covers both native resolutions and all four result states")
    func corpusCoverage() throws {
        let fixtures = try manifest().fixtures
        #expect(Set(fixtures.map { "\($0.width)x\($0.height)" }) == ["406x890", "812x1780"])
        #expect(Set(fixtures.map { $0.expectedState.rawValue }) == [
            "missionComplete", "missionCompleteRepeatSelected",
            "missionFailed", "missionFailedRepeatSelected", "unknown",
        ])
        #expect(fixtures.filter { $0.expectedState == .unknown }.count == 6)
        #expect(Set(fixtures.map(\.resource)).count == fixtures.count)
    }

    private let identity = AutoLevelWindowIdentity(processID: 91507, windowID: 65194)

    private func snapshot(_ capture: Capture, at time: TimeInterval) -> AutoLevelSnapshot {
        .init(classification: capture.classification,
              runtime: .init(observedAt: time, windowIdentity: identity,
                             frameFingerprint: capture.fixture.pngSHA256))
    }

    private func action(_ decision: AutoLevelDecision) throws -> AutoLevelActionRequest {
        guard case let .requestAction(request) = decision else {
            Issue.record("Expected a result action, received \(decision)")
            throw FixtureError.expectedAction
        }
        return request
    }

    private func manifest() throws -> Manifest {
        let url = try #require(Bundle.module.url(forResource: "visual-result-corpus", withExtension: "json"))
        return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
    }

    private func load(_ name: String) throws -> Capture {
        let fixture = try #require(manifest().fixtures.first { $0.resource == name })
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "png"))
        let data = try Data(contentsOf: url)
        #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == fixture.pngSHA256)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
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
                  ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard rendered else { throw FixtureError.cannotRender }
        let classification = try VisualResultDetector.classifyRGBA(
            bytes, width: image.width, height: image.height, bytesPerRow: bytesPerRow
        )
        return Capture(fixture: fixture, classification: classification)
    }

    private struct Manifest: Decodable { let fixtures: [Fixture] }
    private struct Fixture: Decodable {
        let resource: String
        let expectedState: GameState
        let expectedPage: MissionSuccessPageIdentity?
        let expectedIntent: AutoLevelActionIntent?
        let width: Int
        let height: Int
        let pngSHA256: String
    }
    private struct Capture {
        let fixture: Fixture
        let classification: GameStateClassification
    }
    private enum FixtureError: Error { case cannotRender, expectedAction }
}
