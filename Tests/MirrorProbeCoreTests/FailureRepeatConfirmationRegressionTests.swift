import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
@testable import MirrorProbeCore

@Suite("Failure repeat-confirmation regression")
struct FailureRepeatConfirmationRegressionTests {
    @Test("Both captured unselected failure frames retain the same repeat target after hue filtering")
    func capturedPairNoLongerBecomesUnknown() throws {
        let before = try fixture("before")
        let final = try fixture("final")
        #expect(before.saved.classification.state == .missionFailed)
        #expect(final.saved.classification.state == .unknown)
        #expect(final.saved.classification.evidence.map(\.kind) == [
            .missionFailedTitle, .missionRepeatOption, .lowConfidenceMarker,
        ])
        for capture in [before, final] {
            #expect(capture.stamp.redPixelCount == 0)
            #expect(capture.stamp.sampledPixelCount == 7600)
            #expect(capture.stamp.isClearlyAbsent)
            #expect(capture.classification.state == .missionFailed)
            #expect(capture.classification.allowedActions.map(\.name) == [.selectMissionRepeat])
            #expect(!capture.classification.evidence.contains { $0.kind == .lowConfidenceMarker })
            let target = AutoLevelActionTarget(try #require(capture.classification.allowedActions.first).target)
            #expect(MissionRepeatSelectionProof.page(in: capture.classification, matching: target) == .experience)
        }
        #expect(before.classification.allowedActions == final.classification.allowedActions)
    }

    @Test("An ambiguous confirmation reobserves the same unposted request without spending a posted attempt",
          arguments: [false, true])
    func recoversOriginalRequestWithinItsDeadline(alreadyIssuedRetry: Bool) throws {
        let before = try fixture("before")
        let final = try fixture("final")
        var controller = makeController()
        let (request, issuedAt) = try issueRequest(before, controller: &controller, retry: alreadyIssuedRetry)
        let issuedCount = controller.actionsIssued
        var recovery = AutoLevelForegroundActivationRetryState()

        let focusRetry = recovery.recordUnpostedFocusFailure()
        #expect(focusRetry == .retry(nextAttempt: 2, delayMilliseconds: 1_000))
        let observationRetry = recovery.recordUnpostedResultObservationFailure(
            intent: request.intent, classification: final.saved.classification, inputWasPosted: false
        )
        #expect(observationRetry == .retry(nextAttempt: 3, delayMilliseconds: 1_000))
        #expect(controller.actionsIssued == issuedCount)
        #expect(controller.pendingActionAcknowledgementDeadline == nil)
        // Recovery only grants another observation. The old unknown frame still has no action
        // or matching page, and must never be fed into the controller to reissue the request.
        #expect(final.saved.classification.allowedActions.isEmpty)
        #expect(!AutoLevelForegroundActivationRetryState.resultPageMatchesOriginal(
            intent: request.intent, expectedPage: .experience, classification: final.saved.classification
        ))

        let restored = snapshot(final, at: issuedAt + 2)
        var freshness = AutoLevelObservationFreshnessRecovery()
        #expect(freshness.evaluate(capturedAt: issuedAt + 2, now: issuedAt + 2.1) == .fresh)
        #expect(restored.classification.state == request.observedState)
        #expect(restored.actionCandidates == [.init(intent: request.intent, target: request.target)])
        #expect(AutoLevelForegroundActivationRetryState.resultPageMatchesOriginal(
            intent: request.intent, expectedPage: .experience, classification: restored.classification
        ))
        #expect(MissionRepeatSelectionProof.page(
            in: restored.classification, matching: request.target
        ) == .experience)
        let posted = controller.markActionPosted(request, at: issuedAt + 2.1)
        let postedTwice = controller.markActionPosted(request, at: issuedAt + 2.2)
        #expect(posted)
        #expect(!postedTwice)
        #expect(controller.pendingActionAcknowledgementDeadline == issuedAt + 14.1)
        #expect(controller.actionsIssued == issuedCount)
        #expect(controller.completedCycles == 1)
    }

    @Test("Confirmation recovery keeps the request's original twelve-second input deadline",
          arguments: [false, true])
    func recoveryDoesNotRenewAuthorization(alreadyIssuedRetry: Bool) throws {
        let before = try fixture("before")
        let final = try fixture("final")
        var controller = makeController()
        let (request, issuedAt) = try issueRequest(before, controller: &controller, retry: alreadyIssuedRetry)
        let issuedCount = controller.actionsIssued
        var recovery = AutoLevelForegroundActivationRetryState()
        let firstRetry = recovery.recordUnpostedResultObservationFailure(
            intent: request.intent, classification: final.saved.classification, inputWasPosted: false
        )
        #expect(firstRetry == .retry(nextAttempt: 2, delayMilliseconds: 1_000))
        let secondRetry = recovery.recordUnpostedResultObservationFailure(
            intent: request.intent, classification: final.saved.classification, inputWasPosted: false
        )
        #expect(secondRetry == .retry(nextAttempt: 3, delayMilliseconds: 1_000))
        let exhausted = recovery.recordUnpostedResultObservationFailure(
            intent: request.intent, classification: final.saved.classification, inputWasPosted: false
        )
        #expect(exhausted == .exhausted(attempts: 3))
        #expect(recovery.recordUnpostedFocusFailure() == .exhausted(attempts: 3))

        var justBeforeDeadline = controller
        let justInTime = justBeforeDeadline.markActionPosted(request, at: issuedAt + 11.999)
        let expired = controller.markActionPosted(request, at: issuedAt + 12)
        let stillExpired = controller.markActionPosted(request, at: issuedAt + 13)
        #expect(justInTime)
        #expect(!expired)
        #expect(!stillExpired)
        #expect(controller.actionsIssued == issuedCount)
        #expect(controller.pendingActionAcknowledgementDeadline == nil)
    }

    @Test("A selected confirmation cancels either the initial repeat or an already-issued retry",
          arguments: [false, true])
    func selectedConfirmationCancelsWithoutPosting(alreadyIssuedRetry: Bool) throws {
        let before = try fixture("before")
        var controller = makeController()
        let (request, issuedAt) = try issueRequest(before, controller: &controller, retry: alreadyIssuedRetry)
        let issuedCount = controller.actionsIssued
        let selected = MissionResultTopActionResolver.resolve(classification: GameStateClassifier.classify(
            observations: before.saved.ocr.observations,
            repeatSelectedStampDetection: .init(
                region: RepeatSelectedStampDetector.measuredRegion,
                redPixelCount: 1800, sampledPixelCount: 8968
            )
        ))
        #expect(selected.state == .missionFailedRepeatSelected)
        #expect(selected.allowedActions.map(\.name) == [.advanceMissionComplete])
        var recovery = AutoLevelForegroundActivationRetryState()
        #expect(recovery.recordUnpostedResultObservationFailure(
            intent: request.intent, classification: selected, inputWasPosted: false
        ) == nil)
        let cancelled = controller.cancelUnpostedActionAfterForwardResultTransition(
            request, observedState: selected.state
        )
        #expect(cancelled)
        let stalePost = controller.markActionPosted(request, at: issuedAt + 1)
        #expect(!stalePost)
        #expect(controller.pendingActionAcknowledgementDeadline == nil)
        #expect(controller.consume(AutoLevelSnapshot(
            classification: selected,
            runtime: .init(observedAt: issuedAt + 1, windowIdentity: identity,
                           frameFingerprint: "selected-confirmation")
        ), allowNewActions: false) == .wait(.freshObservationRequired))
        #expect(controller.consume(snapshot(before, at: issuedAt + 2)) == .wait(
            .transientState(kind: .missingAction, observationCount: 1)
        ))
        #expect(controller.actionsIssued == issuedCount)
        #expect(controller.completedCycles == 1)
    }

    @Test("Restoration must retain the original known result page even when state and coordinates agree",
          arguments: [AutoLevelActionIntent.selectMissionRepeat, .advanceMissionFailure, .advanceMissionSuccess])
    func restoredPageMustMatchOriginal(intent: AutoLevelActionIntent) throws {
        let final = try fixture("final").classification
        let pageMissing = GameStateClassification(
            state: final.state,
            evidence: final.evidence.filter { $0.kind != .missionExperiencePage },
            allowedActions: final.allowedActions
        )
        let pageChanged = GameStateClassification(
            state: final.state,
            evidence: pageMissing.evidence + [GameStateEvidence(
                kind: .missionLootPage,
                observation: .init(text: "獲得拾得物",
                                   rect: .init(x: 0.778, y: 0.146, width: 0.192, height: 0.021), confidence: 1),
                detail: "different page with the same repeat target"
            )],
            allowedActions: final.allowedActions
        )
        #expect(AutoLevelForegroundActivationRetryState.resultPageMatchesOriginal(
            intent: intent, expectedPage: .experience, classification: final
        ))
        for changed in [pageMissing, pageChanged] {
            #expect(changed.state == final.state)
            #expect(changed.allowedActions == final.allowedActions)
            #expect(!AutoLevelForegroundActivationRetryState.resultPageMatchesOriginal(
                intent: intent, expectedPage: .experience, classification: changed
            ))
        }
        #expect(AutoLevelForegroundActivationRetryState.resultPageMatchesOriginal(
            intent: intent, expectedPage: nil, classification: final
        ) == (intent != .advanceMissionSuccess))
    }

    private let identity = AutoLevelWindowIdentity(processID: 91507, windowID: 65194)

    private func makeController() -> AutoLevelController {
        .init(session: .init(sessionID: "failure-confirmation", startedAt: 0, windowIdentity: identity),
              policy: .init(postActionTimeout: 12))
    }

    private func issueRequest(
        _ before: Capture, controller: inout AutoLevelController, retry: Bool
    ) throws -> (AutoLevelActionRequest, TimeInterval) {
        #expect(controller.consume(snapshot(before, at: 100)) == .completedCycle(
            .init(count: 1, outcome: .failure)
        ))
        let first = try request(controller.consume(snapshot(before, at: 100)))
        #expect(first.intent == .selectMissionRepeat)
        #expect(first.repeatSelectionRetryPage == nil)
        guard retry else { return (first, 100) }
        let posted = controller.markActionPosted(first, at: 101)
        #expect(posted)
        let second = try request(controller.consume(snapshot(before, at: 113)))
        #expect(second.target == first.target)
        #expect(second.repeatSelectionRetryPage == .experience)
        #expect(second.requestID == first.requestID + 1)
        return (second, 113)
    }

    private func request(_ decision: AutoLevelDecision) throws -> AutoLevelActionRequest {
        guard case let .requestAction(request) = decision else {
            Issue.record("Expected a repeat request, received \(decision)")
            throw FixtureError.missingRequest
        }
        return request
    }

    private func snapshot(_ capture: Capture, at time: TimeInterval) -> AutoLevelSnapshot {
        .init(classification: capture.classification,
              runtime: .init(observedAt: time, windowIdentity: identity,
                             frameFingerprint: capture.saved.image.pngSHA256))
    }

    private func fixture(_ name: String) throws -> Capture {
        let jsonURL = try #require(Bundle.module.url(
            forResource: "failure-repeat-confirmation-\(name)", withExtension: "json"
        ))
        let saved = try JSONDecoder().decode(SavedCapture.self, from: Data(contentsOf: jsonURL))
        let pngURL = try #require(Bundle.module.url(
            forResource: "failure-repeat-confirmation-\(name)", withExtension: "png"
        ))
        let png = try Data(contentsOf: pngURL)
        let hash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        #expect(hash == saved.image.pngSHA256)
        #expect(hash == (name == "before"
            ? "a9516cecc2e2f9f7b9e54c92018dda546a0434357489ce81ae11b2bbf9064eeb"
            : "f766c7b9cee4b90b781e7ed59410193e4e781ce3a48092d9fead7306732c89aa"))
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == saved.image.width)
        #expect(image.height == saved.image.height)
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
        #expect(rendered)
        guard rendered else { throw FixtureError.cannotRender }
        let stamp = try RepeatSelectedStampDetector.detectRGBA(
            bytes, width: image.width, height: image.height, bytesPerRow: bytesPerRow
        )
        let classification = MissionResultTopActionResolver.resolve(classification: GameStateClassifier.classify(
            observations: saved.ocr.observations, repeatSelectedStampDetection: stamp
        ))
        return Capture(saved: saved, stamp: stamp, classification: classification)
    }

    private struct Capture {
        let saved: SavedCapture
        let stamp: RepeatSelectedStampDetection
        let classification: GameStateClassification
    }

    private struct SavedCapture: Decodable {
        struct OCR: Decodable { let observations: [OCRTextObservation] }
        struct Image: Decodable {
            let pngSHA256: String
            let width: Int
            let height: Int
        }
        let classification: GameStateClassification
        let ocr: OCR
        let image: Image
    }

    private enum FixtureError: Error {
        case missingRequest
        case cannotRender
    }
}
