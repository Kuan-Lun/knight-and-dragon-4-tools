import Testing
@testable import MirrorProbeCore

@Suite("Auto-level delayed observation sequence")
struct AutoLevelStaleObservationReplayTests {
    @Test("September 9 delayed battle ACK and modal require fresh pixels before the next post")
    func delayedBattleThenModal() throws {
        let identity = AutoLevelWindowIdentity(processID: 91507, windowID: 65194)
        var controller = AutoLevelController(
            session: .init(sessionID: "delayed-ocr", startedAt: 0, windowIdentity: identity),
            policy: .init(postActionTimeout: 12)
        )
        var recovery = AutoLevelObservationFreshnessRecovery()
        func snapshot(_ state: GameState, at capturedAt: Double, fingerprint: String) -> AutoLevelSnapshot {
            let rect = NormalizedRect(x: 0.108, y: 0.537, width: 0.783, height: 0.04)
            return AutoLevelSnapshot(
                classification: .init(state: state, evidence: [], allowedActions: state == .wideModalOneButton ? [
                    .init(name: .pressWideModalTopButton, target: .init(
                        name: .wideModalTopButton, sourceText: "<measured-wide-modal-primary-button>",
                        rect: rect, point: rect.center
                    )),
                ] : []),
                runtime: .init(
                    observedAt: capturedAt, windowIdentity: identity, frameFingerprint: fingerprint,
                    battleSessionID: nil, allAutoStatus: state == .battle ? .active : .unknown,
                    battleStatus: state == .battle ? .inProgress : .unknown
                )
            )
        }
        guard case let .requestAction(prior) = controller.consume(snapshot(
            .wideModalOneButton, at: 1122.4446043332573, fingerprint: "prior-modal"
        )) else {
            Issue.record("Expected the preceding modal request")
            return
        }
        // Model the preceding successful input before the logged post-capture timestamp.
        let posted = controller.markActionPosted(prior, at: 1128)
        #expect(posted)
        #expect(controller.pendingActionAcknowledgementDeadline == 1140)

        // Capture times come from run 043306.LgKS8M; processing times are rounded from
        // its event timestamps. Slow processing must not rewrite either capture timestamp.
        let battleCapturedAt = 1129.9734212083276
        let battleFreshness = recovery.evaluate(capturedAt: battleCapturedAt, now: 1166)
        #expect(battleFreshness == .recapture(attempt: 1))
        #expect(controller.consume(snapshot(.battle, at: battleCapturedAt, fingerprint: "old-battle"),
                                   allowNewActions: battleFreshness == .fresh) == .wait(.battleInProgress))
        #expect(controller.pendingActionAcknowledgementDeadline == nil)

        let modalCapturedAt = 1173.050503458362
        let modalFreshness = recovery.evaluate(capturedAt: modalCapturedAt, now: 1228)
        #expect(modalFreshness == .recapture(attempt: 2))
        #expect(controller.consume(snapshot(.wideModalOneButton, at: modalCapturedAt, fingerprint: "old-modal"),
                                   allowNewActions: modalFreshness == .fresh) == .wait(.freshObservationRequired))
        #expect(controller.actionsIssued == 1)

        let fresh = recovery.evaluate(capturedAt: 1236, now: 1236.5)
        #expect(fresh == .fresh)
        guard case let .requestAction(next) = controller.consume(
            snapshot(.wideModalOneButton, at: 1236, fingerprint: "fresh-modal"),
            allowNewActions: fresh == .fresh
        ) else {
            Issue.record("Only the new, fresh modal may authorize the next input")
            return
        }
        #expect(next.requestID == 2)
        #expect(next.frameFingerprint == "fresh-modal")
        let freshPost = controller.markActionPosted(next, at: 1237)
        #expect(freshPost)
        #expect(controller.pendingActionAcknowledgementDeadline == 1249)
    }
}
