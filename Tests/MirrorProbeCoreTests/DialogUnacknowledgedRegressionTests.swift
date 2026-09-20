import Foundation
import Testing
@testable import MirrorProbeCore

/// The retained final capture of `logs/auto-level-20260920-150737.CW2ZaR` (2026-09-20): a
/// 211x468 window's "探索完成 / 關閉" dialog on the 204x445 recognition canvas. The posted press
/// left the frame byte-identical (mean absolute difference 0.0, the user was moving the mouse)
/// and the run stopped with actionDidNotAdvance after the 8 second timeout. The same dialog must
/// now be pressed again.
@Suite("Unacknowledged dialog press from 2026-09-20")
struct DialogUnacknowledgedRegressionTests {
    private let sha256 = "4ed86e8e246b64791b7bd3a087a0f83fa2afc7df494bc3ccd644b34ae2ccf8b3"
    private let identity = AutoLevelWindowIdentity(processID: 97029, windowID: 11402)

    @Test("The retained dialog canvas is pressed again after an unchanged-frame timeout")
    func unchangedDialogIsPressedAgain() throws {
        let frame = try loadRGBAFixture("dialog-unacknowledged-20260920-final", sha256: sha256)
        #expect(frame.width == 204 && frame.height == 445)
        let classification = try AutoLevelVisualClassifier.classifyRGBA(
            frame.bytes, width: frame.width, height: frame.height, bytesPerRow: frame.bytesPerRow
        )
        #expect(classification.state == .wideModalOneButton)
        #expect(classification.allowedActions.map(\.name) == [.pressWideModalTopButton])

        var controller = AutoLevelController(
            session: AutoLevelSessionMetadata(sessionID: "replay", startedAt: 0, windowIdentity: identity),
            policy: AutoLevelPolicy(actionCooldown: 0.8, postActionTimeout: 8)
        )
        let snapshot: (TimeInterval) -> AutoLevelSnapshot = { time in
            AutoLevelSnapshot(
                classification: classification,
                runtime: AutoLevelRuntimeMetadata(
                    observedAt: time, windowIdentity: self.identity,
                    frameFingerprint: "8b0f-frozen-dialog", battleSessionID: nil
                )
            )
        }
        // Times mirror the incident: press at 294.6, unchanged frame at 294.6 and 305.8.
        let first = try #require(action(controller.consume(snapshot(293.4))))
        #expect(first.intent == .pressWideModalTopButton)
        let posted = controller.markActionPosted(first, at: 294.6)
        #expect(posted)
        #expect(controller.consume(snapshot(294.6)) == .wait(.awaitingFrameChange(intent: .pressWideModalTopButton)))
        let retry = try #require(action(controller.consume(snapshot(305.8))))
        #expect(retry.requestID == 2)
        #expect(retry.target == first.target)
        #expect(controller.completedCycles == 0)
    }

    private func action(_ decision: AutoLevelDecision) -> AutoLevelActionRequest? {
        if case let .requestAction(request) = decision { return request }
        return nil
    }
}
