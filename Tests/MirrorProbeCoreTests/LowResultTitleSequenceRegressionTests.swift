import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
@testable import MirrorProbeCore

@Suite("Captured low-confidence result-title sequences")
struct LowResultTitleSequenceRegressionTests {
    private let identity = AutoLevelWindowIdentity(processID: 91507, windowID: 65194)

    @Test("Original saved OCR reproduces the result-title failure without changing the confidence floor",
          arguments: ["startup", "experience", "loot-after", "loot-final"])
    func originalCapturedClassification(name: String) throws {
        let replay = try load(name)
        #expect(replay.stamp.isPresent)
        #expect(replay.original.state == replay.saved.classification.state)
        #expect(replay.original.allowedActions == replay.saved.classification.allowedActions)
        #expect(replay.original.policyGatedActions == replay.saved.classification.policyGatedActions)
        // The stamp ROI now excludes the first dynamic loot row. Its measured ratio changes,
        // while the saved OCR evidence and resulting action must remain exactly the same.
        #expect(replay.original.evidence.filter { $0.kind != .repeatSelectedMarker }
            == replay.saved.classification.evidence.filter { $0.kind != .repeatSelectedMarker })
        #expect(replay.original.evidence.filter { $0.kind == .repeatSelectedMarker }.count
            == replay.saved.classification.evidence.filter { $0.kind == .repeatSelectedMarker }.count)
        if name == "experience" {
            #expect(replay.original.state == .missionCompleteRepeatSelected)
            #expect(MissionSuccessPageIdentity.resolve(in: replay.original) == .experience)
        } else {
            #expect(replay.original.state == .unknown)
            #expect(replay.original.allowedActions.isEmpty)
            #expect(replay.original.policyGatedActions.isEmpty)
            #expect(replay.original.evidence.count == 1)
            #expect(replay.original.evidence.first?.kind == .lowConfidenceMarker)
            #expect(replay.original.evidence.first?.observation?.confidence == 0.5)
        }
    }

    @Test("Focused OCR of the first run's intact title enables one selected-loot startup request")
    func startupRecoversWithoutTogglingSelectedRepeat() throws {
        let replay = try load("startup")
        var originalController = makeController()
        #expect(originalController.consume(snapshot(replay.original, replay: replay, at: 1))
            == .wait(.transientState(kind: .unknown, observationCount: 1)))
        #expect(originalController.consume(snapshot(replay.original, replay: replay, at: 16))
            == .stop(.uncertainStateExceededGrace(kind: .unknown)))
        #expect(originalController.actionsIssued == 0)

        let refined = try refine(replay, name: "startup")
        var controller = makeController()
        let result = snapshot(refined, replay: replay, at: 1)
        #expect(controller.consume(result) == .completedCycle(.init(count: 1, outcome: .success)))
        let decision = controller.consume(result)
        let request = try action(decision)
        #expect(request.intent == .advanceMissionSuccess)
        #expect(request.frameFingerprint == replay.saved.image.pngSHA256)
        #expect(controller.actionsIssued == 1)
        #expect(controller.completedCycles == 1)
        #expect(result.actionCandidates.map(\.intent) == [.advanceMissionSuccess])
    }

    @Test("Unknown loot after a successful EXP post reproduces the original acknowledgement timeout")
    func originalUnknownLootCannotAcknowledgePostedExperience() throws {
        let experience = try load("experience")
        let loot = try load("loot-after")
        let final = try load("loot-final")
        var controller = makeController()
        let request = try issueExperience(experience, controller: &controller)
        let posted = controller.markActionPosted(request, at: 2)
        #expect(posted)
        #expect(controller.pendingActionAcknowledgementDeadline == 14)

        #expect(controller.consume(snapshot(loot.original, replay: loot, at: 3))
            == .wait(.transientState(kind: .unknown, observationCount: 1)))
        #expect(controller.consume(snapshot(final.original, replay: final, at: 13))
            == .wait(.transientState(kind: .unknown, observationCount: 2)))
        #expect(controller.consume(snapshot(final.original, replay: final, at: 14))
            == .stop(.actionDidNotAdvance(intent: .advanceMissionSuccess)))
        #expect(controller.actionsIssued == 1)
        #expect(controller.completedCycles == 1)
    }

    @Test("Same-image focused loot title acknowledges EXP and issues a fresh loot request without recounting")
    func refinedLootAcknowledgesExperienceAndPreservesCycle() throws {
        let experience = try load("experience")
        let loot = try load("loot-after")
        let final = try load("loot-final")
        let refinedLoot = try refine(loot, name: "loot-after")
        let refinedFinal = try refine(final, name: "loot-final")
        var controller = makeController()
        let experienceRequest = try issueExperience(experience, controller: &controller)
        let experiencePosted = controller.markActionPosted(experienceRequest, at: 2)
        #expect(experiencePosted)

        let nextDecision = controller.consume(snapshot(refinedLoot, replay: loot, at: 3))
        let lootRequest = try action(nextDecision)
        #expect(lootRequest.requestID == experienceRequest.requestID + 1)
        #expect(lootRequest.intent == .advanceMissionSuccess)
        #expect(lootRequest.frameFingerprint == loot.saved.image.pngSHA256)
        #expect(lootRequest.frameFingerprint != experienceRequest.frameFingerprint)
        #expect(lootRequest.target == experienceRequest.target)
        #expect(controller.pendingActionAcknowledgementDeadline == nil)
        #expect(controller.actionsIssued == 2)
        #expect(controller.completedCycles == 1)
        let duplicateExperiencePost = controller.markActionPosted(experienceRequest, at: 3.05)
        #expect(!duplicateExperiencePost)

        let lootPosted = controller.markActionPosted(lootRequest, at: 3.1)
        #expect(lootPosted)
        #expect(controller.consume(snapshot(refinedFinal, replay: final, at: 4))
            == .wait(.awaitingStateChange(intent: .advanceMissionSuccess)))
        #expect(controller.actionsIssued == 2)
        #expect(controller.completedCycles == 1)
    }

    private func refine(_ replay: Replay, name: String) throws -> GameStateClassification {
        let focusedURL = try resource("low-result-title-\(name)-focused", extension: "json")
        let focused = try JSONDecoder().decode(Focused.self, from: Data(contentsOf: focusedURL))
        #expect(focused.region == MissionResultTitleRefinement.region)
        #expect(focused.observations.count == 1)
        #expect(focused.observations.first?.confidence == 1)
        #expect(MissionResultTitleRefinement.needsRefinement(
            observations: replay.saved.ocr.observations,
            classification: replay.original,
            repeatSelectedStampDetection: replay.stamp
        ))
        let refined = try #require(MissionResultTitleRefinement.refinedClassification(
            observations: replay.saved.ocr.observations,
            classification: replay.original,
            repeatSelectedStampDetection: replay.stamp,
            focusedObservations: focused.observations
        ))
        #expect(refined.state == .missionCompleteRepeatSelected)
        #expect(MissionSuccessPageIdentity.resolve(in: refined) == .loot)
        #expect(refined.allowedActions.map(\.name) == [.advanceMissionComplete])
        #expect(refined.evidence.contains {
            $0.kind == .missionCompleteTitle && $0.observation?.confidence == 1
                && $0.detail.contains("source=focusedResultTitle")
        })
        return refined
    }

    private func issueExperience(_ replay: Replay, controller: inout AutoLevelController)
        throws -> AutoLevelActionRequest
    {
        let result = snapshot(replay.original, replay: replay, at: 1)
        #expect(controller.consume(result) == .completedCycle(.init(count: 1, outcome: .success)))
        let decision = controller.consume(result)
        let request = try action(decision)
        #expect(request.intent == .advanceMissionSuccess)
        return request
    }

    private func action(_ decision: AutoLevelDecision) throws -> AutoLevelActionRequest {
        guard case let .requestAction(request) = decision else {
            Issue.record("Expected a result action, received \(decision)")
            throw ReplayError.expectedAction
        }
        return request
    }

    private func makeController() -> AutoLevelController {
        .init(session: .init(sessionID: "low-result-title", startedAt: 0, windowIdentity: identity),
              policy: .init(actionCooldown: 0.8, postActionTimeout: 12,
                            uncertainStateGraceDuration: 15, uncertainStateGraceSnapshots: 8))
    }

    private func snapshot(_ classification: GameStateClassification, replay: Replay,
                          at time: TimeInterval) -> AutoLevelSnapshot {
        .init(classification: classification,
              runtime: .init(observedAt: time, windowIdentity: identity,
                             frameFingerprint: replay.saved.image.pngSHA256))
    }

    private func load(_ name: String) throws -> Replay {
        let json = try Data(contentsOf: resource("low-result-title-\(name)", extension: "json"))
        let saved = try JSONDecoder().decode(Saved.self, from: json)
        let png = try Data(contentsOf: resource("low-result-title-\(name)", extension: "png"))
        #expect(SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
            == saved.image.pngSHA256)
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == saved.image.width && image.height == saved.image.height)
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
        #expect(rendered)
        let stamp = try RepeatSelectedStampDetector.detectRGBA(
            bytes, width: image.width, height: image.height, bytesPerRow: bytesPerRow
        )
        let original = MissionResultTopActionResolver.resolve(classification: GameStateClassifier.classify(
            observations: saved.ocr.observations, repeatSelectedStampDetection: stamp
        ))
        return Replay(saved: saved, stamp: stamp, original: original)
    }

    private func resource(_ name: String, extension suffix: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: suffix))
    }

    private struct Replay {
        let saved: Saved
        let stamp: RepeatSelectedStampDetection
        let original: GameStateClassification
    }
    private struct Saved: Decodable {
        struct OCR: Decodable { let observations: [OCRTextObservation] }
        struct Image: Decodable { let pngSHA256: String; let width: Int; let height: Int }
        let classification: GameStateClassification
        let ocr: OCR
        let image: Image
    }
    private struct Focused: Decodable {
        let region: NormalizedRect
        let observations: [OCRTextObservation]
    }
    private enum ReplayError: Error { case expectedAction }
}
