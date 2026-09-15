import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
@testable import MirrorProbeCore

@Suite("Transient result-title occlusion regression")
struct ResultTitleOcclusionRegressionTests {
    private let identity = AutoLevelWindowIdentity(processID: 91507, windowID: 65194)

    @Test("The unobscured captured EXP page resolves using actual red-stamp pixels")
    func unobscuredExperiencePage() throws {
        let before = try fixture("before")
        let stamp = try detectStamp("before", expectedSHA256: before.image.pngSHA256)
        #expect(stamp.isPresent)
        #expect(stamp.redPixelRatio > 0.10)
        let classification = classify(before, stamp: stamp)

        #expect(classification.state == .missionCompleteRepeatSelected)
        #expect(MissionSuccessPageIdentity.resolve(in: classification) == .experience)
        #expect(classification.allowedActions == before.classification.allowedActions)
        #expect(classification.allowedActions.map(\.name) == [.advanceMissionComplete])
        #expect(classification.evidence.contains {
            $0.kind == .repeatSelectedMarker && $0.observation == nil
                && $0.detail.contains(RepeatSelectedStampDetector.evidenceSentinel)
        })
    }

    @Test("The real obscured title remains unknown even with the intact EXP header and red stamp")
    func obscuredTitleMustNotAuthorizeAnyAction() throws {
        let obscured = try fixture("confirmation")
        let stamp = try detectStamp("confirmation", expectedSHA256: obscured.image.pngSHA256)
        #expect(obscured.ocr.observations.contains { $0.text == "任" })
        #expect(!obscured.ocr.observations.contains { $0.text == "任務完成！" })
        #expect(obscured.ocr.observations.contains { $0.text == "獲得經驗值" })
        #expect(obscured.ocr.observations.contains { $0.text == "重複進行此任務" })
        #expect(stamp.isPresent)

        for evidence in [nil, stamp] as [RepeatSelectedStampDetection?] {
            let classification = classify(obscured, stamp: evidence)
            #expect(classification.state == .unknown)
            #expect(classification.allowedActions.isEmpty)
            #expect(classification.policyGatedActions.isEmpty)
            #expect(MissionSuccessPageIdentity.resolve(in: classification) == nil)
        }
    }

    @Test("A pending unposted result request survives an unknown confirmation and posts only once after restoration")
    func restoresOriginalUnpostedRequestWithoutReissue() throws {
        let before = try fixture("before")
        let obscured = try fixture("confirmation")
        var controller = makeController()
        let request = try issueResultRequest(before, controller: &controller)
        var retry = AutoLevelForegroundActivationRetryState()

        // Focus and result-observation failures share the same original three-attempt budget.
        let focusRetry = retry.recordUnpostedFocusFailure()
        #expect(focusRetry == .retry(nextAttempt: 2, delayMilliseconds: 1_000))
        let resultRetry = retry.recordUnpostedResultObservationFailure(
            intent: request.intent, classification: obscured.classification, inputWasPosted: false
        )
        #expect(resultRetry == .retry(nextAttempt: 3, delayMilliseconds: 1_000))
        #expect(controller.actionsIssued == 1)
        #expect(controller.pendingActionAcknowledgementDeadline == nil)

        // Preflight recovery never feeds unknown or restored snapshots into consume().
        // The fresh restored frame must independently match the same known page and target.
        verifyFreshRestoration(before, request: request, capturedAt: 102, now: 102.1)
        #expect(retry.currentAttempt == 3)
        #expect(controller.actionsIssued == 1)
        #expect(controller.completedCycles == 1)
        let posted = controller.markActionPosted(request, at: 102.1)
        let postedTwice = controller.markActionPosted(request, at: 102.2)
        #expect(posted)
        #expect(!postedTwice)
        #expect(controller.pendingActionAcknowledgementDeadline == 114.1)
    }

    @Test("Repeated fresh confirmation checks do not renew the original twelve-second posting deadline")
    func restorationDoesNotExtendOriginalDeadline() throws {
        let before = try fixture("before")
        let obscured = try fixture("confirmation")
        var controller = makeController()
        let request = try issueResultRequest(before, controller: &controller)
        var retry = AutoLevelForegroundActivationRetryState()
        let resultRetry = retry.recordUnpostedResultObservationFailure(
            intent: request.intent, classification: obscured.classification, inputWasPosted: false
        )
        #expect(resultRetry == .retry(nextAttempt: 2, delayMilliseconds: 1_000))
        let focusRetry = retry.recordUnpostedFocusFailure()
        #expect(focusRetry == .retry(nextAttempt: 3, delayMilliseconds: 1_000))

        for time in [102.0, 106.0, 111.9] {
            verifyFreshRestoration(before, request: request, capturedAt: time, now: time + 0.01)
            #expect(retry.currentAttempt == 3)
            #expect(controller.actionsIssued == 1)
            #expect(controller.pendingActionAcknowledgementDeadline == nil)
        }

        var justBeforeDeadline = controller
        let postedBeforeDeadline = justBeforeDeadline.markActionPosted(request, at: 111.999)
        let postedAtDeadline = controller.markActionPosted(request, at: 112)
        let postedAfterDeadline = controller.markActionPosted(request, at: 112.001)
        #expect(postedBeforeDeadline)
        #expect(!postedAtDeadline)
        #expect(!postedAfterDeadline)
        #expect(controller.actionsIssued == 1)
        #expect(controller.pendingActionAcknowledgementDeadline == nil)
    }

    private func verifyFreshRestoration(
        _ before: ResultTitleOcclusionFixture,
        request: AutoLevelActionRequest,
        capturedAt: TimeInterval,
        now: TimeInterval
    ) {
        let restored = snapshot(before, at: capturedAt)
        var freshness = AutoLevelObservationFreshnessRecovery()
        #expect(freshness.evaluate(capturedAt: capturedAt, now: now) == .fresh)
        #expect(restored.runtime.windowIdentity == identity)
        #expect(restored.classification.state == request.observedState)
        #expect(MissionSuccessPageIdentity.resolve(in: restored.classification) == .experience)
        #expect(restored.classification.policyGatedActions.isEmpty)
        #expect(restored.actionCandidates == [.init(intent: request.intent, target: request.target)])
    }

    private func makeController() -> AutoLevelController {
        AutoLevelController(
            session: .init(sessionID: "result-title-occlusion", startedAt: 0, windowIdentity: identity),
            policy: .init(postActionTimeout: 12)
        )
    }

    private func issueResultRequest(
        _ before: ResultTitleOcclusionFixture,
        controller: inout AutoLevelController
    ) throws -> AutoLevelActionRequest {
        #expect(controller.consume(snapshot(before, at: 100)) == .completedCycle(
            .init(count: 1, outcome: .success)
        ))
        let decision = controller.consume(snapshot(before, at: 100))
        guard case let .requestAction(request) = decision else {
            throw ResultTitleOcclusionTestError.missingResultRequest
        }
        #expect(request.intent == .advanceMissionSuccess)
        return request
    }

    private func snapshot(_ fixture: ResultTitleOcclusionFixture, at time: TimeInterval)
        -> AutoLevelSnapshot
    {
        AutoLevelSnapshot(
            classification: fixture.classification,
            runtime: .init(
                observedAt: time, windowIdentity: identity,
                frameFingerprint: fixture.image.pngSHA256
            )
        )
    }

    private func classify(
        _ fixture: ResultTitleOcclusionFixture,
        stamp: RepeatSelectedStampDetection?
    ) -> GameStateClassification {
        MissionResultTopActionResolver.resolve(classification: GameStateClassifier.classify(
            observations: fixture.ocr.observations,
            repeatSelectedStampDetection: stamp
        ))
    }

    private func fixture(_ name: String) throws -> ResultTitleOcclusionFixture {
        let url = try #require(Bundle.module.url(
            forResource: "result-title-occlusion-\(name)", withExtension: "json"
        ))
        return try JSONDecoder().decode(ResultTitleOcclusionFixture.self, from: Data(contentsOf: url))
    }

    private func detectStamp(_ name: String, expectedSHA256: String)
        throws -> RepeatSelectedStampDetection
    {
        let url = try #require(Bundle.module.url(
            forResource: "result-title-occlusion-\(name)", withExtension: "png"
        ))
        let data = try Data(contentsOf: url)
        #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == expectedSHA256)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let bytesPerRow = image.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * image.height)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let address = buffer.baseAddress,
                  let context = CGContext(
                    data: address, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo
                  )
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        #expect(rendered)
        return try RepeatSelectedStampDetector.detectRGBA(
            bytes, width: image.width, height: image.height, bytesPerRow: bytesPerRow
        )
    }
}

private struct ResultTitleOcclusionFixture: Decodable {
    struct OCR: Decodable { let observations: [OCRTextObservation] }
    struct Image: Decodable { let pngSHA256: String }
    let classification: GameStateClassification
    let ocr: OCR
    let image: Image
}

private enum ResultTitleOcclusionTestError: Error {
    case missingResultRequest
}
