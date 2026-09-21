import Testing
@testable import MirrorProbeCore

enum UnpostedCancellationRejectionCase: String, CaseIterable, Sendable {
    case noPending
    case wrongRequestID
    case differentRequest
    case nonSelectIntent
    case observedUnknown
    case observedInventoryFull
    case observedBattle
    case observedDefeat
    case observedMissionComplete
    case observedMissionFailed
    case observedSelectedFailure
}

@Suite("AutoLevelController")
struct AutoLevelControllerTests {
    @Test("Classifier actions adapt to result-specific neutral intents")
    func adaptsClassifierActionsByState() {
        let success = makeSnapshot(
            state: .missionCompleteRepeatSelected,
            time: 1,
            fingerprint: "success",
            actions: [gameAction(.advanceMissionComplete)]
        )
        let failure = makeSnapshot(
            state: .missionFailedRepeatSelected,
            time: 1,
            fingerprint: "failure",
            actions: [gameAction(.advanceMissionComplete)]
        )

        #expect(success.actionCandidates.map(\.intent) == [.advanceMissionSuccess])
        #expect(failure.actionCandidates.map(\.intent) == [.advanceMissionFailure])
    }

    @Test("A recognized battle prompt requests exactly its close action")
    func closesBattlePrompt() {
        var controller = makeController()
        let decision = controller.consume(makeSnapshot(
            state: .battleEncounterPrompt,
            time: 1,
            fingerprint: "prompt",
            actions: [gameAction(.closeBattlePrompt)]
        ))

        let request = requireAction(decision)
        #expect(request?.intent == .closeBattlePrompt)
        #expect(request?.requestID == 1)
        #expect(controller.actionsIssued == 1)
    }

    @Test("A geometry-only modal closes and resumes the same result without recounting it")
    func closesGeometryModalWithoutRecountingResult() {
        var controller = makeController(policy: policy(actionCooldown: 0))
        let result = makeSnapshot(
            state: .missionCompleteRepeatSelected,
            time: 1,
            fingerprint: "result-exp",
            actions: [gameAction(.advanceMissionComplete)]
        )

        #expect(controller.consume(result) == .completedCycle(.init(
            count: 1,
            outcome: .success
        )))
        #expect(requireAction(controller.consume(makeSnapshot(
            state: .missionCompleteRepeatSelected,
            time: 2,
            fingerprint: "result-exp",
            actions: [gameAction(.advanceMissionComplete)]
        )))?.intent == .advanceMissionSuccess)

        let promptDecision = controller.consume(makeSnapshot(
            state: .wideModalOneButton,
            time: 3,
            fingerprint: "skill-prompt",
            actions: [gameAction(.pressWideModalTopButton)]
        ))
        #expect(requireAction(promptDecision)?.intent == .pressWideModalTopButton)

        let resumedDecision = controller.consume(makeSnapshot(
            state: .missionCompleteRepeatSelected,
            time: 4,
            fingerprint: "result-exp-resumed",
            actions: [gameAction(.advanceMissionComplete)]
        ))
        #expect(requireAction(resumedDecision)?.intent == .advanceMissionSuccess)
        #expect(controller.completedCycles == 1)
        #expect(controller.actionsIssued == 3)
    }

    @Test("Consecutive geometry-only modals remain actionable without OCR identity")
    func consecutiveGeometryModalsRemainActionable() {
        var sameLayout = makeController(policy: policy(actionCooldown: 0))
        #expect(requireAction(sameLayout.consume(makeSnapshot(
            state: .wideModalOneButton,
            time: 1,
            fingerprint: "one-a",
            actions: [gameAction(.pressWideModalTopButton)]
        )))?.intent == .pressWideModalTopButton)
        #expect(requireAction(sameLayout.consume(makeSnapshot(
            state: .wideModalOneButton,
            time: 2,
            fingerprint: "one-b",
            actions: [gameAction(.pressWideModalTopButton)]
        )))?.intent == .pressWideModalTopButton)

        var changingLayout = makeController(
            policy: policy(actionCooldown: 0)
        )
        _ = changingLayout.consume(makeSnapshot(
            state: .wideModalOneButton,
            time: 1,
            fingerprint: "one",
            actions: [gameAction(.pressWideModalTopButton)]
        ))
        #expect(requireAction(changingLayout.consume(makeSnapshot(
            state: .wideModalTwoButtons,
            time: 2,
            fingerprint: "two",
            actions: [gameAction(.pressWideModalTopButton)]
        )))?.intent == .pressWideModalTopButton)
    }

    @Test("A geometry-only two-button modal uses its upper-row rule without equipment metadata")
    func geometryTwoButtonNeedsNoEquipmentMetadata() {
        var controller = makeController()
        #expect(requireAction(controller.consume(makeSnapshot(
            state: .wideModalTwoButtons,
            time: 1,
            fingerprint: "two",
            actions: [gameAction(.pressWideModalTopButton)]
        )))?.intent == .pressWideModalTopButton)
        #expect(controller.actionsIssued == 1)
    }

    @Test("Closing a battle event may reach mission success before the next poll")
    func battleEventCloseCanReachSuccess() {
        var controller = makeController(policy: policy(actionCooldown: 0))
        _ = controller.consume(makeSnapshot(
            state: .battleEventPrompt,
            time: 1,
            fingerprint: "event",
            actions: [gameAction(.closeBattlePrompt)]
        ))

        let result = makeSnapshot(
            state: .missionComplete,
            time: 2,
            fingerprint: "fast-success",
            actions: [gameAction(.selectMissionRepeat)]
        )
        #expect(controller.consume(result) == .completedCycle(.init(
            count: 1,
            outcome: .success
        )))
        #expect(controller.actionsIssued == 1)
    }

    @Test("Closing a battle encounter may reach mission failure before the next poll")
    func battleEncounterCloseCanReachFailure() {
        var controller = makeController(policy: policy(actionCooldown: 0))
        _ = controller.consume(makeSnapshot(
            state: .battleEncounterPrompt,
            time: 1,
            fingerprint: "encounter",
            actions: [gameAction(.closeBattlePrompt)]
        ))

        let result = makeSnapshot(
            state: .missionFailed,
            time: 2,
            fingerprint: "fast-failure",
            actions: [gameAction(.selectMissionRepeat)]
        )
        #expect(controller.consume(result) == .completedCycle(.init(
            count: 1,
            outcome: .failure
        )))
        #expect(controller.actionsIssued == 1)
    }

    @Test("Closing a battle event may reach repeat-selected mission success before the next poll")
    func battleEventCloseCanReachRepeatSelectedSuccess() {
        var controller = makeController(policy: policy(actionCooldown: 0))
        _ = controller.consume(makeSnapshot(
            state: .battleEventPrompt,
            time: 1,
            fingerprint: "event",
            actions: [gameAction(.closeBattlePrompt)]
        ))

        let result = makeSnapshot(
            state: .missionCompleteRepeatSelected,
            time: 2,
            fingerprint: "fast-selected-success",
            actions: [gameAction(.advanceMissionComplete)]
        )
        #expect(controller.consume(result) == .completedCycle(.init(
            count: 1,
            outcome: .success
        )))
        #expect(requireAction(controller.consume(result))?.intent == .advanceMissionSuccess)
        #expect(controller.actionsIssued == 2)
    }

    @Test("Closing a battle encounter may reach repeat-selected mission failure before the next poll")
    func battleEncounterCloseCanReachRepeatSelectedFailure() {
        var controller = makeController(policy: policy(actionCooldown: 0))
        _ = controller.consume(makeSnapshot(
            state: .battleEncounterPrompt,
            time: 1,
            fingerprint: "encounter",
            actions: [gameAction(.closeBattlePrompt)]
        ))

        let result = makeSnapshot(
            state: .missionFailedRepeatSelected,
            time: 2,
            fingerprint: "fast-selected-failure",
            actions: [gameAction(.advanceMissionComplete)]
        )
        #expect(controller.consume(result) == .completedCycle(.init(
            count: 1,
            outcome: .failure
        )))
        #expect(requireAction(controller.consume(result))?.intent == .advanceMissionFailure)
        #expect(controller.actionsIssued == 2)
    }

    @Test("An identical post-click frame is never clicked twice")
    func identicalFrameIsDebounced() {
        var controller = makeController(policy: policy(postActionTimeout: 5))
        let prompt = makeSnapshot(
            state: .battleEventPrompt,
            time: 1,
            fingerprint: "same",
            actions: [gameAction(.closeBattlePrompt)]
        )
        _ = controller.consume(prompt)

        let decision = controller.consume(makeSnapshot(
            state: .battleEventPrompt,
            time: 2,
            fingerprint: "same",
            actions: [gameAction(.closeBattlePrompt)]
        ))

        #expect(decision == .wait(.awaitingFrameChange(intent: .closeBattlePrompt)))
        #expect(controller.actionsIssued == 1)
    }

    @Test("A click which never changes the frame stops at the bounded timeout")
    func unchangedFrameTimesOut() {
        var controller = makeController(policy: policy(postActionTimeout: 3))
        _ = controller.consume(makeSnapshot(
            state: .battleEncounterPrompt,
            time: 1,
            fingerprint: "same",
            actions: [gameAction(.closeBattlePrompt)]
        ))

        let decision = controller.consume(makeSnapshot(
            state: .battleEncounterPrompt,
            time: 4,
            fingerprint: "same",
            actions: [gameAction(.closeBattlePrompt)]
        ))

        #expect(decision == .stop(.actionDidNotAdvance(intent: .closeBattlePrompt)))
    }

    @Test("A dialog press the game never received retries twice on the unchanged dialog before stopping",
          arguments: [GameState.wideModalOneButton, .wideModalTwoButtons])
    func wideModalPressHasThreeAttemptBound(state: GameState) {
        var controller = makeController(policy: policy(actionCooldown: 0, postActionTimeout: 3))
        let dialog: (Double) -> AutoLevelSnapshot = { time in
            self.makeSnapshot(
                state: state, time: time, fingerprint: "frozen-dialog",
                actions: [self.gameAction(.pressWideModalTopButton)]
            )
        }
        let first = requireAction(controller.consume(dialog(1)))!
        #expect(first.requestID == 1 && first.intent == .pressWideModalTopButton)
        let marked1 = controller.markActionPosted(first, at: 2)
        #expect(marked1)
        #expect(controller.consume(dialog(4.9)) == .wait(.awaitingFrameChange(intent: .pressWideModalTopButton)))

        let second = requireAction(controller.consume(dialog(5)))!
        #expect(second.requestID == 2 && second.target == first.target)
        let marked2 = controller.markActionPosted(second, at: 6)
        #expect(marked2)
        #expect(controller.consume(dialog(8.9)) == .wait(.awaitingFrameChange(intent: .pressWideModalTopButton)))

        let third = requireAction(controller.consume(dialog(9)))!
        #expect(third.requestID == 3 && third.target == first.target)
        let marked3 = controller.markActionPosted(third, at: 10)
        #expect(marked3)
        #expect(controller.consume(dialog(12.9)) == .wait(.awaitingFrameChange(intent: .pressWideModalTopButton)))
        #expect(controller.consume(dialog(13)) == .stop(.actionDidNotAdvance(intent: .pressWideModalTopButton)))
        #expect(controller.actionsIssued == 3)
    }

    @Test("A continuation first captured after the acknowledgement timeout acknowledges the posted advance")
    func lateContinuationAcknowledgesTimedOutAdvance() throws {
        var controller = makeController(policy: policy(actionCooldown: 0, postActionTimeout: 3))
        let experience: (Double, String) -> AutoLevelSnapshot = { time, fingerprint in
            self.makeSnapshot(
                state: .missionCompleteRepeatSelected, time: time, fingerprint: fingerprint,
                actions: [self.gameAction(.advanceMissionComplete)]
            )
        }
        #expect(controller.consume(experience(1, "exp")) == .completedCycle(.init(count: 1, outcome: .success)))
        let advance = try #require(requireAction(controller.consume(experience(1.5, "exp"))))
        #expect(advance.intent == .advanceMissionSuccess)
        let posted = controller.markActionPosted(advance, at: 2)
        #expect(posted)
        // The page keeps settling single pixels, so its fingerprint differs from the origin.
        #expect(controller.consume(experience(3, "exp-settled"))
            == .wait(.awaitingStateChange(intent: .advanceMissionSuccess)))

        // logs/auto-level-20260920-200804: the dialog the arrow opens was first captured 11 s
        // after the tap, past the timeout, and the run stopped with actionDidNotAdvance.
        let dialog = makeSnapshot(
            state: .wideModalTwoButtons, time: 13, fingerprint: "dialog",
            actions: [gameAction(.pressWideModalTopButton)]
        )
        let next = try #require(requireAction(controller.consume(dialog)))
        #expect(next.intent == .pressWideModalTopButton)
        #expect(next.requestID == advance.requestID + 1)
        #expect(controller.completedCycles == 1)
        #expect(controller.actionsIssued == 2)
    }

    @Test("A dialog dismissed only after the timeout acknowledges the press instead of stopping",
          arguments: [GameState.wideModalOneButton, .wideModalTwoButtons])
    func lateDismissalAcknowledgesTimedOutWideModalPress(state: GameState) throws {
        var controller = makeController(policy: policy(actionCooldown: 0, postActionTimeout: 3))
        let dialog: (Double, String) -> AutoLevelSnapshot = { time, fingerprint in
            self.makeSnapshot(
                state: state, time: time, fingerprint: fingerprint,
                actions: [self.gameAction(.pressWideModalTopButton)]
            )
        }
        let press = try #require(requireAction(controller.consume(dialog(1, "dialog"))))
        let posted = controller.markActionPosted(press, at: 2)
        #expect(posted)
        #expect(controller.consume(dialog(3, "dialog"))
            == .wait(.awaitingFrameChange(intent: .pressWideModalTopButton)))

        let result = makeSnapshot(
            state: .missionCompleteRepeatSelected, time: 9, fingerprint: "result",
            actions: [gameAction(.advanceMissionComplete)]
        )
        #expect(controller.consume(result) == .completedCycle(.init(count: 1, outcome: .success)))
        #expect(controller.pendingActionAcknowledgementDeadline == nil)
        #expect(controller.actionsIssued == 1)
    }

    @Test("A page that is not the requested continuation still stops after the timeout")
    func unexpectedPageAfterTimeoutStillStops() throws {
        var controller = makeController(policy: policy(actionCooldown: 0, postActionTimeout: 3))
        let experience = makeSnapshot(
            state: .missionCompleteRepeatSelected, time: 1, fingerprint: "exp",
            actions: [gameAction(.advanceMissionComplete)]
        )
        _ = controller.consume(experience)
        let advance = try #require(requireAction(controller.consume(experience)))
        let posted = controller.markActionPosted(advance, at: 2)
        #expect(posted)
        #expect(controller.consume(makeSnapshot(
            state: .missionFailed, time: 9, fingerprint: "failure"
        )) == .stop(.actionDidNotAdvance(intent: .advanceMissionSuccess)))
        #expect(controller.completedCycles == 1)
        #expect(controller.actionsIssued == 1)
    }

    @Test("An unposted request is not acknowledged by a late continuation")
    func unpostedRequestKeepsItsPostingDeadline() throws {
        var controller = makeController(policy: policy(actionCooldown: 0, postActionTimeout: 3))
        let experience = makeSnapshot(
            state: .missionCompleteRepeatSelected, time: 1, fingerprint: "exp",
            actions: [gameAction(.advanceMissionComplete)]
        )
        _ = controller.consume(experience)
        _ = try #require(requireAction(controller.consume(experience)))
        #expect(controller.consume(makeSnapshot(
            state: .wideModalTwoButtons, time: 9, fingerprint: "dialog",
            actions: [gameAction(.pressWideModalTopButton)]
        )) == .stop(.actionDidNotAdvance(intent: .advanceMissionSuccess)))
    }

    @Test("A retried dialog press that finally dismisses the dialog resumes normally")
    func retriedWideModalPressAcknowledgedByDismissal() {
        var controller = makeController(policy: policy(actionCooldown: 0, postActionTimeout: 3))
        let first = requireAction(controller.consume(makeSnapshot(
            state: .wideModalOneButton, time: 1, fingerprint: "dialog",
            actions: [gameAction(.pressWideModalTopButton)]
        )))!
        let marked4 = controller.markActionPosted(first, at: 2)
        #expect(marked4)
        let second = requireAction(controller.consume(makeSnapshot(
            state: .wideModalOneButton, time: 5, fingerprint: "dialog",
            actions: [gameAction(.pressWideModalTopButton)]
        )))!
        #expect(second.requestID == 2)
        let marked5 = controller.markActionPosted(second, at: 6)
        #expect(marked5)
        let resultPage: (Double) -> AutoLevelSnapshot = { time in
            self.makeSnapshot(
                state: .missionCompleteRepeatSelected, time: time, fingerprint: "result-after-dialog",
                actions: [self.gameAction(.advanceMissionComplete)]
            )
        }
        // The dismissal is acknowledged by the result page, which first completes the cycle.
        #expect(controller.consume(resultPage(7)) == .completedCycle(.init(count: 1, outcome: .success)))
        #expect(controller.pendingActionAcknowledgementDeadline == nil)
        #expect(requireAction(controller.consume(resultPage(7)))?.intent == .advanceMissionSuccess)
        #expect(controller.actionsIssued == 3)
    }

    @Test("A timed-out dialog press does not retry when the dialog layout or button changed")
    func wideModalPressRetryRequiresSameDialog() {
        var controller = makeController(policy: policy(actionCooldown: 0, postActionTimeout: 3))
        let first = requireAction(controller.consume(makeSnapshot(
            state: .wideModalOneButton, time: 1, fingerprint: "dialog",
            actions: [gameAction(.pressWideModalTopButton)]
        )))!
        let marked6 = controller.markActionPosted(first, at: 2)
        #expect(marked6)
        let movedButton = gameAction(
            .pressWideModalTopButton,
            rect: NormalizedRect(x: 0.2, y: 0.7, width: 0.6, height: 0.05)
        )
        #expect(movedButton.target.rect != first.target.rect)
        #expect(controller.consume(makeSnapshot(
            state: .wideModalOneButton, time: 5, fingerprint: "dialog",
            actions: [movedButton]
        )) == .stop(.actionDidNotAdvance(intent: .pressWideModalTopButton)))
    }

    @Test("Delayed modal OCR waits for fresh pixels without consuming an action or its deadline")
    func staleInitialActionRequiresFreshObservation() throws {
        var controller = makeController(policy: policy(actionCooldown: 0, postActionTimeout: 5))
        for capturedAt in [1.0, 2.0] {
            #expect(controller.consume(makeSnapshot(
                state: .wideModalOneButton,
                time: capturedAt,
                fingerprint: "stale-modal",
                actions: [gameAction(.pressWideModalTopButton)]
            ), allowNewActions: false) == .wait(.freshObservationRequired))
            #expect(controller.actionsIssued == 0)
            #expect(controller.pendingActionAcknowledgementDeadline == nil)
        }

        let request = try #require(requireAction(controller.consume(makeSnapshot(
            state: .wideModalOneButton,
            time: 3,
            fingerprint: "fresh-modal",
            actions: [gameAction(.pressWideModalTopButton)]
        ))))
        #expect(request.requestID == 1)
        #expect(request.frameFingerprint == "fresh-modal")
        #expect(controller.actionsIssued == 1)
        let expired = controller.markActionPosted(request, at: 8)
        #expect(!expired)
        let posted = controller.markActionPosted(request, at: 7.9)
        #expect(posted)
        #expect(controller.pendingActionAcknowledgementDeadline == 12.9)
    }

    @Test("Delayed acknowledgement preserves cycle and repeat-selection proof but defers the next input")
    func staleAcknowledgementPreservesResultEvidence() throws {
        var controller = makeController(policy: policy(actionCooldown: 0, postActionTimeout: 5))
        let postedRequest = try #require(requireAction(controller.consume(makeSnapshot(
            state: .battleEncounterPrompt,
            time: 1,
            fingerprint: "prompt",
            actions: [gameAction(.closeBattlePrompt)]
        ))))
        let posted = controller.markActionPosted(postedRequest, at: 2)
        #expect(posted)

        let result = makeSnapshot(
            state: .missionCompleteRepeatSelected,
            time: 3,
            fingerprint: "captured-selected-result",
            actions: [gameAction(.advanceMissionComplete)]
        )
        #expect(controller.consume(result, allowNewActions: false)
            == .completedCycle(.init(count: 1, outcome: .success)))
        #expect(controller.pendingActionAcknowledgementDeadline == nil)
        #expect(controller.consume(result, allowNewActions: false) == .wait(.freshObservationRequired))
        #expect(controller.actionsIssued == 1)

        // Retaining the captured SELECTED proof prevents a later OCR miss from undoing it.
        #expect(controller.consume(makeSnapshot(
            state: .missionComplete,
            time: 4,
            fingerprint: "selected-stamp-missed",
            actions: [gameAction(.selectMissionRepeat)]
        )) == .wait(.transientState(kind: .missingAction, observationCount: 1)))
        let nextRequest = try #require(requireAction(controller.consume(makeSnapshot(
            state: .missionCompleteRepeatSelected,
            time: 5,
            fingerprint: "fresh-selected-result",
            actions: [gameAction(.advanceMissionComplete)]
        ))))
        #expect(nextRequest.requestID == 2)
        #expect(nextRequest.intent == .advanceMissionSuccess)
        #expect(controller.completedCycles == 1)
    }

    @Test("Delayed EXP-to-loot proof acknowledges the old post without issuing loot's new action")
    func staleSuccessPageTransitionDefersNextAction() throws {
        var controller = makeController(policy: policy(actionCooldown: 0, postActionTimeout: 5))
        let experience = measuredSuccessFallbackSnapshot(page: .experience, time: 1, fingerprint: "exp")
        _ = controller.consume(experience)
        let request = try #require(requireAction(controller.consume(experience)))
        let posted = controller.markActionPosted(request, at: 2)
        #expect(posted)

        #expect(controller.consume(measuredSuccessFallbackSnapshot(
            page: .loot, time: 3, fingerprint: "captured-loot"
        ), allowNewActions: false) == .wait(.freshObservationRequired))
        #expect(controller.pendingActionAcknowledgementDeadline == nil)
        #expect(controller.actionsIssued == 1)
        let freshRequest = try #require(requireAction(controller.consume(measuredSuccessFallbackSnapshot(
            page: .loot, time: 4, fingerprint: "fresh-loot"
        ))))
        #expect(freshRequest.requestID == 2)
        #expect(freshRequest.frameFingerprint == "fresh-loot")
        #expect(controller.completedCycles == 1)
    }

    @Test("Delayed result OCR cannot restart posted deadlines or spend a success retry",
          arguments: [MissionSuccessPageIdentity.experience, .loot])
    func staleSuccessRetryPreservesPostedDeadlineAndRetryLimit(page: MissionSuccessPageIdentity) throws {
        var controller = makeController(policy: policy(actionCooldown: 0, postActionTimeout: 3))
        let snapshotAt: (Double) -> AutoLevelSnapshot = { capturedAt in
            self.measuredSuccessFallbackSnapshot(page: page, time: capturedAt, fingerprint: "same-page")
        }
        _ = controller.consume(snapshotAt(1))
        let first = try #require(requireAction(controller.consume(snapshotAt(1))))
        let firstPosted = controller.markActionPosted(first, at: 2)
        #expect(firstPosted)

        for capturedAt in [5.0, 5.5] {
            #expect(controller.consume(snapshotAt(capturedAt), allowNewActions: false)
                == .wait(.freshObservationRequired))
            #expect(controller.pendingActionAcknowledgementDeadline == 5)
            #expect(controller.actionsIssued == 1)
        }
        let second = try #require(requireAction(controller.consume(snapshotAt(6))))
        #expect(second.requestID == 2)
        let secondPosted = controller.markActionPosted(second, at: 7)
        #expect(secondPosted)
        #expect(controller.consume(snapshotAt(10), allowNewActions: false)
            == .wait(.freshObservationRequired))
        #expect(controller.pendingActionAcknowledgementDeadline == 10)
        #expect(controller.actionsIssued == 2)

        let third = try #require(requireAction(controller.consume(snapshotAt(11))))
        #expect(third.requestID == 3)
        let thirdPosted = controller.markActionPosted(third, at: 12)
        #expect(thirdPosted)
        #expect(controller.pendingActionAcknowledgementDeadline == 15)
        #expect(controller.consume(snapshotAt(15), allowNewActions: false)
            == .stop(.actionDidNotAdvance(intent: .advanceMissionSuccess)))
        #expect(controller.actionsIssued == 3)
    }

    @Test("Fresh observation gating preserves one-shot retreat confirmation until it can issue",
          arguments: [GameState.retreatConfirmation, .wideModalTwoButtons])
    func staleRetreatConfirmationPreservesOneShotAuthorization(state: GameState) throws {
        var controller = makeController(policy: policy(actionCooldown: 0))
        #expect(controller.consume(makeSnapshot(
            state: .battle,
            time: 1,
            fingerprint: "stale-stall",
            gatedActions: [gatedAction(.openBattleRetreatConfirmation, .temporalDefeatRecovery)],
            battleStatus: .stalledAfterDefeat
        ), allowNewActions: false) == .wait(.freshObservationRequired))
        #expect(controller.actionsIssued == 0)
        let retreat = try #require(requireAction(controller.consume(makeSnapshot(
            state: .battle,
            time: 2,
            fingerprint: "fresh-stall",
            gatedActions: [gatedAction(.openBattleRetreatConfirmation, .temporalDefeatRecovery)],
            battleStatus: .stalledAfterDefeat
        ))))
        #expect(retreat.requestID == 1)
        let retreatPosted = controller.markActionPosted(retreat, at: 2.5)
        #expect(retreatPosted)
        let confirmationAt: (Double) -> AutoLevelSnapshot = { capturedAt in
            self.makeSnapshot(
                state: state,
                time: capturedAt,
                fingerprint: "confirmation",
                actions: state == .wideModalTwoButtons ? [self.gameAction(.pressWideModalTopButton)] : [],
                gatedActions: state == .retreatConfirmation
                    ? [self.gatedAction(.confirmNoTalismanRetreat, .explicitRetreatConfirmation)] : []
            )
        }
        for capturedAt in [3.0, 4.0] {
            #expect(controller.consume(confirmationAt(capturedAt), allowNewActions: false)
                == .wait(.freshObservationRequired))
            #expect(controller.actionsIssued == 1)
            #expect(controller.pendingActionAcknowledgementDeadline == nil)
        }
        let confirmation = try #require(requireAction(controller.consume(confirmationAt(5))))
        #expect(confirmation.requestID == 2)
        #expect(confirmation.intent == (state == .retreatConfirmation
            ? .confirmRetreatWithoutTalisman : .pressWideModalTopButton))
        let confirmationPosted = controller.markActionPosted(confirmation, at: 5.5)
        #expect(confirmationPosted)
        // A confirmation the game never received is pressed again on the same sheet, but
        // never from a stale observation: the one-shot authorization is not re-spent early.
        #expect(controller.consume(confirmationAt(13.5), allowNewActions: false)
            == .wait(.freshObservationRequired))
        #expect(controller.actionsIssued == 2)
        let retried = try #require(requireAction(controller.consume(confirmationAt(14))))
        #expect(retried.requestID == 3)
        #expect(retried.intent == confirmation.intent)
        #expect(retried.target == confirmation.target)
        #expect(controller.actionsIssued == 3)
    }

    @Test("A delayed post starts its acknowledgement timeout without extending authorization")
    func delayedPostStartsAcknowledgementTimeout() {
        var controller = makeController(policy: policy(
            actionCooldown: 0,
            postActionTimeout: 5
        ))
        let request = requireAction(controller.consume(makeSnapshot(
            state: .battleEncounterPrompt,
            time: 1,
            fingerprint: "same",
            actions: [gameAction(.closeBattlePrompt)]
        )))
        #expect(request != nil)
        let marked = controller.markActionPosted(request!, at: 4.9)
        #expect(marked)

        #expect(controller.consume(makeSnapshot(
            state: .battleEncounterPrompt,
            time: 8.9,
            fingerprint: "same",
            actions: [gameAction(.closeBattlePrompt)]
        )) == .wait(.awaitingFrameChange(intent: .closeBattlePrompt)))
        #expect(controller.consume(makeSnapshot(
            state: .battleEncounterPrompt,
            time: 9.9,
            fingerprint: "same",
            actions: [gameAction(.closeBattlePrompt)]
        )) == .stop(.actionDidNotAdvance(intent: .closeBattlePrompt)))
    }

    @Test("Capture recovery sees the original posted-action deadline until acknowledgement")
    func pendingAcknowledgementDeadlineDoesNotRenewWhileWaiting() throws {
        var controller = makeController(policy: policy(
            actionCooldown: 0,
            postActionTimeout: 5
        ))
        #expect(controller.pendingActionAcknowledgementDeadline == nil)
        let request = try #require(requireAction(controller.consume(makeSnapshot(
            state: .battleEncounterPrompt,
            time: 1,
            fingerprint: "prompt",
            actions: [gameAction(.closeBattlePrompt)]
        ))))
        #expect(controller.pendingActionAcknowledgementDeadline == nil)
        let posted = controller.markActionPosted(request, at: 2)
        #expect(posted)
        #expect(controller.pendingActionAcknowledgementDeadline == 7)

        #expect(controller.consume(makeSnapshot(
            state: .battleEncounterPrompt,
            time: 3,
            fingerprint: "prompt",
            actions: [gameAction(.closeBattlePrompt)]
        )) == .wait(.awaitingFrameChange(intent: .closeBattlePrompt)))
        #expect(controller.pendingActionAcknowledgementDeadline == 7)
        #expect(controller.consume(makeSnapshot(
            state: .battleEncounterPrompt,
            time: 4,
            fingerprint: "prompt-animation",
            actions: [gameAction(.closeBattlePrompt)]
        )) == .wait(.awaitingStateChange(intent: .closeBattlePrompt)))
        #expect(controller.pendingActionAcknowledgementDeadline == 7)

        #expect(controller.consume(makeSnapshot(
            state: .missionComplete,
            time: 5,
            fingerprint: "success",
            actions: [gameAction(.selectMissionRepeat)]
        )) == .completedCycle(.init(count: 1, outcome: .success)))
        #expect(controller.pendingActionAcknowledgementDeadline == nil)
        #expect(controller.actionsIssued == 1)
    }

    @Test("A posted success advance retries twice on the same page before the third timeout stops",
          arguments: [MissionSuccessPageIdentity.experience, .loot])
    func successAdvanceHasThreeAttemptBound(page: MissionSuccessPageIdentity) {
        var controller = makeController(policy: policy(
            actionCooldown: 0,
            postActionTimeout: 3
        ))
        let snapshotAt: (Double) -> AutoLevelSnapshot = { observedAt in
            self.measuredSuccessFallbackSnapshot(
                page: page,
                time: observedAt,
                fingerprint: "frozen-loot-page"
            )
        }

        #expect(controller.consume(snapshotAt(1)) == .completedCycle(.init(
            count: 1,
            outcome: .success
        )))
        let first = requireAction(controller.consume(snapshotAt(1)))!
        #expect(first.requestID == 1)
        #expect(first.target.sourceText == MissionResultTopActionResolver.measuredTopAdvanceSentinel)
        #expect(first.target.rect == MissionResultTopActionResolver.measuredTopAdvanceRect)
        let firstMarked = controller.markActionPosted(first, at: 2)
        #expect(firstMarked)
        #expect(controller.consume(snapshotAt(4.9)) == .wait(.awaitingFrameChange(
            intent: .advanceMissionSuccess
        )))

        let second = requireAction(controller.consume(snapshotAt(5)))!
        #expect(second.requestID == 2)
        #expect(second.target == first.target)
        let secondMarked = controller.markActionPosted(second, at: 6)
        #expect(secondMarked)
        #expect(controller.consume(snapshotAt(8.9)) == .wait(.awaitingFrameChange(
            intent: .advanceMissionSuccess
        )))

        let third = requireAction(controller.consume(snapshotAt(9)))!
        #expect(third.requestID == 3)
        #expect(third.target == first.target)
        let thirdMarked = controller.markActionPosted(third, at: 10)
        #expect(thirdMarked)
        #expect(controller.consume(snapshotAt(12.9)) == .wait(.awaitingFrameChange(
            intent: .advanceMissionSuccess
        )))
        #expect(controller.consume(snapshotAt(13)) == .stop(.actionDidNotAdvance(
            intent: .advanceMissionSuccess
        )))
        #expect(controller.actionsIssued == 3)
    }

    @Test("An unposted success-page request is never converted into a retry",
          arguments: [MissionSuccessPageIdentity.experience, .loot])
    func unpostedSuccessPageRequestDoesNotRetry(page: MissionSuccessPageIdentity) {
        var controller = makeController(policy: policy(
            actionCooldown: 0,
            postActionTimeout: 3
        ))
        let snapshotAt: (Double) -> AutoLevelSnapshot = { observedAt in
            self.measuredSuccessFallbackSnapshot(
                page: page,
                time: observedAt,
                fingerprint: "unposted-loot-page"
            )
        }

        _ = controller.consume(snapshotAt(1))
        let request = requireAction(controller.consume(snapshotAt(1)))!
        #expect(request.requestID == 1)
        #expect(controller.consume(snapshotAt(4)) == .stop(.actionDidNotAdvance(
            intent: .advanceMissionSuccess
        )))
        #expect(controller.actionsIssued == 1)
    }

    @Test("A longer cooldown preserves the timed-out retry context")
    func lootPageRetryWaitsForLongerCooldown() {
        var controller = makeController(policy: policy(
            actionCooldown: 10,
            postActionTimeout: 3
        ))
        let snapshotAt: (Double) -> AutoLevelSnapshot = { observedAt in
            self.measuredLootFallbackSnapshot(
                time: observedAt,
                fingerprint: "cooldown-loot-page"
            )
        }

        _ = controller.consume(snapshotAt(1))
        let first = requireAction(controller.consume(snapshotAt(1)))!
        let marked = controller.markActionPosted(first, at: 2)
        #expect(marked)
        #expect(controller.consume(snapshotAt(5)) == .wait(.actionCooldown(remaining: 6)))
        let second = requireAction(controller.consume(snapshotAt(11)))!
        #expect(second.requestID == 2)
        #expect(second.target == first.target)
        #expect(controller.actionsIssued == 2)
    }

    @Test("A forward transition acknowledges a bounded loot-page retry")
    func successfulLootPageRetryIsAcknowledged() {
        var controller = makeController(policy: policy(
            actionCooldown: 0,
            postActionTimeout: 3
        ))
        let snapshotAt: (Double) -> AutoLevelSnapshot = { observedAt in
            self.measuredLootFallbackSnapshot(
                time: observedAt,
                fingerprint: "retryable-loot-page"
            )
        }

        _ = controller.consume(snapshotAt(1))
        let first = requireAction(controller.consume(snapshotAt(1)))!
        let firstMarked = controller.markActionPosted(first, at: 2)
        #expect(firstMarked)
        let second = requireAction(controller.consume(snapshotAt(5)))!
        let secondMarked = controller.markActionPosted(second, at: 6)
        #expect(secondMarked)

        let battle = makeSnapshot(
            state: .battle,
            time: 7,
            fingerprint: "advanced-after-retry",
            allAutoStatus: .active
        )
        #expect(controller.consume(battle) == .wait(.battleInProgress))
        #expect(controller.actionsIssued == 2)
        #expect(controller.completedCycles == 1)
    }

    @Test("A timed-out success advance cannot retry across different result pages")
    func successAdvanceRetryRequiresSameOriginAndCurrentPage() throws {
        // EXP -> loot is the arrow's requested continuation: a late loot page acknowledges the
        // EXP tap and gets loot's own fresh arrow request, never a retry of the EXP post.
        var forward = makeController(policy: policy(actionCooldown: 0, postActionTimeout: 3))
        let experience = measuredSuccessFallbackSnapshot(page: .experience, time: 1, fingerprint: "exp")
        _ = forward.consume(experience)
        let experienceRequest = try #require(requireAction(forward.consume(experience)))
        let experiencePosted = forward.markActionPosted(experienceRequest, at: 2)
        #expect(experiencePosted)
        let lootRequest = try #require(requireAction(forward.consume(
            measuredSuccessFallbackSnapshot(page: .loot, time: 5, fingerprint: "loot")
        )))
        #expect(lootRequest.requestID == experienceRequest.requestID + 1)
        #expect(lootRequest.target == experienceRequest.target)
        #expect(forward.pendingActionAcknowledgementDeadline == nil)
        #expect(forward.completedCycles == 1)
        #expect(forward.actionsIssued == 2)

        // Loot -> EXP is not a continuation of the loot arrow, so it neither retries nor resumes.
        var backward = makeController(policy: policy(actionCooldown: 0, postActionTimeout: 3))
        let loot = measuredSuccessFallbackSnapshot(page: .loot, time: 1, fingerprint: "loot")
        _ = backward.consume(loot)
        let request = try #require(requireAction(backward.consume(loot)))
        let marked = backward.markActionPosted(request, at: 2)
        #expect(marked)
        #expect(backward.consume(
            measuredSuccessFallbackSnapshot(page: .experience, time: 5, fingerprint: "exp")
        ) == .stop(.actionDidNotAdvance(intent: .advanceMissionSuccess)))
        #expect(backward.actionsIssued == 1)
    }

    @Test("An acknowledged EXP retry starts a fresh loot-page budget without recounting success")
    func experienceRetryAcknowledgesForwardLootPage() throws {
        var controller = makeController(policy: policy(actionCooldown: 0, postActionTimeout: 3))
        let experience = measuredSuccessFallbackSnapshot(page: .experience, time: 1, fingerprint: "exp")
        _ = controller.consume(experience)
        let first = try #require(requireAction(controller.consume(experience)))
        let firstPosted = controller.markActionPosted(first, at: 2)
        #expect(firstPosted)
        let second = try #require(requireAction(controller.consume(measuredSuccessFallbackSnapshot(
            page: .experience, time: 5, fingerprint: "exp"
        ))))
        let secondPosted = controller.markActionPosted(second, at: 6)
        #expect(secondPosted)

        // This visible page transition acknowledges EXP before its timeout and issues loot's
        // first action. Sharing the same arrow must not inherit EXP's already-used retry count.
        var lootRequest = try #require(requireAction(controller.consume(measuredSuccessFallbackSnapshot(
            page: .loot, time: 7, fingerprint: "loot"
        ))))
        #expect(lootRequest.target == second.target)
        #expect(controller.pendingActionAcknowledgementDeadline == nil)
        for (postTime, timeout) in [(8.0, 11.0), (12.0, 15.0)] {
            let posted = controller.markActionPosted(lootRequest, at: postTime)
            #expect(posted)
            lootRequest = try #require(requireAction(controller.consume(measuredSuccessFallbackSnapshot(
                page: .loot, time: timeout, fingerprint: "loot"
            ))))
        }
        let lastPosted = controller.markActionPosted(lootRequest, at: 16)
        #expect(lastPosted)
        #expect(controller.consume(measuredSuccessFallbackSnapshot(
            page: .loot, time: 19, fingerprint: "loot"
        )) == .stop(.actionDidNotAdvance(intent: .advanceMissionSuccess)))
        #expect(controller.actionsIssued == 5)
        #expect(controller.completedCycles == 1)
    }

    @Test("Preflight EXP-to-loot cancellation preserves the action count and cooldown")
    func cancelsUnpostedSuccessAdvanceAfterForwardPageTransition() throws {
        var controller = makeController(policy: policy(actionCooldown: 3))
        let experience = measuredSuccessFallbackSnapshot(page: .experience, time: 1, fingerprint: "shared")
        _ = controller.consume(experience)
        let request = try #require(requireAction(controller.consume(experience)))
        let loot = measuredSuccessFallbackSnapshot(page: .loot, time: 2, fingerprint: "shared")

        let cancelled = controller.cancelUnpostedSuccessAdvanceAfterPageTransition(
            request, observedClassification: loot.classification
        )
        #expect(cancelled)
        #expect(controller.actionsIssued == 1)
        #expect(controller.completedCycles == 1)
        #expect(controller.pendingActionAcknowledgementDeadline == nil)
        let stalePost = controller.markActionPosted(request, at: 2)
        #expect(!stalePost)
        #expect(controller.consume(loot) == .wait(.actionCooldown(remaining: 2)))
        let fresh = try #require(requireAction(controller.consume(measuredSuccessFallbackSnapshot(
            page: .loot, time: 4, fingerprint: "shared"
        ))))
        #expect(fresh.requestID == request.requestID + 1)
        #expect(controller.actionsIssued == 2)
        #expect(controller.completedCycles == 1)

        var limited = makeController(policy: policy(actionCooldown: 0, maxActions: 1))
        _ = limited.consume(experience)
        let limitedRequest = try #require(requireAction(limited.consume(experience)))
        let limitedCancelled = limited.cancelUnpostedSuccessAdvanceAfterPageTransition(
            limitedRequest, observedClassification: loot.classification
        )
        #expect(limitedCancelled)
        #expect(limited.consume(loot) == .stop(.maximumActionsReached(limit: 1)))
    }

    @Test("Success-page preflight cancellation requires every field of the unposted request")
    func successPageCancellationRequiresExactPendingRequest() throws {
        var controller = makeController(policy: policy(actionCooldown: 0))
        let experience = measuredSuccessFallbackSnapshot(page: .experience, time: 1, fingerprint: "exp")
        _ = controller.consume(experience)
        let request = try #require(requireAction(controller.consume(experience)))
        let loot = measuredSuccessFallbackSnapshot(page: .loot, time: 2, fingerprint: "loot").classification
        for changedField in 0..<6 {
            let altered = AutoLevelActionRequest(
                requestID: request.requestID + (changedField == 0 ? 1 : 0),
                intent: changedField == 1 ? .advanceMissionFailure : request.intent,
                target: changedField == 2 ? AutoLevelActionTarget(
                    name: request.target.name, sourceText: "changed", rect: request.target.rect
                ) : request.target,
                observedState: changedField == 3 ? .missionFailedRepeatSelected : request.observedState,
                frameFingerprint: changedField == 4 ? "different" : request.frameFingerprint,
                completedCycles: request.completedCycles + (changedField == 5 ? 1 : 0)
            )
            let cancelled = controller.cancelUnpostedSuccessAdvanceAfterPageTransition(
                altered, observedClassification: loot
            )
            #expect(!cancelled)
            #expect(controller.actionsIssued == 1)
        }
        let cancelled = controller.cancelUnpostedSuccessAdvanceAfterPageTransition(
            request, observedClassification: loot
        )
        #expect(cancelled)
        let cancelledAgain = controller.cancelUnpostedSuccessAdvanceAfterPageTransition(
            request, observedClassification: loot
        )
        #expect(!cancelledAgain)
    }

    @Test("Success-page cancellation rejects uncertain pages and ambiguous or incompatible targets")
    func successPageCancellationRequiresTrustedForwardPageAndTarget() throws {
        let experience = measuredSuccessFallbackSnapshot(page: .experience, time: 1, fingerprint: "exp")
        let loot = measuredSuccessFallbackSnapshot(page: .loot, time: 2, fingerprint: "loot").classification
        let page = try #require(loot.evidence.first { $0.kind == .missionLootPage })
        var invalidClassifications = [experience.classification]
        for state in [GameState.unknown, .missionComplete, .missionFailedRepeatSelected, .wideModalOneButton] {
            invalidClassifications.append(GameStateClassification(
                state: state, evidence: loot.evidence, allowedActions: loot.allowedActions, policyGatedActions: []
            ))
        }
        for evidence in [
            loot.evidence.filter { $0.kind != .missionLootPage },
            loot.evidence + [page],
        ] + [GameEvidenceKind.invalidObservation, .lowConfidenceMarker, .conflictingStateMarkers].map({ kind in
            loot.evidence + [GameStateEvidence(kind: kind, observation: nil, detail: "uncertain preflight")]
        }) {
            invalidClassifications.append(GameStateClassification(
                state: loot.state, evidence: evidence, allowedActions: loot.allowedActions, policyGatedActions: []
            ))
        }
        for actions in [
            [],
            loot.allowedActions + loot.allowedActions,
            [gameAction(.advanceMissionComplete,
                        rect: NormalizedRect(x: 0.02, y: 0.70, width: 0.05, height: 0.02))],
            [gameAction(.advanceMissionComplete,
                        rect: NormalizedRect(x: -0.02, y: 0.20, width: 0.05, height: 0.02))],
        ] {
            invalidClassifications.append(GameStateClassification(
                state: loot.state, evidence: loot.evidence, allowedActions: actions, policyGatedActions: []
            ))
        }
        var controller = makeController(policy: policy(actionCooldown: 0))
        _ = controller.consume(experience)
        let request = try #require(requireAction(controller.consume(experience)))
        for classification in invalidClassifications {
            let cancelled = controller.cancelUnpostedSuccessAdvanceAfterPageTransition(
                request, observedClassification: classification
            )
            #expect(!cancelled)
            #expect(controller.actionsIssued == 1)
        }
        let validCancelled = controller.cancelUnpostedSuccessAdvanceAfterPageTransition(
            request, observedClassification: loot
        )
        #expect(validCancelled)
    }

    @Test("Posted actions, reverse transitions, unrelated actions, and stopped sessions cannot cancel")
    func successPageCancellationRejectsOtherPendingContexts() throws {
        let experience = measuredSuccessFallbackSnapshot(page: .experience, time: 1, fingerprint: "exp")
        let loot = measuredSuccessFallbackSnapshot(page: .loot, time: 2, fingerprint: "loot")
        var postedController = makeController(policy: policy(actionCooldown: 0))
        _ = postedController.consume(experience)
        let postedRequest = try #require(requireAction(postedController.consume(experience)))
        let posted = postedController.markActionPosted(postedRequest, at: 1.5)
        #expect(posted)
        let postedCancelled = postedController.cancelUnpostedSuccessAdvanceAfterPageTransition(
            postedRequest, observedClassification: loot.classification
        )
        #expect(!postedCancelled)
        #expect(postedController.pendingActionAcknowledgementDeadline == 9.5)

        var reverse = makeController(policy: policy(actionCooldown: 0))
        _ = reverse.consume(loot)
        let reverseRequest = try #require(requireAction(reverse.consume(loot)))
        for classification in [experience.classification, loot.classification] {
            let cancelled = reverse.cancelUnpostedSuccessAdvanceAfterPageTransition(
                reverseRequest, observedClassification: classification
            )
            #expect(!cancelled)
        }

        var unrelated = makeController(policy: policy(actionCooldown: 0))
        let close = try #require(requireAction(unrelated.consume(makeSnapshot(
            state: .battleEncounterPrompt, time: 1, fingerprint: "prompt", actions: [gameAction(.closeBattlePrompt)]
        ))))
        let closeCancelled = unrelated.cancelUnpostedSuccessAdvanceAfterPageTransition(
            close, observedClassification: loot.classification
        )
        #expect(!closeCancelled)

        var stopped = makeController(policy: policy(actionCooldown: 0, maxRuntime: 2))
        _ = stopped.consume(experience)
        let stoppedRequest = try #require(requireAction(stopped.consume(experience)))
        #expect(stopped.consume(loot) == .stop(.maximumRuntimeReached(limit: 2)))
        let terminalCancelled = stopped.cancelUnpostedSuccessAdvanceAfterPageTransition(
            stoppedRequest, observedClassification: loot.classification
        )
        #expect(!terminalCancelled)
    }

    @Test("Success-page retry requires the same unique exact action target",
          arguments: [MissionSuccessPageIdentity.experience, .loot])
    func successPageRetryRequiresSameUniqueExactTarget(page: MissionSuccessPageIdentity) {
        let baseline = measuredSuccessFallbackSnapshot(
            page: page, time: 1, fingerprint: "baseline"
        ).classification
        let originalAction = baseline.allowedActions[0]
        let changedTarget = NormalizedRect(
            x: 0.03,
            y: 0.195,
            width: 0.05,
            height: 0.02
        )
        let currentActionSets: [[AllowedGameAction]] = [
            [gameAction(
                .advanceMissionComplete,
                rect: changedTarget,
                sourceText: MissionResultTopActionResolver.measuredTopAdvanceSentinel
            )],
            [],
            [originalAction, originalAction],
        ]

        for (index, currentActions) in currentActionSets.enumerated() {
            var controller = makeController(policy: policy(
                actionCooldown: 0,
                postActionTimeout: 3
            ))
            let origin = measuredSuccessFallbackSnapshot(
                page: page,
                time: 1,
                fingerprint: "target-origin-\(index)"
            )
            _ = controller.consume(origin)
            let request = requireAction(controller.consume(origin))!
            let marked = controller.markActionPosted(request, at: 2)
            #expect(marked)

            let current = measuredSuccessFallbackSnapshot(
                page: page,
                time: 5,
                fingerprint: "target-current-\(index)",
                allowedActions: currentActions
            )
            #expect(controller.consume(current) == .stop(.actionDidNotAdvance(
                intent: .advanceMissionSuccess
            )))
            #expect(controller.actionsIssued == 1)
        }
    }

    @Test("An uncertain timeout snapshot cannot authorize a success-page retry",
          arguments: [MissionSuccessPageIdentity.experience, .loot])
    func uncertainSnapshotCannotAuthorizeSuccessPageRetry(page: MissionSuccessPageIdentity) {
        var controller = makeController(policy: policy(
            actionCooldown: 0,
            postActionTimeout: 3
        ))
        let origin = measuredSuccessFallbackSnapshot(
            page: page,
            time: 1,
            fingerprint: "certain-loot-origin"
        )
        _ = controller.consume(origin)
        let request = requireAction(controller.consume(origin))!
        let marked = controller.markActionPosted(request, at: 2)
        #expect(marked)

        let uncertain = makeSnapshot(
            state: .unknown,
            time: 5,
            fingerprint: "uncertain-at-timeout"
        )
        #expect(controller.consume(uncertain) == .stop(.actionDidNotAdvance(
            intent: .advanceMissionSuccess
        )))
        #expect(controller.actionsIssued == 1)
    }

    @Test("A posted non-success action never retries after its timeout")
    func nonSuccessActionDoesNotRetry() {
        var controller = makeController(policy: policy(
            actionCooldown: 0,
            postActionTimeout: 3
        ))
        let failure = makeSnapshot(
            state: .missionFailedRepeatSelected,
            time: 1,
            fingerprint: "frozen-failure",
            actions: [gameAction(.advanceMissionComplete)]
        )
        _ = controller.consume(failure)
        let request = requireAction(controller.consume(failure))!
        #expect(request.intent == .advanceMissionFailure)
        let marked = controller.markActionPosted(request, at: 2)
        #expect(marked)

        #expect(controller.consume(makeSnapshot(
            state: .missionFailedRepeatSelected,
            time: 5,
            fingerprint: "frozen-failure",
            actions: [gameAction(.advanceMissionComplete)]
        )) == .stop(.actionDidNotAdvance(intent: .advanceMissionFailure)))
        #expect(controller.actionsIssued == 1)
    }

    @Test("Only the exact pending unposted request can start acknowledgement")
    func postedActionMarkingIsOneShotAndBounded() {
        var controller = makeController(policy: policy(
            actionCooldown: 0,
            postActionTimeout: 5
        ))
        let request = requireAction(controller.consume(makeSnapshot(
            state: .battleEncounterPrompt,
            time: 1,
            fingerprint: "prompt",
            actions: [gameAction(.closeBattlePrompt)]
        )))!
        let differentRequest = AutoLevelActionRequest(
            requestID: request.requestID + 1,
            intent: request.intent,
            target: request.target,
            observedState: request.observedState,
            frameFingerprint: request.frameFingerprint,
            completedCycles: request.completedCycles
        )

        let markedDifferentRequest = controller.markActionPosted(differentRequest, at: 2)
        #expect(!markedDifferentRequest)
        let markedAtNaN = controller.markActionPosted(request, at: .nan)
        #expect(!markedAtNaN)
        let markedBeforeIssue = controller.markActionPosted(request, at: 0.9)
        #expect(!markedBeforeIssue)
        let markedAtDeadline = controller.markActionPosted(request, at: 6)
        #expect(!markedAtDeadline)
        let marked = controller.markActionPosted(request, at: 2)
        #expect(marked)
        let markedTwice = controller.markActionPosted(request, at: 2.1)
        #expect(!markedTwice)
        let cancelledAfterPost = controller.cancelUnpostedActionForObservedModal(
            request,
            observedState: .wideModalOneButton
        )
        #expect(!cancelledAfterPost)
    }

    @Test("A changed frame in the same modal waits for a state transition without replay")
    func changedFrameSameStateWaits() {
        var controller = makeController(policy: policy(postActionTimeout: 5))
        _ = controller.consume(makeSnapshot(
            state: .battleEncounterPrompt,
            time: 1,
            fingerprint: "before",
            actions: [gameAction(.closeBattlePrompt)]
        ))

        let decision = controller.consume(makeSnapshot(
            state: .battleEncounterPrompt,
            time: 2,
            fingerprint: "animation",
            actions: [gameAction(.closeBattlePrompt)]
        ))

        #expect(decision == .wait(.awaitingStateChange(intent: .closeBattlePrompt)))
        #expect(controller.actionsIssued == 1)
    }

    @Test("A changed result frame with the same target does not replay advance")
    func sameResultTargetDoesNotReplay() {
        var controller = makeController(policy: policy(actionCooldown: 0))
        let target = NormalizedRect(x: 0.02, y: 0.19, width: 0.05, height: 0.02)
        let selected = makeSnapshot(
            state: .missionCompleteRepeatSelected,
            time: 1,
            fingerprint: "result-before",
            actions: [gameAction(.advanceMissionComplete, rect: target)]
        )
        _ = controller.consume(selected)
        #expect(requireAction(controller.consume(selected))?.intent == .advanceMissionSuccess)

        let animated = makeSnapshot(
            state: .missionCompleteRepeatSelected,
            time: 2,
            fingerprint: "result-animation",
            actions: [gameAction(
                .advanceMissionComplete,
                rect: NormalizedRect(x: 0.021, y: 0.191, width: 0.05, height: 0.02)
            )]
        )
        #expect(controller.consume(animated) == .wait(.awaitingStateChange(
            intent: .advanceMissionSuccess
        )))
        #expect(controller.actionsIssued == 1)
    }

    @Test("An explicit EXP-to-loot identity change authorizes the same top arrow once more")
    func changedResultPageIdentityAdvancesNextPage() {
        var controller = makeController(policy: policy(actionCooldown: 0))
        let topArrow = NormalizedRect(x: 0.02, y: 0.19, width: 0.05, height: 0.02)
        let measuredLootDoubleTwo = NormalizedRect(
            x: 0.02463054162561577,
            y: 0.19999999995006246,
            width: 0.04433497536945813,
            height: 0.008988764044943753
        )
        let firstPage = makeSnapshot(
            state: .missionCompleteRepeatSelected,
            time: 1,
            fingerprint: "experience-page",
            actions: [gameAction(
                .advanceMissionComplete,
                rect: topArrow
            )]
        )
        _ = controller.consume(firstPage)
        _ = controller.consume(firstPage)

        var lootEvidence = resultPageEvidence(.missionLootPage, text: "獲得拾得物")
        lootEvidence.append(GameStateEvidence(
            kind: .missionCompleteAdvance,
            observation: OCRTextObservation(
                text: "22",
                rect: measuredLootDoubleTwo,
                confidence: 0.30000001192092896
            ),
            detail: "22"
        ))
        let nextPage = makeSnapshot(
            state: .missionCompleteRepeatSelected,
            time: 2,
            fingerprint: "loot-page",
            evidence: lootEvidence,
            actions: [gameAction(
                .advanceMissionComplete,
                rect: measuredLootDoubleTwo,
                sourceText: "22"
            )]
        )
        let request = requireAction(controller.consume(nextPage))
        #expect(request?.intent == .advanceMissionSuccess)
        #expect(request?.target.sourceText == "22")
        #expect(request?.target.point == measuredLootDoubleTwo.center)
        #expect(request?.requestID == 2)
        #expect(controller.completedCycles == 1)
        #expect(controller.actionsIssued == 2)
    }

    @Test("A classifier-produced zero-OCR loot fallback advances after the EXP page exactly once")
    func changedResultPageIdentityUsesMeasuredLootFallback() {
        var controller = makeController(policy: policy(actionCooldown: 0))
        let firstPage = makeSnapshot(
            state: .missionCompleteRepeatSelected,
            time: 1,
            fingerprint: "experience-before-zero-ocr-loot",
            actions: [gameAction(.advanceMissionComplete)]
        )
        _ = controller.consume(firstPage)
        _ = controller.consume(firstPage)

        let fallbackClassification = measuredLootFallbackClassification()
        let lootPage = AutoLevelSnapshot(
            classification: fallbackClassification,
            runtime: AutoLevelRuntimeMetadata(
                observedAt: 2,
                windowIdentity: testWindow,
                frameFingerprint: "zero-ocr-loot-page"
            )
        )
        let request = requireAction(controller.consume(lootPage))
        #expect(request?.intent == .advanceMissionSuccess)
        #expect(
            request?.target.sourceText
                == GameStateClassifier.measuredLootTopAdvanceSentinel
        )
        #expect(request?.target.rect == GameStateClassifier.measuredLootTopAdvanceRect)
        #expect(request?.target.point == GameStateClassifier.measuredLootTopAdvanceRect.center)
        #expect(request?.requestID == 2)
        #expect(controller.completedCycles == 1)
        #expect(controller.actionsIssued == 2)
    }

    @Test("A supplemental measured fallback cannot bypass its classifier action and evidence")
    func supplementalMeasuredLootFallbackCannotBypassClassifier() {
        let target = AutoLevelActionTarget(
            name: GameTargetName.missionCompleteAdvance.rawValue,
            sourceText: GameStateClassifier.measuredLootTopAdvanceSentinel,
            rect: GameStateClassifier.measuredLootTopAdvanceRect
        )
        let fallbackEvidence = GameStateEvidence(
            kind: .missionCompleteAdvanceMeasuredFallback,
            observation: nil,
            detail: GameStateClassifier.measuredLootTopAdvanceSentinel
        )

        var noActionController = makeController(policy: policy(actionCooldown: 0))
        let noClassifierAction = makeSnapshot(
            state: .missionCompleteRepeatSelected,
            time: 1,
            fingerprint: "supplemental-measured-fallback",
            evidence: resultPageEvidence(.missionLootPage, text: "獲得拾得物")
                + [fallbackEvidence],
            supplemental: [.init(intent: .advanceMissionSuccess, target: target)]
        )
        _ = noActionController.consume(noClassifierAction)
        #expect(noActionController.consume(noClassifierAction) == .wait(.transientState(
            kind: .ambiguousAction,
            observationCount: 1
        )))
        #expect(noActionController.actionsIssued == 0)

        var expController = makeController(policy: policy(actionCooldown: 0))
        let expSentinel = makeSnapshot(
            state: .missionCompleteRepeatSelected,
            time: 1,
            fingerprint: "exp-measured-fallback",
            evidence: resultPageEvidence(.missionExperiencePage, text: "獲得經驗值")
                + [fallbackEvidence],
            actions: [AllowedGameAction(
                name: .advanceMissionComplete,
                target: NamedGameTarget(
                    name: .missionCompleteAdvance,
                    sourceText: GameStateClassifier.measuredLootTopAdvanceSentinel,
                    rect: GameStateClassifier.measuredLootTopAdvanceRect,
                    point: GameStateClassifier.measuredLootTopAdvanceRect.center
                )
            )]
        )
        _ = expController.consume(expSentinel)
        #expect(expController.consume(expSentinel) == .wait(.transientState(
            kind: .ambiguousAction,
            observationCount: 1
        )))
        #expect(expController.actionsIssued == 0)
    }

    @Test("A synthetic loot-page 22 without matching OCR evidence cannot bypass the controller")
    func syntheticLootDoubleTwoCannotBypassController() {
        var controller = makeController(policy: policy(actionCooldown: 0))
        let measured = NormalizedRect(
            x: 0.02463,
            y: 0.2000,
            width: 0.04433,
            height: 0.00899
        )
        let snapshot = makeSnapshot(
            state: .missionCompleteRepeatSelected,
            time: 1,
            fingerprint: "synthetic-loot-22",
            evidence: resultPageEvidence(.missionLootPage, text: "獲得拾得物"),
            actions: [gameAction(.advanceMissionComplete, rect: measured, sourceText: "22")]
        )

        #expect(controller.consume(snapshot) == .completedCycle(.init(
            count: 1,
            outcome: .success
        )))
        #expect(controller.consume(snapshot) == .wait(.transientState(
            kind: .ambiguousAction,
            observationCount: 1
        )))
        #expect(controller.actionsIssued == 0)
    }

    @Test("A supplemental bottom arrow cannot bypass the result classifier")
    func supplementalBottomAdvanceCannotBypassClassifier() {
        var controller = makeController(policy: policy(actionCooldown: 0))
        let bottom = NormalizedRect(x: 0.02, y: 0.70, width: 0.05, height: 0.02)
        let snapshot = makeSnapshot(
            state: .missionCompleteRepeatSelected,
            time: 1,
            fingerprint: "bottom-bypass",
            actions: [],
            supplemental: [AutoLevelActionCandidate(
                intent: .advanceMissionSuccess,
                target: AutoLevelActionTarget(
                    name: GameTargetName.missionCompleteAdvance.rawValue,
                    sourceText: ">>",
                    rect: bottom
                )
            )]
        )

        #expect(controller.consume(snapshot) == .completedCycle(.init(
            count: 1,
            outcome: .success
        )))
        #expect(controller.consume(snapshot) == .wait(.transientState(
            kind: .ambiguousAction,
            observationCount: 1
        )))
        #expect(controller.actionsIssued == 0)
    }

    @Test("A supplemental top arrow cannot bypass missing page identity")
    func supplementalTopAdvanceCannotBypassMissingPageIdentity() {
        var controller = makeController(policy: policy(actionCooldown: 0))
        let top = NormalizedRect(x: 0.02, y: 0.19, width: 0.05, height: 0.02)
        let snapshot = makeSnapshot(
            state: .missionCompleteRepeatSelected,
            time: 1,
            fingerprint: "missing-page-identity",
            evidence: resultPageEvidence(nil),
            actions: [],
            supplemental: [AutoLevelActionCandidate(
                intent: .advanceMissionSuccess,
                target: AutoLevelActionTarget(
                    name: GameTargetName.missionCompleteAdvance.rawValue,
                    sourceText: ">>",
                    rect: top
                )
            )],
            addDefaultResultPageEvidence: false
        )

        #expect(controller.consume(snapshot) == .completedCycle(.init(
            count: 1,
            outcome: .success
        )))
        #expect(controller.consume(snapshot) == .wait(.transientState(
            kind: .missingAction,
            observationCount: 1
        )))
        #expect(controller.actionsIssued == 0)
    }

    @Test("A loot-to-EXP change cannot replay the shared top arrow")
    func reverseResultPageIdentityDoesNotReplay() {
        var controller = makeController(policy: policy(actionCooldown: 0))
        let top = NormalizedRect(x: 0.02, y: 0.19, width: 0.05, height: 0.02)
        let loot = makeSnapshot(
            state: .missionCompleteRepeatSelected,
            time: 1,
            fingerprint: "loot-first",
            evidence: resultPageEvidence(.missionLootPage, text: "獲得拾得物"),
            actions: [gameAction(.advanceMissionComplete, rect: top)]
        )
        _ = controller.consume(loot)
        _ = controller.consume(loot)

        let experience = makeSnapshot(
            state: .missionCompleteRepeatSelected,
            time: 2,
            fingerprint: "experience-second",
            evidence: resultPageEvidence(.missionExperiencePage, text: "獲得經驗值"),
            actions: [gameAction(.advanceMissionComplete, rect: top)]
        )
        #expect(controller.consume(experience) == .wait(.awaitingStateChange(
            intent: .advanceMissionSuccess
        )))
        #expect(controller.actionsIssued == 1)
    }

    @Test("Successful result counts once, selects repeat, then uses success advance")
    func successfulCycleSequence() {
        var controller = makeController(policy: policy(actionCooldown: 0))
        let result = makeSnapshot(
            state: .missionComplete,
            time: 1,
            fingerprint: "success-result",
            actions: [gameAction(.selectMissionRepeat)]
        )

        #expect(controller.consume(result) == .completedCycle(.init(count: 1, outcome: .success)))
        #expect(requireAction(controller.consume(result))?.intent == .selectMissionRepeat)

        let selected = makeSnapshot(
            state: .missionCompleteRepeatSelected,
            time: 2,
            fingerprint: "success-selected",
            actions: [gameAction(.advanceMissionComplete)]
        )
        #expect(requireAction(controller.consume(selected))?.intent == .advanceMissionSuccess)
        #expect(controller.completedCycles == 1)
    }

    @Test("A selected result cannot regress into the repeat toggle within the same episode")
    func selectedResultLatchPreventsReverseToggle() {
        for pair in [
            (GameState.missionCompleteRepeatSelected, GameState.missionComplete),
            (.missionCompleteRepeatSelected, .missionFailed),
            (.missionFailedRepeatSelected, .missionFailed),
            (.missionFailedRepeatSelected, .missionComplete),
        ] {
            var controller = makeController(policy: policy(
                actionCooldown: 0,
                uncertainStateGraceDuration: 10,
                uncertainStateGraceSnapshots: 3
            ))
            let selected = makeSnapshot(
                state: pair.0,
                time: 1,
                fingerprint: "selected",
                actions: [gameAction(.advanceMissionComplete)]
            )
            let expectedOutcome: AutoLevelCycleOutcome = pair.0 == .missionCompleteRepeatSelected
                ? .success
                : .failure
            #expect(controller.consume(selected) == .completedCycle(.init(
                count: 1,
                outcome: expectedOutcome
            )))

            let regressed = makeSnapshot(
                state: pair.1,
                time: 2,
                fingerprint: "selected-marker-missed",
                actions: [gameAction(.selectMissionRepeat)]
            )
            #expect(controller.consume(regressed) == .wait(.transientState(
                kind: .missingAction,
                observationCount: 1
            )))
            #expect(controller.actionsIssued == 0)
        }
    }

    @Test("The next battle clears the selected-result latch")
    func nextBattleClearsSelectedResultLatch() {
        var controller = makeController(policy: policy(actionCooldown: 0))
        let selected = makeSnapshot(
            state: .missionCompleteRepeatSelected,
            time: 1,
            fingerprint: "selected-result",
            actions: [gameAction(.advanceMissionComplete)]
        )
        #expect(controller.consume(selected) == .completedCycle(.init(
            count: 1,
            outcome: .success
        )))

        let battle = makeSnapshot(
            state: .battle,
            time: 2,
            fingerprint: "next-battle",
            battleSessionID: "battle-2",
            allAutoStatus: .active
        )
        #expect(controller.consume(battle) == .wait(.battleInProgress))

        let nextResult = makeSnapshot(
            state: .missionComplete,
            time: 3,
            fingerprint: "next-result",
            actions: [gameAction(.selectMissionRepeat)]
        )
        #expect(controller.consume(nextResult) == .completedCycle(.init(
            count: 2,
            outcome: .success
        )))
        #expect(requireAction(controller.consume(nextResult))?.intent == .selectMissionRepeat)
    }

    @Test("Failed result counts once, selects repeat, then uses failure top advance")
    func failedCycleSequence() {
        var controller = makeController(policy: policy(actionCooldown: 0))
        let result = makeSnapshot(
            state: .missionFailed,
            time: 1,
            fingerprint: "failure-result",
            actions: [gameAction(.selectMissionRepeat)]
        )

        #expect(controller.consume(result) == .completedCycle(.init(count: 1, outcome: .failure)))
        #expect(requireAction(controller.consume(result))?.intent == .selectMissionRepeat)

        let selected = makeSnapshot(
            state: .missionFailedRepeatSelected,
            time: 2,
            fingerprint: "failure-selected",
            actions: [gameAction(.advanceMissionComplete)]
        )
        #expect(requireAction(controller.consume(selected))?.intent == .advanceMissionFailure)
    }

    @Test("An unposted repeat action can be cancelled after its exact forward success transition")
    func cancelsUnpostedSuccessRepeatAfterForwardTransition() {
        var controller = makeController(policy: policy(actionCooldown: 0))
        let result = makeSnapshot(
            state: .missionComplete,
            time: 1,
            fingerprint: "success-before-confirmation",
            actions: [gameAction(.selectMissionRepeat)]
        )
        _ = controller.consume(result)
        let staleRequest = requireAction(controller.consume(result))
        #expect(staleRequest != nil)

        let cancelled = staleRequest.map {
            controller.cancelUnpostedActionAfterForwardResultTransition(
                $0,
                observedState: .missionCompleteRepeatSelected
            )
        }
        #expect(cancelled == true)

        let selected = makeSnapshot(
            state: .missionCompleteRepeatSelected,
            time: 2,
            // The live race produced different OCR states from the exact same pixels. Explicit
            // cancellation must bypass pending-action fingerprint debounce before a fresh poll.
            fingerprint: "success-before-confirmation",
            actions: [gameAction(.advanceMissionComplete)]
        )
        let nextRequest = requireAction(controller.consume(selected))
        #expect(nextRequest?.intent == .advanceMissionSuccess)
        #expect(nextRequest?.requestID == 2)
        #expect(controller.actionsIssued == 2)
        #expect(controller.completedCycles == 1)
    }

    @Test("An unposted repeat action can be cancelled after its exact forward failure transition")
    func cancelsUnpostedFailureRepeatAfterForwardTransition() {
        var controller = makeController(
            policy: policy(actionCooldown: 0)
        )
        let result = makeSnapshot(
            state: .missionFailed,
            time: 1,
            fingerprint: "failure-before-confirmation",
            actions: [gameAction(.selectMissionRepeat)]
        )
        _ = controller.consume(result)
        let staleRequest = requireAction(controller.consume(result))
        #expect(staleRequest != nil)

        let cancelled = staleRequest.map {
            controller.cancelUnpostedActionAfterForwardResultTransition(
                $0,
                observedState: .missionFailedRepeatSelected
            )
        }
        #expect(cancelled == true)

        let selected = makeSnapshot(
            state: .missionFailedRepeatSelected,
            time: 2,
            fingerprint: "failure-before-confirmation",
            actions: [gameAction(.advanceMissionComplete)]
        )
        let nextRequest = requireAction(controller.consume(selected))
        #expect(nextRequest?.intent == .advanceMissionFailure)
        #expect(nextRequest?.requestID == 2)
        #expect(controller.actionsIssued == 2)
        #expect(controller.completedCycles == 1)
    }

    @Test("A modal appearing during preflight cancels stale coordinates for fresh authorization")
    func cancelsUnpostedActionForNewGeometryModal() {
        var controller = makeController(policy: policy(actionCooldown: 0))
        let staleRequest = requireAction(controller.consume(makeSnapshot(
            state: .battleEncounterPrompt,
            time: 1,
            fingerprint: "encounter",
            actions: [gameAction(.closeBattlePrompt)]
        )))
        #expect(staleRequest != nil)

        let cancelled = staleRequest.map {
            controller.cancelUnpostedActionForObservedModal(
                $0,
                observedState: .wideModalOneButton
            )
        }
        #expect(cancelled == true)

        let freshRequest = requireAction(controller.consume(makeSnapshot(
            state: .wideModalOneButton,
            time: 2,
            fingerprint: "new-modal",
            actions: [gameAction(.pressWideModalTopButton)]
        )))
        #expect(freshRequest?.intent == .pressWideModalTopButton)
        #expect(freshRequest?.requestID == 2)
        #expect(controller.actionsIssued == 2)

        let refused = freshRequest.map {
            controller.cancelUnpostedActionForObservedModal(
                $0,
                observedState: .unknown
            )
        }
        #expect(refused == false)
    }

    @Test("Unposted action cancellation rejects every non-equivalent transition")
    func rejectsNonEquivalentUnpostedTransition() {
        var controller = makeController(policy: policy(actionCooldown: 0))
        let result = makeSnapshot(
            state: .missionComplete,
            time: 1,
            fingerprint: "success-before-unsafe-transition",
            actions: [gameAction(.selectMissionRepeat)]
        )
        _ = controller.consume(result)
        let staleRequest = requireAction(controller.consume(result))
        #expect(staleRequest != nil)

        let cancelled = staleRequest.map {
            controller.cancelUnpostedActionAfterForwardResultTransition(
                $0,
                observedState: .missionFailedRepeatSelected
            )
        }
        #expect(cancelled == false)

        let unrelated = makeSnapshot(
            state: .missionFailedRepeatSelected,
            time: 2,
            fingerprint: "cross-outcome-transition",
            actions: [gameAction(.advanceMissionComplete)]
        )
        #expect(controller.consume(unrelated) == .stop(.unexpectedTransition(
            intent: .selectMissionRepeat,
            from: .missionComplete,
            to: .missionFailedRepeatSelected
        )))
        #expect(controller.actionsIssued == 1)
    }

    @Test(
        "Unposted cancellation rejects its complete negative matrix without clearing pending",
        arguments: UnpostedCancellationRejectionCase.allCases
    )
    func unpostedCancellationNegativeMatrix(
        testCase: UnpostedCancellationRejectionCase
    ) {
        let comment = Comment(rawValue: testCase.rawValue)

        if testCase == .noPending {
            var controller = makeController(policy: policy(actionCooldown: 0))
            let action = gameAction(.selectMissionRepeat)
            let foreignRequest = AutoLevelActionRequest(
                requestID: 1,
                intent: .selectMissionRepeat,
                target: AutoLevelActionTarget(action.target),
                observedState: .missionComplete,
                frameFingerprint: "no-pending",
                completedCycles: 0
            )
            #expect(
                controller.cancelUnpostedActionAfterForwardResultTransition(
                    foreignRequest,
                    observedState: .missionCompleteRepeatSelected
                ) == false,
                comment
            )

            let ordinaryResult = makeSnapshot(
                state: .missionComplete,
                time: 1,
                fingerprint: "ordinary-result",
                actions: [action]
            )
            #expect(
                controller.consume(ordinaryResult)
                    == .completedCycle(.init(count: 1, outcome: .success)),
                comment
            )
            return
        }

        if testCase == .nonSelectIntent {
            var controller = makeController(policy: policy(actionCooldown: 0))
            let prompt = makeSnapshot(
                state: .battleEventPrompt,
                time: 1,
                fingerprint: "close-pending",
                actions: [gameAction(.closeBattlePrompt)]
            )
            guard let closeRequest = requireAction(controller.consume(prompt)) else {
                return
            }
            #expect(
                controller.cancelUnpostedActionAfterForwardResultTransition(
                    closeRequest,
                    observedState: .missionCompleteRepeatSelected
                ) == false,
                comment
            )

            let samePixels = makeSnapshot(
                state: .battle,
                time: 2,
                fingerprint: "close-pending",
                battleSessionID: "battle-1",
                allAutoStatus: .active
            )
            #expect(
                controller.consume(samePixels)
                    == .wait(.awaitingFrameChange(intent: .closeBattlePrompt)),
                comment
            )
            let freshBattle = makeSnapshot(
                state: .battle,
                time: 3,
                fingerprint: "close-fresh",
                battleSessionID: "battle-1",
                allAutoStatus: .active
            )
            #expect(controller.consume(freshBattle) == .wait(.battleInProgress), comment)
            return
        }

        var controller = makeController(policy: policy(actionCooldown: 0))
        let result = makeSnapshot(
            state: .missionComplete,
            time: 1,
            fingerprint: "repeat-pending",
            actions: [gameAction(.selectMissionRepeat)]
        )
        _ = controller.consume(result)
        guard let pendingRequest = requireAction(controller.consume(result)) else {
            return
        }

        let presentedRequest: AutoLevelActionRequest
        let observedState: GameState
        switch testCase {
        case .wrongRequestID:
            presentedRequest = AutoLevelActionRequest(
                requestID: pendingRequest.requestID + 1,
                intent: pendingRequest.intent,
                target: pendingRequest.target,
                observedState: pendingRequest.observedState,
                frameFingerprint: pendingRequest.frameFingerprint,
                completedCycles: pendingRequest.completedCycles
            )
            observedState = .missionCompleteRepeatSelected

        case .differentRequest:
            presentedRequest = AutoLevelActionRequest(
                requestID: pendingRequest.requestID,
                intent: pendingRequest.intent,
                target: pendingRequest.target,
                observedState: .missionFailed,
                frameFingerprint: "different-request",
                completedCycles: pendingRequest.completedCycles
            )
            observedState = .missionCompleteRepeatSelected

        case .observedUnknown:
            presentedRequest = pendingRequest
            observedState = .unknown
        case .observedInventoryFull:
            presentedRequest = pendingRequest
            observedState = .inventoryFull
        case .observedBattle:
            presentedRequest = pendingRequest
            observedState = .battle
        case .observedDefeat:
            presentedRequest = pendingRequest
            observedState = .defeat
        case .observedMissionComplete:
            presentedRequest = pendingRequest
            observedState = .missionComplete
        case .observedMissionFailed:
            presentedRequest = pendingRequest
            observedState = .missionFailed
        case .observedSelectedFailure:
            presentedRequest = pendingRequest
            observedState = .missionFailedRepeatSelected

        case .noPending, .nonSelectIntent:
            Issue.record("Case should have returned before the shared pending-action path")
            return
        }

        #expect(
            controller.cancelUnpostedActionAfterForwardResultTransition(
                presentedRequest,
                observedState: observedState
            ) == false,
            comment
        )

        let samePixelsSelected = makeSnapshot(
            state: .missionCompleteRepeatSelected,
            time: 2,
            fingerprint: "repeat-pending",
            actions: [gameAction(.advanceMissionComplete)]
        )
        #expect(
            controller.consume(samePixelsSelected)
                == .wait(.awaitingFrameChange(intent: .selectMissionRepeat)),
            comment
        )

        let freshSelected = makeSnapshot(
            state: .missionCompleteRepeatSelected,
            time: 3,
            fingerprint: "repeat-selected-fresh",
            actions: [gameAction(.advanceMissionComplete)]
        )
        let nextRequest = requireAction(controller.consume(freshSelected))
        #expect(nextRequest?.intent == .advanceMissionSuccess, comment)
        #expect(nextRequest?.requestID == 2, comment)
    }

    @Test("Result episode is counted once across selected and unselected frames")
    func resultEpisodeCountsOnce() {
        var controller = makeController(policy: policy(actionCooldown: 0))
        let result = makeSnapshot(
            state: .missionComplete,
            time: 1,
            fingerprint: "r1",
            actions: [gameAction(.selectMissionRepeat)]
        )
        _ = controller.consume(result)
        _ = controller.consume(result)
        _ = controller.consume(makeSnapshot(
            state: .missionCompleteRepeatSelected,
            time: 2,
            fingerprint: "r2",
            actions: [gameAction(.advanceMissionComplete)]
        ))

        #expect(controller.completedCycles == 1)
    }

    @Test("Loot collection uses yes candidate and never a generic confirmation")
    func confirmsLootCollection() {
        var controller = makeController()
        let decision = controller.consume(makeSnapshot(
            state: .lootCollectionConfirmation,
            time: 1,
            fingerprint: "loot",
            actions: [gameAction(.confirmLootCollection)]
        ))

        #expect(requireAction(decision)?.intent == .confirmLootCollection)
    }

    @Test("Recruitment always selects the explicit top recruit action")
    func recruitsAdventurer() {
        var controller = makeController()
        let decision = controller.consume(makeSnapshot(
            state: .adventurerRecruitment,
            time: 1,
            fingerprint: "recruit",
            actions: [gameAction(.recruitAdventurer)]
        ))

        #expect(requireAction(decision)?.intent == .recruitAdventurer)
    }

    @Test("Result episode survives loot and recruitment until the next battle family")
    func resultEpisodeSurvivesPostResultModals() {
        var controller = makeController(policy: policy(actionCooldown: 0))
        let result = makeSnapshot(
            state: .missionCompleteRepeatSelected,
            time: 1,
            fingerprint: "result-before-modals",
            actions: [gameAction(.advanceMissionComplete)]
        )

        #expect(controller.consume(result) == .completedCycle(.init(
            count: 1,
            outcome: .success
        )))
        #expect(requireAction(controller.consume(result))?.intent == .advanceMissionSuccess)

        let loot = makeSnapshot(
            state: .lootCollectionConfirmation,
            time: 2,
            fingerprint: "loot-modal",
            actions: [gameAction(.confirmLootCollection)]
        )
        #expect(requireAction(controller.consume(loot))?.intent == .confirmLootCollection)
        #expect(controller.completedCycles == 1)

        let adventurer = makeSnapshot(
            state: .adventurerRecruitment,
            time: 3,
            fingerprint: "adventurer-modal",
            actions: [gameAction(.recruitAdventurer)]
        )
        #expect(requireAction(controller.consume(adventurer))?.intent == .recruitAdventurer)
        #expect(controller.completedCycles == 1)

        let sameResult = makeSnapshot(
            state: .missionCompleteRepeatSelected,
            time: 4,
            fingerprint: "same-result-after-recruit",
            actions: [gameAction(.advanceMissionComplete)]
        )
        #expect(requireAction(controller.consume(sameResult))?.intent == .advanceMissionSuccess)
        #expect(controller.completedCycles == 1)

        let battle = makeSnapshot(
            state: .battle,
            time: 5,
            fingerprint: "next-battle",
            battleSessionID: "next-battle",
            allAutoStatus: .active
        )
        #expect(controller.consume(battle) == .wait(.battleInProgress))
        #expect(controller.completedCycles == 1)

        let nextResult = makeSnapshot(
            state: .missionComplete,
            time: 6,
            fingerprint: "next-result",
            actions: [gameAction(.selectMissionRepeat)]
        )
        #expect(controller.consume(nextResult) == .completedCycle(.init(
            count: 2,
            outcome: .success
        )))
    }

    @Test("State and action intent must agree")
    func refusesCrossStateAction() {
        var controller = makeController(policy: policy(
            uncertainStateGraceDuration: 10,
            uncertainStateGraceSnapshots: 3
        ))
        let decision = controller.consume(makeSnapshot(
            state: .missionComplete,
            time: 1,
            fingerprint: "wrong-action",
            actions: [gameAction(.confirmLootCollection)]
        ))
        #expect(decision == .completedCycle(.init(count: 1, outcome: .success)))

        let second = controller.consume(makeSnapshot(
            state: .missionComplete,
            time: 1.1,
            fingerprint: "wrong-action",
            actions: [gameAction(.confirmLootCollection)]
        ))
        #expect(second == .wait(.transientState(kind: .missingAction, observationCount: 1)))
        #expect(controller.actionsIssued == 0)
    }

    @Test("Action cooldown blocks a second transition click")
    func appliesActionCooldown() {
        var controller = makeController(policy: policy(actionCooldown: 2))
        _ = controller.consume(makeSnapshot(
            state: .battleEncounterPrompt,
            time: 1,
            fingerprint: "prompt",
            actions: [gameAction(.closeBattlePrompt)]
        ))

        let battle = makeSnapshot(
            state: .battle,
            time: 2,
            fingerprint: "battle",
            actions: [gameAction(.enableAutoBattle)],
            battleSessionID: "b1",
            allAutoStatus: .active
        )
        #expect(controller.consume(battle) == .wait(.battleInProgress))
        #expect(controller.actionsIssued == 1)
    }

    @Test("Inactive or unknown all-auto metadata can never request the toggle")
    func neverRequestsAllAutoToggle() {
        var inactiveController = makeController(policy: policy(actionCooldown: 0))
        let inactive = inactiveController.consume(makeSnapshot(
            state: .battle,
            time: 1,
            fingerprint: "inactive",
            actions: [gameAction(.enableAutoBattle)],
            battleSessionID: "battle-1",
            allAutoStatus: .inactive
        ))
        #expect(inactive == .stop(.allAutoBecameInactive(battleSessionID: "battle-1")))
        #expect(inactiveController.actionsIssued == 0)

        var unknownController = makeController(policy: policy(actionCooldown: 0))
        let unknown = unknownController.consume(makeSnapshot(
            state: .battle,
            time: 1,
            fingerprint: "unknown",
            actions: [gameAction(.enableAutoBattle)],
            battleSessionID: "battle-1",
            allAutoStatus: .unknown
        ))
        #expect(unknown == .wait(.transientState(
            kind: .battleMetadataUnknown,
            observationCount: 1
        )))
        #expect(unknownController.actionsIssued == 0)
    }

    @Test("All-auto may complete the mission before the next poll")
    func autoCanTransitionDirectlyToMissionComplete() {
        var controller = makeController(policy: policy(actionCooldown: 0))
        _ = controller.consume(makeSnapshot(
            state: .battle,
            time: 1,
            fingerprint: "battle-before-auto",
            actions: [gameAction(.enableAutoBattle)],
            battleSessionID: "battle-1",
            allAutoStatus: .active
        ))

        let result = makeSnapshot(
            state: .missionComplete,
            time: 2,
            fingerprint: "instant-success",
            actions: [gameAction(.selectMissionRepeat)]
        )
        #expect(controller.consume(result) == .completedCycle(.init(
            count: 1,
            outcome: .success
        )))
        #expect(controller.actionsIssued == 0)
    }

    @Test("All-auto may reach a failed result before the next poll")
    func autoCanTransitionDirectlyToMissionFailure() {
        var controller = makeController(policy: policy(actionCooldown: 0))
        _ = controller.consume(makeSnapshot(
            state: .battle,
            time: 1,
            fingerprint: "battle-before-auto",
            actions: [gameAction(.enableAutoBattle)],
            battleSessionID: "battle-1",
            allAutoStatus: .active
        ))

        let result = makeSnapshot(
            state: .missionFailed,
            time: 2,
            fingerprint: "instant-failure",
            actions: [gameAction(.selectMissionRepeat)]
        )
        #expect(controller.consume(result) == .completedCycle(.init(
            count: 1,
            outcome: .failure
        )))
        #expect(controller.actionsIssued == 0)
    }

    @Test("Every new default-on battle session remains click-free")
    func defaultAutoForNewBattleSession() {
        var controller = makeController(policy: policy(actionCooldown: 0))
        #expect(controller.consume(makeSnapshot(
            state: .battle,
            time: 1,
            fingerprint: "b1-before",
            actions: [gameAction(.enableAutoBattle)],
            battleSessionID: "b1",
            allAutoStatus: .active
        )) == .wait(.battleInProgress))

        let decision = controller.consume(makeSnapshot(
            state: .battle,
            time: 2,
            fingerprint: "b2-before",
            actions: [gameAction(.enableAutoBattle)],
            battleSessionID: "b2",
            allAutoStatus: .active
        ))
        #expect(decision == .wait(.battleInProgress))
        #expect(controller.actionsIssued == 0)
    }

    @Test("A default-on battle never toggles the visible all-auto control")
    func observesAlreadyActiveAuto() {
        var controller = makeController()
        #expect(controller.consume(makeSnapshot(
            state: .battle,
            time: 1,
            fingerprint: "active",
            actions: [gameAction(.enableAutoBattle)],
            battleSessionID: "b1",
            allAutoStatus: .active
        )) == .wait(.battleInProgress))

        #expect(controller.consume(makeSnapshot(
            state: .battle,
            time: 2,
            fingerprint: "unknown",
            actions: [gameAction(.enableAutoBattle)],
            battleSessionID: "b1",
            allAutoStatus: .unknown
        )) == .wait(.allAutoAlreadyEnabled))
        #expect(controller.actionsIssued == 0)
    }

    @Test("All-auto becoming inactive after it was latched stops")
    func autoUnexpectedlyInactiveStops() {
        var controller = makeController()
        _ = controller.consume(makeSnapshot(
            state: .battle,
            time: 1,
            fingerprint: "active",
            battleSessionID: "b1",
            allAutoStatus: .active
        ))
        let decision = controller.consume(makeSnapshot(
            state: .battle,
            time: 2,
            fingerprint: "inactive",
            actions: [gameAction(.enableAutoBattle)],
            battleSessionID: "b1",
            allAutoStatus: .inactive
        ))

        #expect(decision == .stop(.allAutoBecameInactive(battleSessionID: "b1")))
    }

    @Test("An OCR-only external retreat confirmation remains unauthorized without geometry")
    func externalOCRRetreatConfirmationStops() {
        var controller = makeController()
        let decision = controller.consume(makeSnapshot(
            state: .retreatConfirmation,
            time: 1,
            fingerprint: "retreat-confirm",
            gatedActions: [gatedAction(.confirmNoTalismanRetreat, .explicitRetreatConfirmation)]
        ))

        #expect(decision == .stop(.retreatConfirmationWasNotRequested))
        #expect(controller.actionsIssued == 0)
    }

    @Test("A posted recovery transaction may confirm the exact gated yes target once")
    func confirmsPostedRetreat() {
        var controller = makeController(policy: policy(actionCooldown: 0))
        guard let request = requireAction(controller.consume(makeSnapshot(
            state: .battle,
            time: 1,
            fingerprint: "stalled",
            gatedActions: [gatedAction(.openBattleRetreatConfirmation, .temporalDefeatRecovery)],
            battleStatus: .stalledAfterDefeat
        ))) else { return }
        let marked = controller.markActionPosted(request, at: 1.5)
        #expect(marked)
        let decision = controller.consume(makeSnapshot(
            state: .retreatConfirmation,
            time: 2,
            fingerprint: "retreat-confirm",
            gatedActions: [gatedAction(.confirmNoTalismanRetreat, .explicitRetreatConfirmation)]
        ))

        #expect(requireAction(decision)?.intent == .confirmRetreatWithoutTalisman)
        #expect(controller.actionsIssued == 2)
    }

    @Test("An unposted retreat cannot authorize an OCR-only confirmation")
    func unpostedRetreatDoesNotAuthorizeConfirmation() {
        var controller = makeController(policy: policy(actionCooldown: 0))
        guard let request = requireAction(controller.consume(makeSnapshot(
            state: .battle,
            time: 1,
            fingerprint: "stalled",
            gatedActions: [gatedAction(.openBattleRetreatConfirmation, .temporalDefeatRecovery)],
            battleStatus: .stalledAfterDefeat
        ))) else { return }
        #expect(request.intent == .requestRetreat)

        #expect(controller.consume(makeSnapshot(
            state: .retreatConfirmation,
            time: 2,
            fingerprint: "external-confirmation",
            gatedActions: [gatedAction(.confirmNoTalismanRetreat, .explicitRetreatConfirmation)]
        )) == .stop(.retreatConfirmationWasNotRequested))
        #expect(controller.actionsIssued == 1)
    }

    @Test("A posted retreat may reach either failure result directly and resume the next cycle",
          arguments: [GameState.missionFailed, .missionFailedRepeatSelected])
    func postedRetreatDirectFailureContinues(state: GameState) throws {
        var (controller, retreat) = try makePendingRetreatController(
            policy: policy(actionCooldown: 0)
        )
        let failureAt: (Double) -> AutoLevelSnapshot = { time in
            self.makeSnapshot(
                state: state,
                time: time,
                fingerprint: "direct-failure",
                actions: [self.gameAction(state == .missionFailed
                    ? .selectMissionRepeat : .advanceMissionComplete)]
            )
        }

        #expect(controller.consume(failureAt(2), allowNewActions: false)
            == .completedCycle(.init(count: 1, outcome: .failure)))
        #expect(controller.pendingActionAcknowledgementDeadline == nil)
        #expect(controller.actionsIssued == 1)
        let repostedRetreat = controller.markActionPosted(retreat, at: 2)
        #expect(!repostedRetreat)
        #expect(controller.consume(failureAt(2.5), allowNewActions: false)
            == .wait(.freshObservationRequired))
        #expect(controller.completedCycles == 1)
        #expect(controller.actionsIssued == 1)

        var advance = try #require(requireAction(controller.consume(failureAt(3))))
        #expect(advance.requestID == 2)
        #expect(advance.intent == (state == .missionFailed
            ? .selectMissionRepeat : .advanceMissionFailure))
        if state == .missionFailed {
            let selectionPosted = controller.markActionPosted(advance, at: 3.5)
            #expect(selectionPosted)
            advance = try #require(requireAction(controller.consume(makeSnapshot(
                state: .missionFailedRepeatSelected,
                time: 4,
                fingerprint: "failure-now-selected",
                actions: [gameAction(.advanceMissionComplete)]
            ))))
            #expect(advance.intent == .advanceMissionFailure)
        }
        #expect(controller.completedCycles == 1)
        #expect(controller.actionsIssued == (state == .missionFailed ? 3 : 2))
        let advancePosted = controller.markActionPosted(advance, at: 4.5)
        #expect(advancePosted)
        #expect(controller.consume(makeSnapshot(
            state: .battle,
            time: 5,
            fingerprint: "next-battle",
            allAutoStatus: .active
        )) == .wait(.battleInProgress))
        #expect(controller.consume(makeSnapshot(
            state: .missionFailed,
            time: 6,
            fingerprint: "next-failure",
            actions: [gameAction(.selectMissionRepeat)]
        )) == .completedCycle(.init(count: 2, outcome: .failure)))
    }

    @Test("A direct failure result does not acknowledge an unposted retreat",
          arguments: [GameState.missionFailed, .missionFailedRepeatSelected])
    func unpostedRetreatDirectFailureStops(state: GameState) throws {
        var (controller, _) = try makePendingRetreatController(posted: false)
        #expect(controller.consume(makeSnapshot(
            state: state,
            time: 2,
            fingerprint: "external-failure"
        )) == .stop(.unexpectedTransition(
            intent: .requestRetreat,
            from: .battle,
            to: state
        )))
        #expect(controller.completedCycles == 0)
        #expect(controller.actionsIssued == 1)
    }

    @Test("A direct failure after retreat grants no later OCR confirmation authorization",
          arguments: [GameState.missionFailed, .missionFailedRepeatSelected])
    func postedRetreatDirectFailureDoesNotAuthorizeConfirmation(state: GameState) throws {
        var (controller, _) = try makePendingRetreatController()
        #expect(controller.consume(makeSnapshot(
            state: state,
            time: 2,
            fingerprint: "direct-failure"
        )) == .completedCycle(.init(count: 1, outcome: .failure)))
        #expect(controller.consume(makeSnapshot(
            state: .retreatConfirmation,
            time: 3,
            fingerprint: "unrequested-confirmation",
            gatedActions: [gatedAction(.confirmNoTalismanRetreat, .explicitRetreatConfirmation)]
        )) == .stop(.retreatConfirmationWasNotRequested))
        #expect(controller.actionsIssued == 1)
    }

    @Test("A directly observed selected failure keeps the repeat toggle latched")
    func postedRetreatDirectSelectedFailureKeepsRepeatLatch() throws {
        var (controller, _) = try makePendingRetreatController()
        #expect(controller.consume(makeSnapshot(
            state: .missionFailedRepeatSelected,
            time: 2,
            fingerprint: "direct-selected-failure"
        )) == .completedCycle(.init(count: 1, outcome: .failure)))
        #expect(controller.consume(makeSnapshot(
            state: .missionFailed,
            time: 3,
            fingerprint: "selected-marker-missed",
            actions: [gameAction(.selectMissionRepeat)]
        )) == .wait(.transientState(kind: .missingAction, observationCount: 1)))
        #expect(controller.completedCycles == 1)
        #expect(controller.actionsIssued == 1)
    }

    @Test("Direct failure acknowledgement retains the original fingerprint and deadline guards")
    func postedRetreatDirectFailureKeepsAcknowledgementGuards() throws {
        var (controller, retreat) = try makePendingRetreatController()
        #expect(controller.pendingActionAcknowledgementDeadline == 9.5)
        #expect(controller.consume(makeSnapshot(
            state: .missionFailed,
            time: 2,
            fingerprint: retreat.frameFingerprint
        )) == .wait(.awaitingFrameChange(intent: .requestRetreat)))
        #expect(controller.completedCycles == 0)
        #expect(controller.pendingActionAcknowledgementDeadline == 9.5)
        #expect(controller.consume(makeSnapshot(
            state: .missionFailed,
            time: 9.5,
            fingerprint: "failure-at-deadline"
        )) == .stop(.actionDidNotAdvance(intent: .requestRetreat)))
        #expect(controller.completedCycles == 0)
        #expect(controller.actionsIssued == 1)
    }

    @Test("A posted retreat still rejects success results and stops on full inventory",
          arguments: [GameState.missionComplete, .missionCompleteRepeatSelected, .inventoryFull])
    func postedRetreatStillRejectsUnrelatedStates(state: GameState) throws {
        var (controller, _) = try makePendingRetreatController()
        let expected: AutoLevelStopReason = state == .inventoryFull
            ? .inventoryFull
            : .unexpectedTransition(intent: .requestRetreat, from: .battle, to: state)
        #expect(controller.consume(makeSnapshot(
            state: state,
            time: 2,
            fingerprint: "unrelated-result"
        )) == .stop(expected))
        #expect(controller.completedCycles == 0)
        #expect(controller.actionsIssued == 1)
    }

    @Test("A direct failure cannot acknowledge retreat from a different window")
    func postedRetreatDirectFailureRejectsWindowChange() throws {
        var (controller, _) = try makePendingRetreatController()
        let changedWindow = AutoLevelWindowIdentity(processID: 11, windowID: 33)
        #expect(controller.consume(makeSnapshot(
            state: .missionFailed,
            time: 2,
            fingerprint: "different-window-failure",
            windowIdentity: changedWindow
        )) == .stop(.windowIdentityChanged(expected: testWindow, actual: changedWindow)))
        #expect(controller.completedCycles == 0)
        #expect(controller.actionsIssued == 1)
    }

    @Test("A direct failure after retreat retains cycle, runtime, and action limits",
          arguments: ["cycles", "runtime", "actions"])
    func postedRetreatDirectFailureKeepsRunLimits(limit: String) throws {
        var (controller, _) = try makePendingRetreatController(policy: policy(
            maxCycles: limit == "cycles" ? 1 : 100,
            maxRuntime: limit == "runtime" ? 2 : 100,
            maxActions: limit == "actions" ? 1 : 100
        ))
        let result = makeSnapshot(
            state: .missionFailed,
            time: 2,
            fingerprint: "direct-failure",
            actions: [gameAction(.selectMissionRepeat)]
        )
        if limit == "cycles" {
            #expect(controller.consume(result) == .completedCycle(.init(count: 1, outcome: .failure)))
            #expect(controller.consume(result) == .stop(.maximumCyclesReached(limit: 1)))
        } else {
            #expect(controller.consume(result) == .stop(limit == "runtime"
                ? .maximumRuntimeReached(limit: 2) : .maximumActionsReached(limit: 1)))
            #expect(controller.completedCycles == 0)
        }
        #expect(controller.actionsIssued == 1)
    }

    @Test("Geometry-only modals carry the stalled-defeat recovery through its button sequence")
    func geometryRetreatRecoveryTransaction() {
        var controller = makeController(policy: policy(actionCooldown: 0))
        guard let request = requireAction(controller.consume(makeSnapshot(
            state: .battle,
            time: 1,
            fingerprint: "stalled",
            gatedActions: [gatedAction(.openBattleRetreatConfirmation, .temporalDefeatRecovery)],
            battleStatus: .stalledAfterDefeat
        ))) else { return }
        #expect(request.intent == .requestRetreat)
        let marked = controller.markActionPosted(request, at: 1.5)
        #expect(marked)

        #expect(requireAction(controller.consume(makeSnapshot(
            state: .wideModalTwoButtons,
            time: 2,
            fingerprint: "retreat-confirm",
            actions: [gameAction(.pressWideModalTopButton)]
        )))?.intent == .pressWideModalTopButton)

        #expect(requireAction(controller.consume(makeSnapshot(
            state: .wideModalOneButton,
            time: 3,
            fingerprint: "defeat-close",
            actions: [gameAction(.pressWideModalTopButton)]
        )))?.intent == .pressWideModalTopButton)

        #expect(controller.consume(makeSnapshot(
            state: .missionFailed,
            time: 4,
            fingerprint: "failed-result",
            actions: [gameAction(.selectMissionRepeat)]
        )) == .completedCycle(.init(count: 1, outcome: .failure)))
        #expect(controller.actionsIssued == 3)
    }

    @Test("Only temporal stalled-defeat metadata can request retreat")
    func temporalDefeatRequestsRetreat() {
        var controller = makeController()
        let normal = makeSnapshot(
            state: .battle,
            time: 1,
            fingerprint: "normal",
            gatedActions: [gatedAction(.openBattleRetreatConfirmation, .temporalDefeatRecovery)],
            battleSessionID: "b1",
            allAutoStatus: .active,
            battleStatus: .inProgress
        )
        #expect(controller.consume(normal) == .wait(.battleInProgress))

        let stalled = makeSnapshot(
            state: .battle,
            time: 2,
            fingerprint: "stalled",
            gatedActions: [gatedAction(.openBattleRetreatConfirmation, .temporalDefeatRecovery)],
            battleSessionID: "b1",
            allAutoStatus: .active,
            battleStatus: .stalledAfterDefeat
        )
        #expect(requireAction(controller.consume(stalled))?.intent == .requestRetreat)
    }

    @Test("A stalled-battle retreat the game never received retries twice before stopping")
    func retreatRequestHasThreeAttemptBound() throws {
        var controller = makeController(policy: policy(actionCooldown: 0, postActionTimeout: 3))
        let stalled: (Double) -> AutoLevelSnapshot = { time in
            self.makeSnapshot(
                state: .battle, time: time, fingerprint: "frozen-battle",
                gatedActions: [self.gatedAction(.openBattleRetreatConfirmation, .temporalDefeatRecovery)],
                battleSessionID: "b1", allAutoStatus: .active, battleStatus: .stalledAfterDefeat
            )
        }
        let first = try #require(requireAction(controller.consume(stalled(1))))
        #expect(first.intent == .requestRetreat)
        let firstPosted = controller.markActionPosted(first, at: 2)
        #expect(firstPosted)
        #expect(controller.consume(stalled(4.9)) == .wait(.awaitingFrameChange(intent: .requestRetreat)))
        let second = try #require(requireAction(controller.consume(stalled(5))))
        #expect(second.requestID == 2 && second.intent == .requestRetreat && second.target == first.target)
        let secondPosted = controller.markActionPosted(second, at: 6)
        #expect(secondPosted)
        let third = try #require(requireAction(controller.consume(stalled(9))))
        #expect(third.requestID == 3)
        let thirdPosted = controller.markActionPosted(third, at: 10)
        #expect(thirdPosted)
        #expect(controller.consume(stalled(13)) == .stop(.actionDidNotAdvance(intent: .requestRetreat)))
        #expect(controller.actionsIssued == 3)
    }

    @Test("A retried retreat still authorizes the confirmation sheet, which also retries")
    func retriedRetreatAuthorizesConfirmationRetry() throws {
        var controller = makeController(policy: policy(actionCooldown: 0, postActionTimeout: 3))
        let stalled: (Double) -> AutoLevelSnapshot = { time in
            self.makeSnapshot(
                state: .battle, time: time, fingerprint: "frozen-battle",
                gatedActions: [self.gatedAction(.openBattleRetreatConfirmation, .temporalDefeatRecovery)],
                battleSessionID: "b1", allAutoStatus: .active, battleStatus: .stalledAfterDefeat
            )
        }
        let sheet: (Double) -> AutoLevelSnapshot = { time in
            self.makeSnapshot(
                state: .retreatConfirmation, time: time, fingerprint: "sheet",
                gatedActions: [self.gatedAction(.confirmNoTalismanRetreat, .explicitRetreatConfirmation)]
            )
        }
        let first = try #require(requireAction(controller.consume(stalled(1))))
        let firstPosted = controller.markActionPosted(first, at: 2)
        #expect(firstPosted)
        let retry = try #require(requireAction(controller.consume(stalled(5))))
        #expect(retry.intent == .requestRetreat)
        let retryPosted = controller.markActionPosted(retry, at: 6)
        #expect(retryPosted)
        // The sheet acknowledges the retried retreat and is confirmed once.
        let confirmation = try #require(requireAction(controller.consume(sheet(7))))
        #expect(confirmation.intent == .confirmRetreatWithoutTalisman)
        let confirmationPosted = controller.markActionPosted(confirmation, at: 8)
        #expect(confirmationPosted)
        // A lost confirmation press leaves the same sheet: press it again, bounded.
        let confirmationRetry = try #require(requireAction(controller.consume(sheet(11))))
        #expect(confirmationRetry.intent == .confirmRetreatWithoutTalisman)
        #expect(confirmationRetry.target == confirmation.target)
        let confirmationRetryPosted = controller.markActionPosted(confirmationRetry, at: 12)
        #expect(confirmationRetryPosted)
        let thirdConfirmation = try #require(requireAction(controller.consume(sheet(15))))
        let thirdPosted = controller.markActionPosted(thirdConfirmation, at: 16)
        #expect(thirdPosted)
        #expect(controller.consume(sheet(19)) == .stop(.actionDidNotAdvance(intent: .confirmRetreatWithoutTalisman)))
        #expect(controller.actionsIssued == 5)
    }

    @Test("A timed-out retreat does not retry once the battle is no longer stalled")
    func retreatRetryRequiresStalledBattle() throws {
        var controller = makeController(policy: policy(actionCooldown: 0, postActionTimeout: 3))
        let first = try #require(requireAction(controller.consume(makeSnapshot(
            state: .battle, time: 1, fingerprint: "frozen-battle",
            gatedActions: [gatedAction(.openBattleRetreatConfirmation, .temporalDefeatRecovery)],
            battleSessionID: "b1", allAutoStatus: .active, battleStatus: .stalledAfterDefeat
        ))))
        let firstPosted = controller.markActionPosted(first, at: 2)
        #expect(firstPosted)
        #expect(controller.consume(makeSnapshot(
            state: .battle, time: 5, fingerprint: "frozen-battle",
            gatedActions: [gatedAction(.openBattleRetreatConfirmation, .temporalDefeatRecovery)],
            battleSessionID: "b1", allAutoStatus: .active, battleStatus: .inProgress
        )) == .stop(.actionDidNotAdvance(intent: .requestRetreat)))
    }

    @Test("Cancelling an unposted retreat resumes battle observations and preserves limits")
    func cancelledRetreatResumesObservations() {
        var controller = makeController(
            policy: policy(actionCooldown: 10)
        )
        guard let request = requireAction(controller.consume(makeSnapshot(
            state: .battle,
            time: 1,
            fingerprint: "stalled",
            gatedActions: [gatedAction(.openBattleRetreatConfirmation, .temporalDefeatRecovery)],
            battleStatus: .stalledAfterDefeat
        ))) else { return }

        let cancelled = controller.cancelUnpostedRetreat(request)
        #expect(cancelled)
        #expect(controller.actionsIssued == 1)
        #expect(controller.completedCycles == 0)
        let cancelledTwice = controller.cancelUnpostedRetreat(request)
        #expect(!cancelledTwice)
        let markedAfterCancellation = controller.markActionPosted(request, at: 2)
        #expect(!markedAfterCancellation)
        #expect(controller.consume(makeSnapshot(
            state: .battle,
            time: 2,
            fingerprint: "moving-again",
            allAutoStatus: .active
        )) == .wait(.battleInProgress))

        #expect(controller.consume(makeSnapshot(
            state: .battle,
            time: 3,
            fingerprint: "new-stall-during-cooldown",
            gatedActions: [gatedAction(.openBattleRetreatConfirmation, .temporalDefeatRecovery)],
            battleStatus: .stalledAfterDefeat
        )) == .wait(.actionCooldown(remaining: 8)))

        let newRequest = requireAction(controller.consume(makeSnapshot(
            state: .battle,
            time: 11,
            fingerprint: "new-confirmed-stall",
            gatedActions: [gatedAction(.openBattleRetreatConfirmation, .temporalDefeatRecovery)],
            battleStatus: .stalledAfterDefeat
        )))
        #expect(newRequest?.intent == .requestRetreat)
        #expect(newRequest?.requestID == request.requestID + 1)
        #expect(newRequest?.frameFingerprint == "new-confirmed-stall")
        #expect(controller.actionsIssued == 2)
    }

    @Test("A cancelled retreat does not authorize a later OCR-only confirmation")
    func cancelledRetreatDoesNotAuthorizeConfirmation() {
        var controller = makeController(policy: policy(actionCooldown: 0))
        guard let request = requireAction(controller.consume(makeSnapshot(
            state: .battle,
            time: 1,
            fingerprint: "stalled",
            gatedActions: [gatedAction(.openBattleRetreatConfirmation, .temporalDefeatRecovery)],
            battleStatus: .stalledAfterDefeat
        ))) else { return }

        let cancelled = controller.cancelUnpostedRetreat(request)
        #expect(cancelled)
        #expect(controller.consume(makeSnapshot(
            state: .retreatConfirmation,
            time: 2,
            fingerprint: "external-confirmation",
            gatedActions: [gatedAction(.confirmNoTalismanRetreat, .explicitRetreatConfirmation)]
        )) == .stop(.retreatConfirmationWasNotRequested))
        #expect(controller.actionsIssued == 1)
    }

    @Test(
        "Retreat cancellation requires every field of the pending request to match",
        arguments: ["requestID", "intent", "target", "observedState", "frameFingerprint", "completedCycles"]
    )
    func retreatCancellationRejectsDifferentRequest(changedField: String) {
        var controller = makeController()
        guard let request = requireAction(controller.consume(makeSnapshot(
            state: .battle,
            time: 1,
            fingerprint: "stalled",
            gatedActions: [gatedAction(.openBattleRetreatConfirmation, .temporalDefeatRecovery)],
            battleStatus: .stalledAfterDefeat
        ))) else { return }

        let differentTarget = AutoLevelActionTarget(
            name: request.target.name,
            sourceText: "different source text",
            rect: request.target.rect
        )
        let differentRequest = AutoLevelActionRequest(
            requestID: changedField == "requestID" ? request.requestID + 1 : request.requestID,
            intent: changedField == "intent" ? .closeBattlePrompt : request.intent,
            target: changedField == "target" ? differentTarget : request.target,
            observedState: changedField == "observedState" ? .defeat : request.observedState,
            frameFingerprint: changedField == "frameFingerprint" ? "different" : request.frameFingerprint,
            completedCycles: changedField == "completedCycles" ? 1 : request.completedCycles
        )

        let cancelledDifferentRequest = controller.cancelUnpostedRetreat(differentRequest)
        #expect(!cancelledDifferentRequest)
        #expect(controller.consume(makeSnapshot(
            state: .battle,
            time: 2,
            fingerprint: "moving-again",
            allAutoStatus: .active
        )) == .wait(.awaitingStateChange(intent: .requestRetreat)))
        let cancelled = controller.cancelUnpostedRetreat(request)
        #expect(cancelled)
        #expect(controller.actionsIssued == 1)
    }

    @Test("A posted retreat cannot be cancelled and retains its confirmation transaction")
    func postedRetreatCannotBeCancelled() {
        var controller = makeController(policy: policy(actionCooldown: 0))
        guard let request = requireAction(controller.consume(makeSnapshot(
            state: .battle,
            time: 1,
            fingerprint: "stalled",
            gatedActions: [gatedAction(.openBattleRetreatConfirmation, .temporalDefeatRecovery)],
            battleStatus: .stalledAfterDefeat
        ))) else { return }

        let marked = controller.markActionPosted(request, at: 2)
        #expect(marked)
        let cancelled = controller.cancelUnpostedRetreat(request)
        #expect(!cancelled)
        #expect(requireAction(controller.consume(makeSnapshot(
            state: .retreatConfirmation,
            time: 3,
            fingerprint: "requested-confirmation",
            gatedActions: [gatedAction(.confirmNoTalismanRetreat, .explicitRetreatConfirmation)]
        )))?.intent == .confirmRetreatWithoutTalisman)
    }

    @Test("Retreat cancellation cannot discard an unrelated pending action")
    func retreatCancellationRejectsNonRetreat() {
        var controller = makeController()
        guard let request = requireAction(controller.consume(makeSnapshot(
            state: .battleEventPrompt,
            time: 1,
            fingerprint: "prompt",
            actions: [gameAction(.closeBattlePrompt)]
        ))) else { return }

        let cancelled = controller.cancelUnpostedRetreat(request)
        #expect(!cancelled)
        #expect(controller.consume(makeSnapshot(
            state: .battleEventPrompt,
            time: 2,
            fingerprint: "prompt",
            actions: [gameAction(.closeBattlePrompt)]
        )) == .wait(.awaitingFrameChange(intent: .closeBattlePrompt)))
        #expect(controller.actionsIssued == 1)
    }

    @Test("A focus-deferred unposted action is discarded and re-requested from a newer frame")
    func foregroundDeferralDiscardsUnpostedAction() {
        var controller = makeController(policy: policy(actionCooldown: 10))
        guard let request = requireAction(controller.consume(makeSnapshot(
            state: .wideModalOneButton,
            time: 1,
            fingerprint: "prompt",
            actions: [gameAction(.pressWideModalTopButton)]
        ))) else { return }

        let differentRequest = AutoLevelActionRequest(
            requestID: request.requestID + 1,
            intent: request.intent,
            target: request.target,
            observedState: request.observedState,
            frameFingerprint: request.frameFingerprint,
            completedCycles: request.completedCycles
        )
        let cancelled = controller.cancelUnpostedActionForForegroundDeferral(differentRequest)
        #expect(!cancelled)
        let cancelled2 = controller.cancelUnpostedActionForForegroundDeferral(request)
        #expect(cancelled2)
        let cancelled3 = controller.cancelUnpostedActionForForegroundDeferral(request)
        #expect(!cancelled3)
        #expect(controller.actionsIssued == 1)
        let marked = controller.markActionPosted(request, at: 2)
        #expect(!marked)
        #expect(controller.consume(makeSnapshot(
            state: .wideModalOneButton,
            time: 3,
            fingerprint: "prompt",
            actions: [gameAction(.pressWideModalTopButton)]
        )) == .wait(.actionCooldown(remaining: 8)))

        let renewed = requireAction(controller.consume(makeSnapshot(
            state: .wideModalOneButton,
            time: 12,
            fingerprint: "prompt-later",
            actions: [gameAction(.pressWideModalTopButton)]
        )))
        #expect(renewed?.intent == .pressWideModalTopButton)
        #expect(renewed?.requestID == request.requestID + 1)
        #expect(renewed?.frameFingerprint == "prompt-later")
        #expect(controller.actionsIssued == 2)
    }

    @Test("A posted action cannot be discarded by focus deferral")
    func foregroundDeferralKeepsPostedAction() {
        var controller = makeController(policy: policy(actionCooldown: 0))
        guard let request = requireAction(controller.consume(makeSnapshot(
            state: .wideModalOneButton,
            time: 1,
            fingerprint: "prompt",
            actions: [gameAction(.pressWideModalTopButton)]
        ))) else { return }

        let marked = controller.markActionPosted(request, at: 2)
        #expect(marked)
        let cancelled = controller.cancelUnpostedActionForForegroundDeferral(request)
        #expect(!cancelled)
        let decision = controller.consume(makeSnapshot(
            state: .wideModalOneButton,
            time: 3,
            fingerprint: "prompt",
            actions: [gameAction(.pressWideModalTopButton)]
        ))
        guard case .wait = decision else {
            Issue.record("Expected the posted action to stay pending, got \(decision)")
            return
        }
        #expect(controller.actionsIssued == 1)
    }

    @Test("Focus deferral of a retreat discards its recovery confirmation")
    func foregroundDeferralOfRetreatDropsConfirmation() {
        var controller = makeController(policy: policy(actionCooldown: 0))
        guard let request = requireAction(controller.consume(makeSnapshot(
            state: .battle,
            time: 1,
            fingerprint: "stalled",
            gatedActions: [gatedAction(.openBattleRetreatConfirmation, .temporalDefeatRecovery)],
            battleStatus: .stalledAfterDefeat
        ))) else { return }

        let cancelled = controller.cancelUnpostedActionForForegroundDeferral(request)
        #expect(cancelled)
        #expect(controller.consume(makeSnapshot(
            state: .retreatConfirmation,
            time: 2,
            fingerprint: "external-confirmation",
            gatedActions: [gatedAction(.confirmNoTalismanRetreat, .explicitRetreatConfirmation)]
        )) == .stop(.retreatConfirmationWasNotRequested))
        #expect(controller.actionsIssued == 1)
    }

    @Test("Focus deferral of an unposted retreat confirmation keeps its one-shot authorization")
    func foregroundDeferralOfConfirmationRestoresAuthorization() {
        var controller = makeController(policy: policy(actionCooldown: 0))
        guard let retreat = requireAction(controller.consume(makeSnapshot(
            state: .battle,
            time: 1,
            fingerprint: "stalled",
            gatedActions: [gatedAction(.openBattleRetreatConfirmation, .temporalDefeatRecovery)],
            battleStatus: .stalledAfterDefeat
        ))) else { return }
        let marked = controller.markActionPosted(retreat, at: 2)
        #expect(marked)
        guard let confirmation = requireAction(controller.consume(makeSnapshot(
            state: .retreatConfirmation,
            time: 3,
            fingerprint: "requested-confirmation",
            gatedActions: [gatedAction(.confirmNoTalismanRetreat, .explicitRetreatConfirmation)]
        ))) else { return }
        #expect(confirmation.intent == .confirmRetreatWithoutTalisman)

        let cancelled = controller.cancelUnpostedActionForForegroundDeferral(confirmation)
        #expect(cancelled)
        guard let renewed = requireAction(controller.consume(makeSnapshot(
            state: .retreatConfirmation,
            time: 4,
            fingerprint: "requested-confirmation-later",
            gatedActions: [gatedAction(.confirmNoTalismanRetreat, .explicitRetreatConfirmation)]
        ))) else { return }
        #expect(renewed.intent == .confirmRetreatWithoutTalisman)
        #expect(renewed.requestID == confirmation.requestID + 1)
        #expect(controller.actionsIssued == 3)

        // Once posted, the confirmation can neither be discarded nor authorized again.
        let marked2 = controller.markActionPosted(renewed, at: 5)
        #expect(marked2)
        let cancelled2 = controller.cancelUnpostedActionForForegroundDeferral(renewed)
        #expect(!cancelled2)
        #expect(controller.consume(makeSnapshot(
            state: .retreatConfirmation,
            time: 6,
            fingerprint: "requested-confirmation-later",
            gatedActions: [gatedAction(.confirmNoTalismanRetreat, .explicitRetreatConfirmation)]
        )) == .wait(.awaitingFrameChange(intent: .confirmRetreatWithoutTalisman)))
    }

    @Test("Verified stalled defeat requests retreat without equipment metadata")
    func stalledDefeatNeedsNoEquipmentMetadata() {
        var controller = makeController()
        let decision = controller.consume(makeSnapshot(
            state: .battle,
            time: 1,
            fingerprint: "stalled",
            gatedActions: [gatedAction(.openBattleRetreatConfirmation, .temporalDefeatRecovery)],
            battleStatus: .stalledAfterDefeat
        ))

        #expect(requireAction(decision)?.intent == .requestRetreat)
        #expect(controller.actionsIssued == 1)
    }

    @Test("Unknown state gets bounded count grace then stops")
    func unknownCountGrace() {
        var controller = makeController(policy: policy(
            uncertainStateGraceDuration: 100,
            uncertainStateGraceSnapshots: 2
        ))
        #expect(controller.consume(makeSnapshot(
            state: .unknown, time: 1, fingerprint: "u1"
        )) == .wait(.transientState(kind: .unknown, observationCount: 1)))
        #expect(controller.consume(makeSnapshot(
            state: .unknown, time: 2, fingerprint: "u2"
        )) == .wait(.transientState(kind: .unknown, observationCount: 2)))
        #expect(controller.consume(makeSnapshot(
            state: .unknown, time: 3, fingerprint: "u3"
        )) == .stop(.uncertainStateExceededGrace(kind: .unknown)))
    }

    @Test("Classification conflict stops immediately")
    func conflictStopsImmediately() {
        var controller = makeController()
        let conflictEvidence = GameStateEvidence(
            kind: .conflictingStateMarkers,
            observation: nil,
            detail: "conflict"
        )
        #expect(controller.consume(makeSnapshot(
            state: .unknown,
            time: 1,
            fingerprint: "c1",
            evidence: [conflictEvidence]
        )) == .stop(.classificationConflict))
    }

    @Test("Inventory full stops immediately and can never sell")
    func inventoryStopsImmediately() {
        var controller = makeController()
        #expect(controller.consume(makeSnapshot(
            state: .inventoryFull, time: 1, fingerprint: "i1"
        )) == .stop(.inventoryFull))
        #expect(controller.actionsIssued == 0)
    }

    @Test("Missing and duplicate action targets fail closed after grace")
    func missingAndAmbiguousActions() {
        let shortGrace = policy(
            uncertainStateGraceDuration: 100,
            uncertainStateGraceSnapshots: 1
        )
        var missing = makeController(policy: shortGrace)
        let noClose = makeSnapshot(
            state: .battleEncounterPrompt, time: 1, fingerprint: "m1"
        )
        #expect(missing.consume(noClose) == .wait(.transientState(
            kind: .missingAction,
            observationCount: 1
        )))
        #expect(missing.consume(makeSnapshot(
            state: .battleEncounterPrompt, time: 2, fingerprint: "m2"
        )) == .stop(.uncertainStateExceededGrace(kind: .missingAction)))

        var ambiguous = makeController(policy: shortGrace)
        let duplicate = makeSnapshot(
            state: .battleEncounterPrompt,
            time: 1,
            fingerprint: "a1",
            actions: [gameAction(.closeBattlePrompt)],
            supplemental: [candidate(.closeBattlePrompt)]
        )
        #expect(ambiguous.consume(duplicate) == .wait(.transientState(
            kind: .ambiguousAction,
            observationCount: 1
        )))
    }

    @Test("Window identity changes stop immediately and permanently")
    func windowChangeStops() {
        var controller = makeController()
        let changedWindow = AutoLevelWindowIdentity(processID: 22, windowID: 33)
        let decision = controller.consume(makeSnapshot(
            state: .battle,
            time: 1,
            fingerprint: "window",
            windowIdentity: changedWindow,
            allAutoStatus: .active
        ))
        let reason = AutoLevelStopReason.windowIdentityChanged(
            expected: testWindow,
            actual: changedWindow
        )
        #expect(decision == .stop(reason))
        #expect(controller.consume(makeSnapshot(
            state: .battle,
            time: 2,
            fingerprint: "back",
            allAutoStatus: .active
        )) == .stop(reason))
    }

    @Test("Runtime limit is hard and inclusive")
    func runtimeLimit() {
        var controller = makeController(policy: policy(maxRuntime: 10))
        let decision = controller.consume(makeSnapshot(
            state: .battle,
            time: 10,
            fingerprint: "deadline",
            allAutoStatus: .active
        ))
        #expect(decision == .stop(.maximumRuntimeReached(limit: 10)))
    }

    @Test("Maximum action count stops before another action")
    func actionLimit() {
        var controller = makeController(policy: policy(
            actionCooldown: 0,
            maxActions: 1
        ))
        _ = controller.consume(makeSnapshot(
            state: .battleEncounterPrompt,
            time: 1,
            fingerprint: "prompt",
            actions: [gameAction(.closeBattlePrompt)]
        ))
        let decision = controller.consume(makeSnapshot(
            state: .battle,
            time: 2,
            fingerprint: "battle",
            actions: [gameAction(.enableAutoBattle)],
            allAutoStatus: .inactive
        ))
        #expect(decision == .stop(.maximumActionsReached(limit: 1)))
    }

    @Test("Maximum cycle count reports the last completion before stopping, even on stale pixels",
          arguments: [true, false])
    func cycleLimit(allowNewActions: Bool) {
        var controller = makeController(policy: policy(maxCycles: 1))
        let result = makeSnapshot(
            state: .missionComplete,
            time: 1,
            fingerprint: "result",
            actions: [gameAction(.selectMissionRepeat)]
        )
        #expect(controller.consume(result, allowNewActions: allowNewActions)
            == .completedCycle(.init(count: 1, outcome: .success)))
        #expect(controller.consume(result, allowNewActions: allowNewActions)
            == .stop(.maximumCyclesReached(limit: 1)))
        #expect(controller.actionsIssued == 0)
    }

    @Test("Non-monotonic observations stop")
    func nonMonotonicTimeStops() {
        var controller = makeController()
        _ = controller.consume(makeSnapshot(
            state: .battle, time: 2, fingerprint: "later", allAutoStatus: .active
        ))
        #expect(controller.consume(makeSnapshot(
            state: .battle, time: 1, fingerprint: "earlier", allAutoStatus: .active
        )) == .stop(.nonMonotonicTimestamp(previous: 2, current: 1)))
    }

    @Test("Invalid target never becomes a click")
    func invalidTargetStopsThroughGrace() {
        var controller = makeController(policy: policy(
            uncertainStateGraceDuration: 100,
            uncertainStateGraceSnapshots: 0
        ))
        let invalidTarget = AutoLevelActionTarget(
            name: "close",
            sourceText: "關閉",
            rect: NormalizedRect(x: -0.1, y: 0.5, width: 0.1, height: 0.1)
        )
        let decision = controller.consume(makeSnapshot(
            state: .battleEncounterPrompt,
            time: 1,
            fingerprint: "invalid",
            supplemental: [.init(intent: .closeBattlePrompt, target: invalidTarget)]
        ))
        #expect(decision == .stop(.uncertainStateExceededGrace(kind: .ambiguousAction)))
        #expect(controller.actionsIssued == 0)
    }

    @Test("An action cannot borrow a differently named target")
    func mismatchedNamedTargetStops() {
        var controller = makeController(policy: policy(
            uncertainStateGraceDuration: 100,
            uncertainStateGraceSnapshots: 0
        ))
        let lootTarget = AutoLevelActionTarget(
            name: GameTargetName.lootConfirmationYes.rawValue,
            sourceText: "是",
            rect: NormalizedRect(x: 0.4, y: 0.4, width: 0.1, height: 0.1)
        )
        let decision = controller.consume(makeSnapshot(
            state: .battleEncounterPrompt,
            time: 1,
            fingerprint: "wrong-name",
            supplemental: [.init(intent: .closeBattlePrompt, target: lootTarget)]
        ))

        #expect(decision == .stop(.uncertainStateExceededGrace(kind: .ambiguousAction)))
        #expect(controller.actionsIssued == 0)
    }

    @Test("Unexpected known post-action state stops")
    func unexpectedTransitionStops() {
        var controller = makeController(policy: policy(actionCooldown: 0))
        _ = controller.consume(makeSnapshot(
            state: .lootCollectionConfirmation,
            time: 1,
            fingerprint: "loot",
            actions: [gameAction(.confirmLootCollection)]
        ))
        let decision = controller.consume(makeSnapshot(
            state: .missionFailed,
            time: 2,
            fingerprint: "unexpected",
            actions: [gameAction(.selectMissionRepeat)]
        ))
        #expect(decision == .stop(.unexpectedTransition(
            intent: .confirmLootCollection,
            from: .lootCollectionConfirmation,
            to: .missionFailed
        )))
    }

    @Test("Invalid policy and session metadata are terminal")
    func invalidConfigurationStops() {
        var invalidPolicy = makeController(policy: policy(maxActions: 0))
        #expect(invalidPolicy.consume(makeSnapshot(
            state: .battle, time: 1, fingerprint: "x", allAutoStatus: .active
        )) == .stop(.invalidPolicy))

        var invalidSession = AutoLevelController(session: .init(
            sessionID: "",
            startedAt: 0,
            windowIdentity: testWindow
        ))
        #expect(invalidSession.consume(makeSnapshot(
            state: .battle, time: 1, fingerprint: "x", allAutoStatus: .active
        )) == .stop(.invalidSessionMetadata))
    }

    // MARK: - Fixtures

    private func makePendingRetreatController(
        policy: AutoLevelPolicy = AutoLevelPolicy(),
        posted: Bool = true
    ) throws -> (AutoLevelController, AutoLevelActionRequest) {
        var controller = makeController(policy: policy)
        let retreat = try #require(requireAction(controller.consume(makeSnapshot(
            state: .battle,
            time: 1,
            fingerprint: "stalled",
            gatedActions: [gatedAction(.openBattleRetreatConfirmation, .temporalDefeatRecovery)],
            battleStatus: .stalledAfterDefeat
        ))))
        #expect(retreat.intent == .requestRetreat)
        if posted {
            let marked = controller.markActionPosted(retreat, at: 1.5)
            #expect(marked)
        }
        return (controller, retreat)
    }

    private var testWindow: AutoLevelWindowIdentity {
        AutoLevelWindowIdentity(processID: 11, windowID: 22)
    }

    private func makeController(
        policy: AutoLevelPolicy = AutoLevelPolicy()
    ) -> AutoLevelController {
        AutoLevelController(
            session: AutoLevelSessionMetadata(
                sessionID: "test-session",
                startedAt: 0,
                windowIdentity: testWindow
            ),
            policy: policy
        )
    }

    private func policy(
        actionCooldown: Double = 0.8,
        postActionTimeout: Double = 8,
        uncertainStateGraceDuration: Double = 2,
        uncertainStateGraceSnapshots: Int = 2,
        maxCycles: Int = 100,
        maxRuntime: Double = 100,
        maxActions: Int = 100
    ) -> AutoLevelPolicy {
        AutoLevelPolicy(
            actionCooldown: actionCooldown,
            postActionTimeout: postActionTimeout,
            uncertainStateGraceDuration: uncertainStateGraceDuration,
            uncertainStateGraceSnapshots: uncertainStateGraceSnapshots,
            maxCycles: maxCycles,
            maxRuntime: maxRuntime,
            maxActions: maxActions
        )
    }

    private func makeSnapshot(
        state: GameState,
        time: Double,
        fingerprint: String,
        evidence: [GameStateEvidence] = [],
        actions: [AllowedGameAction] = [],
        gatedActions: [PolicyGatedGameAction] = [],
        supplemental: [AutoLevelActionCandidate] = [],
        windowIdentity: AutoLevelWindowIdentity? = nil,
        battleSessionID: String? = nil,
        allAutoStatus: AutoLevelAllAutoStatus = .unknown,
        battleStatus: AutoLevelBattleStatus = .inProgress,
        addDefaultResultPageEvidence: Bool = true
    ) -> AutoLevelSnapshot {
        var resolvedEvidence = evidence
        if state == .missionCompleteRepeatSelected || state == .missionFailedRepeatSelected,
           !resolvedEvidence.contains(where: { $0.kind == .missionRepeatOption })
        {
            resolvedEvidence += resultPageEvidence(nil)
        }
        if addDefaultResultPageEvidence,
           state == .missionCompleteRepeatSelected,
           !resolvedEvidence.contains(where: {
               $0.kind == .missionExperiencePage || $0.kind == .missionLootPage
           })
        {
            resolvedEvidence.append(GameStateEvidence(
                kind: .missionExperiencePage,
                observation: OCRTextObservation(
                    text: "獲得經驗值",
                    rect: NormalizedRect(x: 0.78, y: 0.145, width: 0.19, height: 0.02),
                    confidence: 1
                ),
                detail: "test EXP page"
            ))
        }
        return AutoLevelSnapshot(
            classification: GameStateClassification(
                state: state,
                evidence: resolvedEvidence,
                allowedActions: actions,
                policyGatedActions: gatedActions
            ),
            runtime: AutoLevelRuntimeMetadata(
                observedAt: time,
                windowIdentity: windowIdentity ?? testWindow,
                frameFingerprint: fingerprint,
                battleSessionID: battleSessionID,
                allAutoStatus: allAutoStatus,
                battleStatus: battleStatus
            ),
            supplementalActionCandidates: supplemental
        )
    }

    private func gameAction(
        _ name: GameActionName,
        rect: NormalizedRect = NormalizedRect(
            x: 0.02,
            y: 0.19,
            width: 0.05,
            height: 0.02
        ),
        sourceText: String? = nil
    ) -> AllowedGameAction {
        AllowedGameAction(
            name: name,
            target: NamedGameTarget(
                name: targetName(for: name),
                sourceText: sourceText
                    ?? (name == .advanceMissionComplete ? ">>" : name.rawValue),
                rect: rect,
                point: rect.center
            )
        )
    }

    private func resultPageEvidence(
        _ pageKind: GameEvidenceKind?,
        text: String = ""
    ) -> [GameStateEvidence] {
        var evidence = [GameStateEvidence(
            kind: .missionRepeatOption,
            observation: OCRTextObservation(
                text: "重複進行此任務",
                rect: NormalizedRect(x: 0.025, y: 0.236, width: 0.286, height: 0.020),
                confidence: 1
            ),
            detail: "test repeat option"
        )]
        if let pageKind {
            evidence.append(GameStateEvidence(
                kind: pageKind,
                observation: OCRTextObservation(
                    text: text,
                    rect: NormalizedRect(x: 0.78, y: 0.146, width: 0.19, height: 0.020),
                    confidence: 1
                ),
                detail: "test result page"
            ))
        }
        return evidence
    }

    private func measuredLootFallbackClassification() -> GameStateClassification {
        GameStateClassifier.classify(
            observations: [
                OCRTextObservation(
                    text: "任務完成！",
                    rect: NormalizedRect(
                        x: 0.3891067804403232,
                        y: 0.10550803805301134,
                        width: 0.21193422589983257,
                        height: 0.02269178776258829
                    ),
                    confidence: 1
                ),
                OCRTextObservation(
                    text: "獲得拾得物",
                    rect: NormalizedRect(
                        x: 0.7783251214285715,
                        y: 0.14606741552808988,
                        width: 0.1921182266009852,
                        height: 0.020224719101123556
                    ),
                    confidence: 1
                ),
                OCRTextObservation(
                    text: "重複進行此任務",
                    rect: NormalizedRect(
                        x: 0.024630543912737477,
                        y: 0.23595505606741574,
                        width: 0.2857142857142857,
                        height: 0.020224719101123556
                    ),
                    confidence: 1
                ),
                OCRTextObservation(
                    text: "SELECTED",
                    rect: NormalizedRect(
                        x: 0.36982343572043463,
                        y: 0.2232546383556393,
                        width: 0.26002105938389963,
                        height: 0.035046082400204126
                    ),
                    confidence: 0.5
                ),
            ],
            permitMeasuredLootTopAdvanceFallback: true
        )
    }

    private func measuredLootFallbackSnapshot(
        time: Double,
        fingerprint: String,
        allowedActions: [AllowedGameAction]? = nil
    ) -> AutoLevelSnapshot {
        measuredResultFallbackSnapshot(
            pageKind: .missionLootPage,
            pageText: "獲得拾得物",
            time: time,
            fingerprint: fingerprint,
            allowedActions: allowedActions
        )
    }

    private func measuredSuccessFallbackSnapshot(
        page: MissionSuccessPageIdentity,
        time: Double,
        fingerprint: String,
        allowedActions: [AllowedGameAction]? = nil
    ) -> AutoLevelSnapshot {
        measuredResultFallbackSnapshot(
            pageKind: page == .experience ? .missionExperiencePage : .missionLootPage,
            pageText: page == .experience ? "獲得經驗值" : "獲得拾得物",
            time: time,
            fingerprint: fingerprint,
            allowedActions: allowedActions
        )
    }

    private func measuredResultFallbackSnapshot(
        pageKind: GameEvidenceKind,
        pageText: String,
        time: Double,
        fingerprint: String,
        allowedActions: [AllowedGameAction]? = nil
    ) -> AutoLevelSnapshot {
        let lootBaseline = measuredLootFallbackClassification()
        var evidence = lootBaseline.evidence.filter {
            $0.kind != .missionExperiencePage && $0.kind != .missionLootPage
        }
        evidence.append(GameStateEvidence(
            kind: pageKind,
            observation: OCRTextObservation(
                text: pageText,
                rect: NormalizedRect(
                    x: 0.7783251214285715,
                    y: 0.14606741552808988,
                    width: 0.1921182266009852,
                    height: 0.020224719101123556
                ),
                confidence: 1
            ),
            detail: "measured result page"
        ))
        let baseline = MissionResultTopActionResolver.resolve(classification:
            GameStateClassification(
                state: lootBaseline.state,
                evidence: evidence,
                allowedActions: lootBaseline.allowedActions,
                policyGatedActions: lootBaseline.policyGatedActions
            )
        )
        let classification = GameStateClassification(
            state: baseline.state,
            evidence: baseline.evidence,
            allowedActions: allowedActions ?? baseline.allowedActions,
            policyGatedActions: baseline.policyGatedActions
        )
        return AutoLevelSnapshot(
            classification: classification,
            runtime: AutoLevelRuntimeMetadata(
                observedAt: time,
                windowIdentity: testWindow,
                frameFingerprint: fingerprint
            )
        )
    }

    private func gatedAction(
        _ name: GameActionName,
        _ requirement: GameActionPolicyRequirement
    ) -> PolicyGatedGameAction {
        PolicyGatedGameAction(
            name: name,
            target: NamedGameTarget(
                name: targetName(for: name),
                sourceText: name.rawValue,
                rect: NormalizedRect(x: 0.4, y: 0.4, width: 0.1, height: 0.1),
                point: NormalizedPoint(x: 0.45, y: 0.45)
            ),
            requirement: requirement
        )
    }

    private func candidate(_ intent: AutoLevelActionIntent) -> AutoLevelActionCandidate {
        AutoLevelActionCandidate(
            intent: intent,
            target: AutoLevelActionTarget(
                name: intent.rawValue,
                sourceText: intent.rawValue,
                rect: NormalizedRect(x: 0.4, y: 0.4, width: 0.1, height: 0.1)
            )
        )
    }

    private func targetName(for action: GameActionName) -> GameTargetName {
        switch action {
        case .selectMissionRepeat:
            return .missionRepeatOption
        case .advanceMissionComplete:
            return .missionCompleteAdvance
        case .recruitAdventurer:
            return .adventurerRecruit
        case .leaveAdventurer:
            return .adventurerLeave
        case .closeBattlePrompt:
            return .battlePromptClose
        case .pressWideModalTopButton:
            return .wideModalTopButton
        case .enableAutoBattle:
            return .battleAuto
        case .confirmLootCollection:
            return .lootConfirmationYes
        case .openBattleRetreatConfirmation:
            return .battleRetreat
        case .confirmNoTalismanRetreat:
            return .retreatConfirmationYes
        }
    }

    private func requireAction(
        _ decision: AutoLevelDecision
    ) -> AutoLevelActionRequest? {
        guard case let .requestAction(request) = decision else {
            Issue.record("Expected action request, got \(decision)")
            return nil
        }
        return request
    }
}
