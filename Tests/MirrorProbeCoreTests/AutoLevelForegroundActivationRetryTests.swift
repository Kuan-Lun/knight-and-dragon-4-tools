import Testing
@testable import MirrorProbeCore

@Suite("Foreground activation retry")
struct AutoLevelForegroundActivationRetryTests {
    @Test("Focus contention gets exactly three total attempts")
    func exhaustsAfterThreeAttempts() {
        var state = AutoLevelForegroundActivationRetryState()

        #expect(state.currentAttempt == 1)
        #expect(state.settleDelayMilliseconds == 350)
        #expect(
            state.recordUnpostedFocusFailure()
                == .retry(nextAttempt: 2, delayMilliseconds: 1_000)
        )
        #expect(state.currentAttempt == 2)
        #expect(state.settleDelayMilliseconds == 600)
        #expect(
            state.recordUnpostedFocusFailure()
                == .retry(nextAttempt: 3, delayMilliseconds: 1_000)
        )
        #expect(state.currentAttempt == 3)
        #expect(state.settleDelayMilliseconds == 900)
        #expect(
            state.recordUnpostedFocusFailure()
                == .exhausted(attempts: 3)
        )
        #expect(
            state.recordUnpostedFocusFailure()
                == .exhausted(attempts: 3)
        )
        #expect(state.currentAttempt == 3)
    }

    @Test("Every action starts with a fresh retry budget")
    func freshActionsHaveIndependentBudgets() {
        var first = AutoLevelForegroundActivationRetryState()
        _ = first.recordUnpostedFocusFailure()

        let second = AutoLevelForegroundActivationRetryState()
        #expect(first.currentAttempt == 2)
        #expect(second.currentAttempt == 1)
        #expect(second.settleDelayMilliseconds == 350)
    }

    @Test("A live process with a missing application handle gets exactly three total attempts")
    func applicationResolutionExhaustsSharedBudget() {
        var state = AutoLevelForegroundActivationRetryState()
        let expectedDecisions: [AutoLevelForegroundActivationRetryDecision] = [
            .retry(nextAttempt: 2, delayMilliseconds: 1_000),
            .retry(nextAttempt: 3, delayMilliseconds: 1_000),
            .exhausted(attempts: 3),
            .exhausted(attempts: 3),
        ]
        for expected in expectedDecisions {
            #expect(state.recordUnpostedApplicationResolutionFailure(
                processIsRunning: true,
                inputWasPosted: false
            ) == expected)
        }
        #expect(state.currentAttempt == 3)
        #expect(state.recordUnpostedFocusFailure() == .exhausted(attempts: 3))

        var nextAction = AutoLevelForegroundActivationRetryState()
        #expect(nextAction.currentAttempt == 1)
        #expect(nextAction.recordUnpostedApplicationResolutionFailure(
            processIsRunning: true,
            inputWasPosted: false
        ) == .retry(nextAttempt: 2, delayMilliseconds: 1_000))
        #expect(state.currentAttempt == 3)
    }

    @Test("Unconfirmed process liveness and posted input reject resolution recovery without spending attempts",
          arguments: [(false, false), (false, true), (true, true)])
    func applicationResolutionRequiresLiveProcessAndUnpostedInput(
        processIsRunning: Bool,
        inputWasPosted: Bool
    ) {
        var state = AutoLevelForegroundActivationRetryState()
        _ = state.recordUnpostedFocusFailure()
        #expect(state.currentAttempt == 2)
        #expect(state.recordUnpostedApplicationResolutionFailure(
            processIsRunning: processIsRunning,
            inputWasPosted: inputWasPosted
        ) == nil)
        #expect(state.currentAttempt == 2)
        #expect(state.recordUnpostedApplicationResolutionFailure(
            processIsRunning: true,
            inputWasPosted: false
        ) == .retry(nextAttempt: 3, delayMilliseconds: 1_000))
    }

    @Test("Application resolution, focus, and unknown results share three total attempts in any order",
          arguments: [
            [0, 1, 2], [0, 2, 1], [1, 0, 2],
            [1, 2, 0], [2, 0, 1], [2, 1, 0],
          ])
    func mixedApplicationResolutionFailuresNeverRenewBudget(failureOrder: [Int]) {
        var state = AutoLevelForegroundActivationRetryState()
        let expectedDecisions: [AutoLevelForegroundActivationRetryDecision] = [
            .retry(nextAttempt: 2, delayMilliseconds: 1_000),
            .retry(nextAttempt: 3, delayMilliseconds: 1_000),
            .exhausted(attempts: 3),
        ]
        for (failure, expected) in zip(failureOrder, expectedDecisions) {
            let decision: AutoLevelForegroundActivationRetryDecision?
            switch failure {
            case 0:
                decision = state.recordUnpostedApplicationResolutionFailure(
                    processIsRunning: true,
                    inputWasPosted: false
                )
            case 1:
                decision = state.recordUnpostedFocusFailure()
            default:
                decision = state.recordUnpostedResultObservationFailure(
                    intent: .advanceMissionSuccess,
                    classification: unknownResult(),
                    inputWasPosted: false
                )
            }
            #expect(decision == expected)
        }
        #expect(state.currentAttempt == 3)
        #expect(state.recordUnpostedApplicationResolutionFailure(
            processIsRunning: true,
            inputWasPosted: false
        ) == .exhausted(attempts: 3))
    }

    @Test("Unknown unposted result controls with benign scaffolding can be observed again",
          arguments: [AutoLevelActionIntent.advanceMissionSuccess, .advanceMissionFailure, .selectMissionRepeat])
    func transientUnknownResultPermitsFreshObservation(intent: AutoLevelActionIntent) {
        let benignKinds: [GameEvidenceKind] = [
            .missionCompleteTitle, .missionFailedTitle, .missionRepeatOption,
            .repeatSelectedMarker, .repeatUnselectedMarker, .missionExperiencePage, .missionLootPage,
        ]
        let evidenceSets: [[GameStateEvidence]] = [[], [lowConfidenceEvidence]] + benignKinds.map {
            [lowConfidenceEvidence, GameStateEvidence(kind: $0, observation: nil, detail: "result scaffold")]
        }
        for evidence in evidenceSets {
            var state = AutoLevelForegroundActivationRetryState()
            let classification = unknownResult(evidence: evidence)
            #expect(state.recordUnpostedResultObservationFailure(
                intent: intent,
                classification: classification,
                inputWasPosted: false
            ) == .retry(nextAttempt: 2, delayMilliseconds: 1_000))
            #expect(state.currentAttempt == 2)
            #expect(state.settleDelayMilliseconds == 600)
            // A retry decision never turns the rejected observation into an input target.
            #expect(classification.state == .unknown)
            #expect(classification.allowedActions.isEmpty)
            #expect(classification.policyGatedActions.isEmpty)
        }
    }

    @Test("Result observation recovery never extends to unrelated controls or retreat")
    func otherActionIntentsDoNotRetryUnknownResults() {
        let ineligibleIntents: [AutoLevelActionIntent] = [
            .closeBattlePrompt, .pressWideModalTopButton, .enableAllAuto,
            .confirmLootCollection, .recruitAdventurer, .leaveAdventurer,
            .requestRetreat, .confirmRetreatWithoutTalisman,
        ]
        var state = AutoLevelForegroundActivationRetryState()
        for intent in ineligibleIntents {
            #expect(state.recordUnpostedResultObservationFailure(
                intent: intent,
                classification: unknownResult(),
                inputWasPosted: false
            ) == nil)
            #expect(state.currentAttempt == 1)
        }
    }

    @Test("Recognized preflight state changes keep their existing cancellation or stop handling",
          arguments: [AutoLevelActionIntent.advanceMissionSuccess, .advanceMissionFailure, .selectMissionRepeat])
    func recognizedStatesDoNotEnterUnknownResultRecovery(intent: AutoLevelActionIntent) {
        let recognizedStates: [GameState] = [
            .missionComplete, .missionCompleteRepeatSelected, .wideModalOneButton,
            .wideModalTwoButtons, .missionFailed, .missionFailedRepeatSelected,
            .lootCollectionConfirmation, .adventurerRecruitment, .defeatPrompt,
            .retreatConfirmation, .battleEventPrompt, .battleEncounterPrompt,
            .battle, .defeat, .inventoryFull,
        ]
        var retry = AutoLevelForegroundActivationRetryState()
        for state in recognizedStates {
            #expect(retry.recordUnpostedResultObservationFailure(
                intent: intent,
                classification: .init(state: state, evidence: [], allowedActions: []),
                inputWasPosted: false
            ) == nil)
            #expect(retry.currentAttempt == 1)
        }
    }

    @Test("Explicit adverse or unrelated evidence cannot be hidden by a low-confidence marker",
          arguments: [AutoLevelActionIntent.advanceMissionSuccess, .advanceMissionFailure, .selectMissionRepeat])
    func adverseAndUnrelatedEvidenceNeverRetries(intent: AutoLevelActionIntent) {
        let disallowedKinds: [GameEvidenceKind] = [
            .invalidObservation, .conflictingStateMarkers, .inventoryFullMarker,
            .defeatMarker, .wideModalGeometry, .battleMarker, .retreatConfirmationPrompt,
            .lootCollectionPrompt, .missionCompleteAdvance,
        ]
        var state = AutoLevelForegroundActivationRetryState()
        for kind in disallowedKinds {
            let adverse = GameStateEvidence(kind: kind, observation: nil, detail: "must remain terminal")
            for evidence in [[adverse], [lowConfidenceEvidence, adverse]] {
                #expect(state.recordUnpostedResultObservationFailure(
                    intent: intent,
                    classification: unknownResult(evidence: evidence),
                    inputWasPosted: false
                ) == nil)
                #expect(state.currentAttempt == 1)
            }
        }
    }

    @Test("Posted input and malformed unknown classifications never enter result recovery",
          arguments: [AutoLevelActionIntent.advanceMissionSuccess, .advanceMissionFailure, .selectMissionRepeat])
    func postedInputAndUnexpectedActionsRejectRecovery(intent: AutoLevelActionIntent) {
        var state = AutoLevelForegroundActivationRetryState()
        #expect(state.recordUnpostedResultObservationFailure(
            intent: intent,
            classification: unknownResult(),
            inputWasPosted: true
        ) == nil)
        let rect = NormalizedRect(x: 0.02, y: 0.19, width: 0.05, height: 0.02)
        let target = NamedGameTarget(
            name: .missionCompleteAdvance,
            sourceText: "unexpected-target",
            rect: rect,
            point: rect.center
        )
        let malformed = [
            GameStateClassification(state: .unknown, evidence: [], allowedActions: [
                .init(name: .advanceMissionComplete, target: target),
            ]),
            GameStateClassification(state: .unknown, evidence: [], allowedActions: [], policyGatedActions: [
                .init(name: .openBattleRetreatConfirmation, target: target, requirement: .temporalDefeatRecovery),
            ]),
        ]
        for classification in malformed {
            #expect(state.recordUnpostedResultObservationFailure(
                intent: intent,
                classification: classification,
                inputWasPosted: false
            ) == nil)
        }
        #expect(state.currentAttempt == 1)
    }

    @Test("Persistent unknown result confirmations allow exactly three total attempts",
          arguments: [AutoLevelActionIntent.advanceMissionSuccess, .advanceMissionFailure, .selectMissionRepeat])
    func persistentUnknownResultIsBounded(intent: AutoLevelActionIntent) {
        var state = AutoLevelForegroundActivationRetryState()
        let expectedDecisions: [AutoLevelForegroundActivationRetryDecision] = [
            .retry(nextAttempt: 2, delayMilliseconds: 1_000),
            .retry(nextAttempt: 3, delayMilliseconds: 1_000),
            .exhausted(attempts: 3),
            .exhausted(attempts: 3),
        ]
        for expected in expectedDecisions {
            #expect(state.recordUnpostedResultObservationFailure(
                intent: intent,
                classification: unknownResult(),
                inputWasPosted: false
            ) == expected)
        }
        #expect(state.currentAttempt == 3)
        #expect(state.recordUnpostedFocusFailure() == .exhausted(attempts: 3))
    }

    @Test("Focus and result observation failures share one total attempt budget",
          arguments: [AutoLevelActionIntent.advanceMissionSuccess, .advanceMissionFailure, .selectMissionRepeat],
          [false, true])
    func focusAndUnknownResultShareBudget(intent: AutoLevelActionIntent, resultFirst: Bool) {
        var state = AutoLevelForegroundActivationRetryState()
        for (index, isResultFailure) in [resultFirst, !resultFirst].enumerated() {
            let decision: AutoLevelForegroundActivationRetryDecision? = isResultFailure
                ? state.recordUnpostedResultObservationFailure(
                    intent: intent,
                    classification: unknownResult(),
                    inputWasPosted: false
                )
                : state.recordUnpostedFocusFailure()
            #expect(decision == .retry(nextAttempt: index + 2, delayMilliseconds: 1_000))
        }
        #expect(state.currentAttempt == 3)
        #expect(state.recordUnpostedResultObservationFailure(
            intent: intent,
            classification: unknownResult(),
            inputWasPosted: false
        ) == .exhausted(attempts: 3))
        #expect(state.recordUnpostedFocusFailure() == .exhausted(attempts: 3))
    }

    @Test("Live AX focus wins over advisory activation and stale AppKit active flags", arguments: [
        (false, true, true, true),
        (true, true, true, true),
        (true, false, true, true),
        (false, false, true, true),
        (true, true, false, false),
        (false, true, false, false),
        (false, false, false, false),
    ])
    func observedFocusIsAuthoritative(
        activateReturned: Bool,
        targetApplicationIsActive: Bool,
        frontmostProcessMatches: Bool,
        expected: Bool
    ) {
        #expect(
            AutoLevelForegroundActivationRetryState.activationIsReady(
                activateReturned: activateReturned,
                targetApplicationIsActive: targetApplicationIsActive,
                frontmostProcessMatches: frontmostProcessMatches
            ) == expected
        )
    }

    @Test("Without obstruction observations only an unposted foreground focus failure retries")
    func retryableInputBoundaryRejectionsStayNarrow() {
        #expect(
            AutoLevelForegroundActivationRetryState.permitsRetry(
                after: .applicationNotFrontmost,
                inputWasPosted: false
            )
        )
        #expect(
            !AutoLevelForegroundActivationRetryState.permitsRetry(
                after: .applicationNotFrontmost,
                inputWasPosted: true
            )
        )
        #expect(
            !AutoLevelForegroundActivationRetryState.permitsRetry(
                after: .applicationNotFrontmost,
                inputWasPosted: false,
                inputMode: .process
            )
        )

        let terminalRejections: [AutoLevelInputRejection] = [
            .stopRequested,
            .invalidTiming,
            .actionAuthorizationExpired,
            .sessionRuntimeExpired,
            .windowUnavailable,
            .windowIdentityChanged,
            .windowGeometryChanged,
            .clickPointObscured,
        ]
        for rejection in terminalRejections {
            #expect(
                !AutoLevelForegroundActivationRetryState.permitsRetry(
                    after: rejection,
                    inputWasPosted: false
                )
            )
        }
    }

    @Test("A focused target covered by another process stays rejected but may retry")
    func externalObstructionAllowsOnlyANewAttempt() throws {
        let snapshot = obstructionSnapshot()
        let rejection = try #require(safetyRejection(snapshot: snapshot))

        #expect(rejection == .clickPointObscured)
        #expect(AutoLevelForegroundActivationRetryState.permitsRetry(
            after: rejection,
            inputWasPosted: false,
            expectedWindowIdentity: identity,
            snapshot: snapshot
        ))
        // The retry policy does not relax the safety check for the rejected snapshot.
        #expect(safetyRejection(snapshot: snapshot) == .clickPointObscured)
    }

    @Test("Persistent external obstruction exhausts the same three-attempt budget")
    func persistentExternalObstructionIsBounded() throws {
        var state = AutoLevelForegroundActivationRetryState()
        let snapshot = obstructionSnapshot()
        let decisions: [AutoLevelForegroundActivationRetryDecision] = [
            .retry(nextAttempt: 2, delayMilliseconds: 1_000),
            .retry(nextAttempt: 3, delayMilliseconds: 1_000),
            .exhausted(attempts: 3),
        ]

        for expectedDecision in decisions {
            let rejection = try #require(safetyRejection(snapshot: snapshot))
            #expect(rejection == .clickPointObscured)
            #expect(AutoLevelForegroundActivationRetryState.permitsRetry(
                after: rejection,
                inputWasPosted: false,
                expectedWindowIdentity: identity,
                snapshot: snapshot
            ))
            #expect(state.recordUnpostedFocusFailure() == expectedDecision)
        }
        #expect(state.currentAttempt == 3)
        #expect(state.recordUnpostedFocusFailure() == .exhausted(attempts: 3))
    }

    @Test("Focus contention and external obstruction consume one shared budget")
    func contentionReasonsShareBudget() throws {
        var state = AutoLevelForegroundActivationRetryState()
        #expect(AutoLevelForegroundActivationRetryState.permitsRetry(
            after: .applicationNotFrontmost,
            inputWasPosted: false
        ))
        #expect(state.recordUnpostedFocusFailure() == .retry(nextAttempt: 2, delayMilliseconds: 1_000))

        let snapshot = obstructionSnapshot()
        let rejection = try #require(safetyRejection(snapshot: snapshot))
        #expect(AutoLevelForegroundActivationRetryState.permitsRetry(
            after: rejection,
            inputWasPosted: false,
            expectedWindowIdentity: identity,
            snapshot: snapshot
        ))
        #expect(state.recordUnpostedFocusFailure() == .retry(nextAttempt: 3, delayMilliseconds: 1_000))
        #expect(state.recordUnpostedFocusFailure() == .exhausted(attempts: 3))
    }

    @Test("Only a fresh unobscured snapshot can authorize input after recovery")
    func clearedObstructionNeedsFreshAuthorization() throws {
        let obscured = obstructionSnapshot()
        let rejection = try #require(safetyRejection(snapshot: obscured))
        #expect(AutoLevelForegroundActivationRetryState.permitsRetry(
            after: rejection,
            inputWasPosted: false,
            expectedWindowIdentity: identity,
            snapshot: obscured
        ))

        let freshSnapshot = obstructionSnapshot(topmostWindowIdentity: identity)
        #expect(safetyRejection(snapshot: obscured) == .clickPointObscured)
        #expect(safetyRejection(snapshot: freshSnapshot) == nil)
    }

    @Test("Obstruction retries require every identity and ordering observation")
    func obstructionVetoMatrix() {
        let competingTargetWindow = AutoLevelWindowIdentity(
            processID: identity.processID, windowID: identity.windowID + 1
        )
        let ineligibleSnapshots: [AutoLevelInputSnapshot?] = [
            nil,
            obstructionSnapshot(windowIdentity: nil),
            obstructionSnapshot(windowIdentity: otherWindow),
            obstructionSnapshot(windowIdentity: competingTargetWindow),
            obstructionSnapshot(frontmostProcessID: nil),
            obstructionSnapshot(frontmostProcessID: otherWindow.processID),
            obstructionSnapshot(targetProcessTopmostWindowIdentity: nil),
            obstructionSnapshot(targetProcessTopmostWindowIdentity: competingTargetWindow),
            obstructionSnapshot(targetProcessTopmostWindowIdentity: otherWindow),
            obstructionSnapshot(topmostWindowIdentity: nil),
            obstructionSnapshot(topmostWindowIdentity: competingTargetWindow),
            obstructionSnapshot(topmostWindowIdentity: identity),
        ]
        for snapshot in ineligibleSnapshots {
            #expect(!AutoLevelForegroundActivationRetryState.permitsRetry(
                after: .clickPointObscured,
                inputWasPosted: false,
                expectedWindowIdentity: identity,
                snapshot: snapshot
            ))
        }

        let eligibleSnapshot = obstructionSnapshot()
        #expect(!AutoLevelForegroundActivationRetryState.permitsRetry(
            after: .clickPointObscured,
            inputWasPosted: false,
            expectedWindowIdentity: nil,
            snapshot: eligibleSnapshot
        ))
        #expect(!AutoLevelForegroundActivationRetryState.permitsRetry(
            after: .clickPointObscured,
            inputWasPosted: false,
            inputMode: .process,
            expectedWindowIdentity: identity,
            snapshot: eligibleSnapshot
        ))
        #expect(!AutoLevelForegroundActivationRetryState.permitsRetry(
            after: .clickPointObscured,
            inputWasPosted: true,
            expectedWindowIdentity: identity,
            snapshot: eligibleSnapshot
        ))
    }

    @Test("A covering external window never makes other safety failures retryable")
    func otherRejectionsRemainTerminal() {
        let terminalRejections: [AutoLevelInputRejection] = [
            .stopRequested,
            .invalidTiming,
            .actionAuthorizationExpired,
            .sessionRuntimeExpired,
            .windowUnavailable,
            .windowIdentityChanged,
            .windowGeometryChanged,
        ]
        for rejection in terminalRejections {
            #expect(!AutoLevelForegroundActivationRetryState.permitsRetry(
                after: rejection,
                inputWasPosted: false,
                expectedWindowIdentity: identity,
                snapshot: obstructionSnapshot()
            ))
        }
    }

    private let identity = AutoLevelWindowIdentity(processID: 99, windowID: 7)
    private let otherWindow = AutoLevelWindowIdentity(processID: 98, windowID: 8)
    private let geometry = AutoLevelWindowGeometry(x: 40, y: 80, width: 300, height: 650)

    private var lowConfidenceEvidence: GameStateEvidence {
        .init(kind: .lowConfidenceMarker, observation: nil, detail: "result marker confidence is temporarily low")
    }

    private func unknownResult(evidence: [GameStateEvidence] = []) -> GameStateClassification {
        .init(state: .unknown, evidence: evidence, allowedActions: [])
    }

    private func obstructionSnapshot(
        windowIdentity: AutoLevelWindowIdentity? = AutoLevelWindowIdentity(processID: 99, windowID: 7),
        frontmostProcessID: Int32? = 99,
        topmostWindowIdentity: AutoLevelWindowIdentity? = AutoLevelWindowIdentity(processID: 98, windowID: 8),
        targetProcessTopmostWindowIdentity: AutoLevelWindowIdentity? = AutoLevelWindowIdentity(processID: 99, windowID: 7)
    ) -> AutoLevelInputSnapshot {
        AutoLevelInputSnapshot(
            windowIdentity: windowIdentity,
            windowGeometry: geometry,
            frontmostProcessID: frontmostProcessID,
            topmostWindowIdentity: topmostWindowIdentity,
            targetProcessTopmostWindowIdentity: targetProcessTopmostWindowIdentity
        )
    }

    private func safetyRejection(snapshot: AutoLevelInputSnapshot) -> AutoLevelInputRejection? {
        AutoLevelInputSafety.rejection(
            expectedWindowIdentity: identity,
            expectedWindowGeometry: geometry,
            snapshot: snapshot,
            now: 100,
            actionDeadline: 112,
            sessionDeadline: 200,
            stopRequested: false
        )
    }
}
