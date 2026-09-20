import Foundation
import Testing
@testable import MirrorProbeCore

/// The retained final capture of `logs/auto-level-20260920-165503.92enHa` (2026-09-20): a
/// 211x468 window's frozen boss battle on the 204x445 canvas, 26 cycles in. The stall monitor
/// confirmed 5.5 seconds without change, the posted retreat left the frame byte-identical for
/// the next 10 seconds (the user was moving the mouse), and the run stopped with
/// actionDidNotAdvance(requestRetreat). The same retreat must now be posted again.
@Suite("Unacknowledged stalled-battle retreat from 2026-09-20")
struct RetreatUnacknowledgedRegressionTests {
    private let sha256 = "3538231ce615e1e2b6b644fce1c3a0077f34fd6978312ce35200bb587016d0a6"
    private let identity = AutoLevelWindowIdentity(processID: 97029, windowID: 11402)

    @Test("The retained frozen battle canvas retreats again after an unchanged-frame timeout")
    func frozenBattleRetreatsAgain() throws {
        let frame = try loadRGBAFixture("retreat-unacknowledged-20260920-final", sha256: sha256)
        #expect(frame.width == 204 && frame.height == 445)
        let classification = try AutoLevelVisualClassifier.classifyRGBA(
            frame.bytes, width: frame.width, height: frame.height, bytesPerRow: frame.bytesPerRow
        )
        #expect(classification.state == .battle)
        #expect(classification.allowedActions.isEmpty)
        #expect(VisualBattleEvidence.hasTrustedRetreat(in: classification))
        let retreat = try #require(classification.policyGatedActions.first)
        #expect(retreat.name == .openBattleRetreatConfirmation)

        var controller = AutoLevelController(
            session: AutoLevelSessionMetadata(sessionID: "replay", startedAt: 0, windowIdentity: identity),
            policy: AutoLevelPolicy(actionCooldown: 0.8, postActionTimeout: 8)
        )
        // Stalled-defeat status is temporal runtime metadata proven by the incident's monitor.
        let snapshot: (TimeInterval) -> AutoLevelSnapshot = { time in
            AutoLevelSnapshot(
                classification: classification,
                runtime: AutoLevelRuntimeMetadata(
                    observedAt: time, windowIdentity: self.identity,
                    frameFingerprint: "05794bb4-frozen-battle", battleSessionID: "b-16200",
                    allAutoStatus: .active, battleStatus: .stalledAfterDefeat
                )
            )
        }
        // Times mirror the incident: request at 622.6, posted 623.9, unchanged at 623.9 and 635.4.
        let first = try #require(action(controller.consume(snapshot(622.6))))
        #expect(first.intent == .requestRetreat)
        #expect(first.target.rect == VisualBattleEvidence.measuredRetreatRect)
        let posted = controller.markActionPosted(first, at: 623.9)
        #expect(posted)
        #expect(controller.consume(snapshot(623.9)) == .wait(.awaitingFrameChange(intent: .requestRetreat)))
        let retry = try #require(action(controller.consume(snapshot(635.4))))
        #expect(retry.requestID == 2)
        #expect(retry.intent == .requestRetreat)
        #expect(retry.target == first.target)
    }

    private func action(_ decision: AutoLevelDecision) -> AutoLevelActionRequest? {
        if case let .requestAction(request) = decision { return request }
        return nil
    }
}
