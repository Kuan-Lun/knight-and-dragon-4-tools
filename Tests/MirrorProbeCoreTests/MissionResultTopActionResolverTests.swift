import Testing
@testable import MirrorProbeCore

@Suite("Fixed result top-action resolver")
struct MissionResultTopActionResolverTests {
    @Test("Success EXP and loot pages use the same fixed top target without arrow OCR")
    func successPagesUseFixedTop() {
        for pageKind in [GameEvidenceKind.missionExperiencePage, .missionLootPage] {
            let result = MissionResultTopActionResolver.resolve(classification: classification(
                state: .missionCompleteRepeatSelected,
                title: .missionCompleteTitle,
                page: pageKind
            ))

            #expect(result.allowedActions.map(\.name) == [.advanceMissionComplete])
            #expect(result.allowedActions.first?.target.rect
                    == MissionResultTopActionResolver.measuredTopAdvanceRect)
            #expect(result.allowedActions.first?.target.sourceText
                    == MissionResultTopActionResolver.measuredTopAdvanceSentinel)
            #expect(result.evidence.contains { $0.kind == .missionResultAdvanceMeasuredFallback })
        }
    }

    @Test("Failure result uses the fixed top target without arrow OCR")
    func failureUsesFixedTop() {
        let result = MissionResultTopActionResolver.resolve(classification: classification(
            state: .missionFailedRepeatSelected,
            title: .missionFailedTitle,
            page: nil
        ))

        #expect(result.allowedActions.map(\.name) == [.advanceMissionComplete])
        #expect(result.allowedActions.first?.target.rect
                == MissionResultTopActionResolver.measuredTopAdvanceRect)
    }

    @Test("Incomplete result identity never gains a fixed target")
    func incompleteIdentityStops() {
        let missingPage = MissionResultTopActionResolver.resolve(classification: classification(
            state: .missionCompleteRepeatSelected,
            title: .missionCompleteTitle,
            page: nil
        ))
        #expect(missingPage.allowedActions.isEmpty)

        let conflicting = MissionResultTopActionResolver.resolve(classification:
            GameStateClassification(
                state: .missionFailedRepeatSelected,
                evidence: classification(
                    state: .missionFailedRepeatSelected,
                    title: .missionFailedTitle,
                    page: nil
                ).evidence + [GameStateEvidence(
                    kind: .conflictingStateMarkers,
                    observation: nil,
                    detail: "conflict"
                )],
                allowedActions: []
            )
        )
        #expect(conflicting.allowedActions.isEmpty)
    }

    @Test("Controller accepts the measured target for success and failure intents")
    func controllerAcceptsMeasuredTarget() {
        for item in [
            (GameState.missionCompleteRepeatSelected, GameEvidenceKind.missionCompleteTitle,
             Optional(GameEvidenceKind.missionExperiencePage), AutoLevelActionIntent.advanceMissionSuccess),
            (.missionFailedRepeatSelected, .missionFailedTitle, nil,
             AutoLevelActionIntent.advanceMissionFailure),
        ] {
            let resolved = MissionResultTopActionResolver.resolve(classification: classification(
                state: item.0,
                title: item.1,
                page: item.2
            ))
            var controller = AutoLevelController(
                session: AutoLevelSessionMetadata(
                    sessionID: "result-top",
                    startedAt: 0,
                    windowIdentity: AutoLevelWindowIdentity(processID: 7, windowID: 9)
                ),
                policy: AutoLevelPolicy(actionCooldown: 0)
            )
            let decision = controller.consume(AutoLevelSnapshot(
                classification: resolved,
                runtime: AutoLevelRuntimeMetadata(
                    observedAt: 1,
                    windowIdentity: AutoLevelWindowIdentity(processID: 7, windowID: 9),
                    frameFingerprint: "result"
                )
            ))
            // The first result observation records the completed cycle before issuing its action.
            #expect(decision == .completedCycle(.init(
                count: 1,
                outcome: item.0 == .missionCompleteRepeatSelected ? .success : .failure
            )))
            let action = controller.consume(AutoLevelSnapshot(
                classification: resolved,
                runtime: AutoLevelRuntimeMetadata(
                    observedAt: 1.1,
                    windowIdentity: AutoLevelWindowIdentity(processID: 7, windowID: 9),
                    frameFingerprint: "result"
                )
            ))
            guard case let .requestAction(request) = action else {
                Issue.record("expected a result advance request")
                continue
            }
            #expect(request.intent == item.3)
            #expect(request.target.point
                    == MissionResultTopActionResolver.measuredTopAdvanceRect.center)
        }
    }

    private func classification(
        state: GameState,
        title: GameEvidenceKind,
        page: GameEvidenceKind?
    ) -> GameStateClassification {
        let isFailure = title == .missionFailedTitle
        let titleObservation = OCRTextObservation(
            text: isFailure ? "任務失敗" : "任務完成！",
            rect: NormalizedRect(x: 0.39, y: 0.105, width: 0.21, height: 0.023),
            confidence: 1
        )
        let repeatObservation = OCRTextObservation(
            text: "重複進行此任務",
            rect: NormalizedRect(x: 0.0246, y: 0.236, width: 0.2857, height: 0.0202),
            confidence: 1
        )
        let selectedObservation = OCRTextObservation(
            text: "SELECTED",
            rect: NormalizedRect(x: 0.37, y: 0.224, width: 0.25, height: 0.034),
            confidence: 0.5
        )
        var evidence = [
            GameStateEvidence(kind: title, observation: titleObservation, detail: titleObservation.text),
            GameStateEvidence(
                kind: .missionRepeatOption,
                observation: repeatObservation,
                detail: repeatObservation.text
            ),
            GameStateEvidence(
                kind: .repeatSelectedMarker,
                observation: selectedObservation,
                detail: selectedObservation.text
            ),
        ]
        if let page {
            let pageObservation = OCRTextObservation(
                text: page == .missionExperiencePage ? "獲得經驗值" : "獲得拾得物",
                rect: NormalizedRect(x: 0.778, y: 0.146, width: 0.192, height: 0.0202),
                confidence: 1
            )
            evidence.append(GameStateEvidence(
                kind: page,
                observation: pageObservation,
                detail: pageObservation.text
            ))
        }
        return GameStateClassification(state: state, evidence: evidence, allowedActions: [])
    }
}
