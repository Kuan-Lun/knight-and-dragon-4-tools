import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
@testable import MirrorProbeCore

@Suite("Verified unselected mission-repeat recovery")
struct MissionRepeatSelectionRetryTests {
    @Test("The captured failure has no selected stamp and receives recovery after twelve seconds")
    func capturedIgnoredRepeatReplaysFromItsOriginalPixelsAndOCR() throws {
        let pngURL = try #require(Bundle.module.url(
            forResource: "mission-repeat-ignored-final", withExtension: "png"
        ))
        let jsonURL = try #require(Bundle.module.url(
            forResource: "mission-repeat-ignored-final", withExtension: "json"
        ))
        let capture = try JSONDecoder().decode(SavedCapture.self, from: Data(contentsOf: jsonURL))
        let png = try Data(contentsOf: pngURL)
        let hash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        #expect(hash == capture.image.pngSHA256)
        #expect(hash == "63573baf63525303a89d364bec336b1099f2d5e6c0bbeacf430b075bc53dda02")
        let detection = try detectPNG(pngURL, expectedWidth: capture.image.width,
                                      expectedHeight: capture.image.height)
        #expect(detection.redPixelCount == 0)
        #expect(detection.sampledPixelCount == 7600)
        #expect(detection.isClearlyAbsent)

        let classification = GameStateClassifier.classify(
            observations: capture.ocr.observations,
            repeatSelectedStampDetection: detection
        )
        #expect(classification.state == .missionFailed)
        #expect(classification.allowedActions.map(\.name) == [.selectMissionRepeat])
        let target = AutoLevelActionTarget(try #require(classification.allowedActions.first).target)
        #expect(MissionRepeatSelectionProof.page(in: classification, matching: target) == .experience)
        #expect(classification.evidence.filter { $0.kind == .repeatUnselectedMarker } == [
            absentMarker,
        ])

        var controller = makeController(timeout: 12)
        let origin = snapshot(classification, at: 0.1, fingerprint: hash)
        #expect(controller.consume(origin) == .completedCycle(.init(count: 1, outcome: .failure)))
        let first = try action(controller.consume(origin))
        #expect(first.intent == .selectMissionRepeat)
        #expect(first.repeatSelectionRetryPage == nil)
        let firstPosted = controller.markActionPosted(first, at: 1)
        #expect(firstPosted)
        #expect(controller.consume(snapshot(classification, at: 12.9, fingerprint: hash)) == .wait(
            .awaitingFrameChange(intent: .selectMissionRepeat)
        ))
        let retry = try action(controller.consume(snapshot(classification, at: 13, fingerprint: hash)))
        #expect(retry.requestID == first.requestID + 1)
        #expect(retry.target == first.target)
        #expect(retry.repeatSelectionRetryPage == .experience)
        #expect(controller.completedCycles == 1)
        #expect(controller.actionsIssued == 2)
    }

    @Test("Exactly three posted attempts are permitted for each verified result family and page",
          arguments: [GameState.missionComplete, .missionFailed],
          [MissionSuccessPageIdentity.experience, .loot])
    func repeatRecoveryHasThreeAttemptBound(state: GameState, page: MissionSuccessPageIdentity) throws {
        var controller = makeController()
        let classification = result(state: state, page: page)
        let initial = snapshot(classification, at: 1)
        #expect(controller.consume(initial) == .completedCycle(.init(
            count: 1, outcome: state == .missionComplete ? .success : .failure
        )))
        let first = try action(controller.consume(initial))
        let firstPosted = controller.markActionPosted(first, at: 2)
        #expect(firstPosted)
        #expect(controller.consume(snapshot(classification, at: 4.9)) == .wait(
            .awaitingFrameChange(intent: .selectMissionRepeat)
        ))
        let second = try action(controller.consume(snapshot(classification, at: 5)))
        #expect(second.repeatSelectionRetryPage == page)
        #expect(second.target == first.target)
        let secondPosted = controller.markActionPosted(second, at: 6)
        #expect(secondPosted)
        let third = try action(controller.consume(snapshot(classification, at: 9)))
        #expect(third.requestID == 3)
        #expect(third.repeatSelectionRetryPage == page)
        #expect(third.target == first.target)
        let thirdPosted = controller.markActionPosted(third, at: 10)
        #expect(thirdPosted)
        #expect(controller.consume(snapshot(classification, at: 13)) == .stop(
            .actionDidNotAdvance(intent: .selectMissionRepeat)
        ))
        #expect(controller.consume(snapshot(classification, at: 14)) == .stop(
            .actionDidNotAdvance(intent: .selectMissionRepeat)
        ))
        #expect(controller.actionsIssued == 3)
        #expect(controller.completedCycles == 1)
    }

    @Test("Freshness waits preserve the posted deadline and do not spend repeat attempts")
    func staleObservationDoesNotSpendRetryBudget() throws {
        var controller = makeController()
        let classification = result()
        _ = controller.consume(snapshot(classification, at: 1))
        let first = try action(controller.consume(snapshot(classification, at: 1)))
        let firstPosted = controller.markActionPosted(first, at: 2)
        #expect(firstPosted)
        for time in [5.0, 5.5, 6.0] {
            #expect(controller.consume(snapshot(classification, at: time), allowNewActions: false)
                == .wait(.freshObservationRequired))
            #expect(controller.pendingActionAcknowledgementDeadline == 5)
            #expect(controller.actionsIssued == 1)
        }
        let second = try action(controller.consume(snapshot(classification, at: 7)))
        #expect(second.requestID == 2)
        let secondPosted = controller.markActionPosted(second, at: 8)
        #expect(secondPosted)
        #expect(controller.consume(snapshot(classification, at: 11), allowNewActions: false)
            == .wait(.freshObservationRequired))
        #expect(controller.pendingActionAcknowledgementDeadline == 11)
        #expect(controller.actionsIssued == 2)
        let third = try action(controller.consume(snapshot(classification, at: 12)))
        #expect(third.requestID == 3)
        let thirdPosted = controller.markActionPosted(third, at: 13)
        #expect(thirdPosted)
        #expect(controller.consume(snapshot(classification, at: 16), allowNewActions: false) == .stop(
            .actionDidNotAdvance(intent: .selectMissionRepeat)
        ))
        #expect(controller.actionsIssued == 3)
    }

    @Test("An unposted original or retry request cannot obtain another attempt",
          arguments: [false, true])
    func anUnpostedRequestNeverRetries(unpostedRetry: Bool) throws {
        var controller = makeController()
        let classification = result()
        _ = controller.consume(snapshot(classification, at: 1))
        let first = try action(controller.consume(snapshot(classification, at: 1)))
        if unpostedRetry {
            let posted = controller.markActionPosted(first, at: 2)
            #expect(posted)
            let retry = try action(controller.consume(snapshot(classification, at: 5)))
            #expect(retry.repeatSelectionRetryPage == .experience)
        }
        let timeout = unpostedRetry ? 8.0 : 4.0
        #expect(controller.consume(snapshot(classification, at: timeout)) == .stop(
            .actionDidNotAdvance(intent: .selectMissionRepeat)
        ))
        #expect(controller.actionsIssued == (unpostedRetry ? 2 : 1))
    }

    @Test("Repeat recovery preserves cooldown, maximum actions, runtime, and cycle limits")
    func retriesRespectSessionLimits() throws {
        let classification = result()
        var cooldown = makeController(cooldown: 10)
        _ = cooldown.consume(snapshot(classification, at: 1))
        let first = try action(cooldown.consume(snapshot(classification, at: 1)))
        let posted = cooldown.markActionPosted(first, at: 2)
        #expect(posted)
        #expect(cooldown.consume(snapshot(classification, at: 5)) == .wait(
            .actionCooldown(remaining: 6)
        ))
        #expect(cooldown.actionsIssued == 1)
        #expect(cooldown.pendingActionAcknowledgementDeadline == 5)
        #expect(try action(cooldown.consume(snapshot(classification, at: 11))).requestID == 2)

        for (policy, reason) in [
            (AutoLevelPolicy(postActionTimeout: 3, maxActions: 1),
             AutoLevelStopReason.maximumActionsReached(limit: 1)),
            (AutoLevelPolicy(postActionTimeout: 3, maxRuntime: 5),
             AutoLevelStopReason.maximumRuntimeReached(limit: 5)),
        ] {
            var limited = AutoLevelController(session: session, policy: policy)
            _ = limited.consume(snapshot(classification, at: 1))
            let request = try action(limited.consume(snapshot(classification, at: 1)))
            let marked = limited.markActionPosted(request, at: 2)
            #expect(marked)
            #expect(limited.consume(snapshot(classification, at: 5)) == .stop(reason))
            #expect(limited.actionsIssued == 1)
        }
        var cycleLimited = AutoLevelController(session: session, policy: .init(maxCycles: 1))
        #expect(cycleLimited.consume(snapshot(classification, at: 1)) == .completedCycle(
            .init(count: 1, outcome: .failure)
        ))
        #expect(cycleLimited.consume(snapshot(classification, at: 1)) == .stop(
            .maximumCyclesReached(limit: 1)
        ))
        #expect(cycleLimited.actionsIssued == 0)
    }

    @Test("Both original and current captures must positively prove an absent stamp",
          arguments: [false, true])
    func absenceProofIsRequiredAtBothEnds(missingFromOrigin: Bool) throws {
        let verified = result()
        let withoutPixels = replacing(verified, evidence: verified.evidence.filter {
            $0.kind != .repeatUnselectedMarker
        })
        var controller = makeController()
        let origin = missingFromOrigin ? withoutPixels : verified
        let current = missingFromOrigin ? verified : withoutPixels
        _ = controller.consume(snapshot(origin, at: 1))
        let first = try action(controller.consume(snapshot(origin, at: 1)))
        let posted = controller.markActionPosted(first, at: 2)
        #expect(posted)
        #expect(controller.consume(snapshot(current, at: 5)) == .stop(
            .actionDidNotAdvance(intent: .selectMissionRepeat)
        ))
        #expect(controller.actionsIssued == 1)
    }

    @Test("Timeout recovery cannot cross page, result-family, or exact target boundaries")
    func retryRequiresSamePageStateAndTarget() throws {
        let baseline = result()
        let changedRect = NormalizedRect(x: 0.025, y: 0.236, width: 0.286, height: 0.020)
        let changedAction = repeatAction(rect: changedRect)
        let originalAction = try #require(baseline.allowedActions.first)
        let variants = [
            result(page: .loot),
            result(state: .missionComplete),
            replacing(baseline, actions: [changedAction]),
            replacing(baseline, actions: []),
            replacing(baseline, actions: [originalAction, originalAction]),
        ]
        for current in variants {
            var controller = makeController()
            _ = controller.consume(snapshot(baseline, at: 1))
            let first = try action(controller.consume(snapshot(baseline, at: 1)))
            let posted = controller.markActionPosted(first, at: 2)
            #expect(posted)
            #expect(controller.consume(snapshot(current, at: 5, fingerprint: "different")) == .stop(
                .actionDidNotAdvance(intent: .selectMissionRepeat)
            ))
            #expect(controller.actionsIssued == 1)
        }
    }

    @Test("Only unique trusted pixel absence, page, and repeat-row evidence prove an unselected toggle")
    func proofRejectsMissingAmbiguousAndForgedEvidence() throws {
        let baseline = result()
        let target = AutoLevelActionTarget(try #require(baseline.allowedActions.first).target)
        let row = try #require(baseline.evidence.first { $0.kind == .missionRepeatOption })
        let page = try #require(baseline.evidence.first { $0.kind == .missionExperiencePage })
        #expect(MissionRepeatSelectionProof.page(in: baseline, matching: target) == .experience)

        let invalidEvidence = [
            baseline.evidence.filter { $0.kind != .repeatUnselectedMarker },
            baseline.evidence + [absentMarker],
            baseline.evidence.filter { $0.kind != .repeatUnselectedMarker } + [
                GameStateEvidence(kind: .repeatUnselectedMarker, observation: nil, detail: "no SELECTED OCR"),
            ],
            baseline.evidence.filter { $0.kind != .repeatUnselectedMarker } + [
                GameStateEvidence(kind: .repeatUnselectedMarker, observation: row.observation,
                                  detail: RepeatSelectedStampDetector.absentEvidenceSentinel),
            ],
            baseline.evidence.filter { $0.kind != .missionExperiencePage },
            baseline.evidence + [page],
            baseline.evidence + [row],
            baseline.evidence + [GameStateEvidence(
                kind: .repeatSelectedMarker, observation: nil,
                detail: RepeatSelectedStampDetector.evidenceSentinel
            )],
            baseline.evidence + [GameStateEvidence(
                kind: .lowConfidenceMarker, observation: nil, detail: "uncertain result"
            )],
            baseline.evidence + [GameStateEvidence(
                kind: .invalidObservation, observation: nil, detail: "invalid result"
            )],
            baseline.evidence + [GameStateEvidence(
                kind: .conflictingStateMarkers, observation: nil, detail: "conflicting result"
            )],
        ]
        for evidence in invalidEvidence {
            #expect(MissionRepeatSelectionProof.page(
                in: replacing(baseline, evidence: evidence), matching: target
            ) == nil)
        }
        for confidence in [0.599, 1.001, Double.nan, .infinity] {
            let invalidRow = GameStateEvidence(
                kind: .missionRepeatOption,
                observation: .init(text: "重複進行此任務", rect: repeatRect, confidence: confidence),
                detail: "untrusted repeat row"
            )
            #expect(MissionRepeatSelectionProof.page(in: replacing(
                baseline,
                evidence: baseline.evidence.filter { $0.kind != .missionRepeatOption } + [invalidRow]
            ), matching: target) == nil)
        }
        for mismatchedTarget in [
            AutoLevelActionTarget(name: "other", sourceText: target.sourceText, rect: target.rect),
            AutoLevelActionTarget(name: target.name, sourceText: "重複", rect: target.rect),
            AutoLevelActionTarget(name: target.name, sourceText: target.sourceText,
                                  rect: .init(x: 0.025, y: 0.236, width: 0.286, height: 0.020)),
            AutoLevelActionTarget(name: target.name, sourceText: target.sourceText, rect: target.rect,
                                  point: .init(x: target.point.x + 0.001, y: target.point.y)),
        ] {
            #expect(MissionRepeatSelectionProof.page(in: baseline, matching: mismatchedTarget) == nil)
        }
    }

    @Test("A delayed selected stamp acknowledges a posted repeat retry",
          arguments: [GameState.missionComplete, .missionFailed])
    func selectedStampAdvancesAfterRetry(state: GameState) throws {
        var controller = makeController()
        let classification = result(state: state)
        _ = controller.consume(snapshot(classification, at: 1))
        let first = try action(controller.consume(snapshot(classification, at: 1)))
        let firstPosted = controller.markActionPosted(first, at: 2)
        #expect(firstPosted)
        let retry = try action(controller.consume(snapshot(classification, at: 5)))
        let retryPosted = controller.markActionPosted(retry, at: 6)
        #expect(retryPosted)
        let selected = result(state: state, selected: true)
        let advance = try action(controller.consume(snapshot(selected, at: 7, fingerprint: "selected")))
        #expect(advance.intent == (state == .missionComplete ? .advanceMissionSuccess : .advanceMissionFailure))
        #expect(advance.repeatSelectionRetryPage == nil)
        #expect(controller.completedCycles == 1)
        #expect(controller.actionsIssued == 3)
    }

    @Test("A stamp appearing during retry preflight cancels the stale toggle and preserves its latch",
          arguments: [GameState.missionComplete, .missionFailed])
    func selectedStampCancelsUnpostedRetry(state: GameState) throws {
        var controller = makeController()
        let classification = result(state: state)
        _ = controller.consume(snapshot(classification, at: 1))
        let first = try action(controller.consume(snapshot(classification, at: 1)))
        let firstPosted = controller.markActionPosted(first, at: 2)
        #expect(firstPosted)
        let retry = try action(controller.consume(snapshot(classification, at: 5)))
        let selected = result(state: state, selected: true)
        let cancelled = controller.cancelUnpostedActionAfterForwardResultTransition(
            retry, observedState: selected.state
        )
        #expect(cancelled)
        let stalePost = controller.markActionPosted(retry, at: 5.1)
        #expect(!stalePost)
        #expect(controller.pendingActionAcknowledgementDeadline == nil)
        #expect(controller.consume(snapshot(selected, at: 6), allowNewActions: false) == .wait(
            .freshObservationRequired
        ))
        #expect(controller.consume(snapshot(classification, at: 7)) == .wait(
            .transientState(kind: .missingAction, observationCount: 1)
        ))
        #expect(controller.actionsIssued == 2)
        #expect(controller.completedCycles == 1)
    }

    @Test("Pixel absence requires valid measured pixels and never a merely subthreshold red stamp")
    func absenceIsStricterThanNotSelected() {
        let region = RepeatSelectedStampDetector.measuredRegion
        #expect(RepeatSelectedStampDetection(region: region, redPixelCount: 0,
                                              sampledPixelCount: 100).isClearlyAbsent)
        #expect(RepeatSelectedStampDetection(region: region, redPixelCount: 1,
                                              sampledPixelCount: 1000).isClearlyAbsent)
        for detection in [
            RepeatSelectedStampDetection(region: region, redPixelCount: 2, sampledPixelCount: 1000),
            RepeatSelectedStampDetection(region: region, redPixelCount: 1, sampledPixelCount: 100),
            RepeatSelectedStampDetection(region: region, redPixelCount: 0, sampledPixelCount: 0),
            RepeatSelectedStampDetection(region: region, redPixelCount: -1, sampledPixelCount: 100),
            RepeatSelectedStampDetection(region: region, redPixelCount: 101, sampledPixelCount: 100),
            RepeatSelectedStampDetection(region: .init(x: 0, y: 0, width: 1, height: 1),
                                          redPixelCount: 0, sampledPixelCount: 100),
        ] {
            #expect(!detection.isClearlyAbsent)
        }
    }

    private var identity: AutoLevelWindowIdentity { .init(processID: 11, windowID: 22) }
    private var session: AutoLevelSessionMetadata {
        .init(sessionID: "repeat-retry", startedAt: 0, windowIdentity: identity)
    }
    private var repeatRect: NormalizedRect {
        .init(x: 0.0246305439, y: 0.2359550561, width: 0.2857142857, height: 0.0202247191)
    }
    private var absentMarker: GameStateEvidence {
        .init(kind: .repeatUnselectedMarker, observation: nil,
              detail: RepeatSelectedStampDetector.absentEvidenceSentinel)
    }

    private func makeController(timeout: Double = 3, cooldown: Double = 0) -> AutoLevelController {
        .init(session: session, policy: .init(actionCooldown: cooldown, postActionTimeout: timeout))
    }

    private func snapshot(
        _ classification: GameStateClassification,
        at time: Double,
        fingerprint: String = "unchanged-result"
    ) -> AutoLevelSnapshot {
        .init(classification: classification, runtime: .init(
            observedAt: time, windowIdentity: identity, frameFingerprint: fingerprint
        ))
    }

    private func result(
        state: GameState = .missionFailed,
        page: MissionSuccessPageIdentity = .experience,
        selected: Bool = false
    ) -> GameStateClassification {
        let observations = [
            OCRTextObservation(text: state == .missionComplete ? "任務完成！" : "任務失敗",
                               rect: .init(x: 0.39, y: 0.105, width: 0.21, height: 0.024), confidence: 1),
            OCRTextObservation(text: page == .experience ? "獲得經驗值" : "獲得拾得物",
                               rect: .init(x: 0.778, y: 0.146, width: 0.192, height: 0.021), confidence: 1),
            OCRTextObservation(text: ">>",
                               rect: .init(x: 0.025, y: 0.198, width: 0.045, height: 0.011), confidence: 0.3),
            OCRTextObservation(text: "重複進行此任務", rect: repeatRect, confidence: 1),
        ]
        return MissionResultTopActionResolver.resolve(classification: GameStateClassifier.classify(
            observations: observations,
            repeatSelectedStampDetection: .init(
                region: RepeatSelectedStampDetector.measuredRegion,
                redPixelCount: selected ? 20 : 0,
                sampledPixelCount: 100
            )
        ))
    }

    private func repeatAction(rect: NormalizedRect) -> AllowedGameAction {
        .init(name: .selectMissionRepeat, target: .init(
            name: .missionRepeatOption, sourceText: "重複進行此任務", rect: rect, point: rect.center
        ))
    }

    private func replacing(
        _ classification: GameStateClassification,
        evidence: [GameStateEvidence]? = nil,
        actions: [AllowedGameAction]? = nil
    ) -> GameStateClassification {
        .init(state: classification.state, evidence: evidence ?? classification.evidence,
              allowedActions: actions ?? classification.allowedActions,
              policyGatedActions: classification.policyGatedActions)
    }

    private func action(_ decision: AutoLevelDecision) throws -> AutoLevelActionRequest {
        guard case let .requestAction(request) = decision else {
            Issue.record("Expected a request, received \(decision)")
            throw ReplayError.expectedAction
        }
        return request
    }

    private func detectPNG(
        _ url: URL, expectedWidth: Int, expectedHeight: Int
    ) throws -> RepeatSelectedStampDetection {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == expectedWidth)
        #expect(image.height == expectedHeight)
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
        guard rendered else { throw ReplayError.cannotRender }
        return try RepeatSelectedStampDetector.detectRGBA(
            bytes, width: image.width, height: image.height, bytesPerRow: bytesPerRow
        )
    }

    private struct SavedCapture: Decodable {
        struct Image: Decodable {
            let width: Int
            let height: Int
            let pngSHA256: String
        }
        struct OCR: Decodable { let observations: [OCRTextObservation] }
        let image: Image
        let ocr: OCR
    }

    private enum ReplayError: Error {
        case expectedAction
        case cannotRender
    }
}
