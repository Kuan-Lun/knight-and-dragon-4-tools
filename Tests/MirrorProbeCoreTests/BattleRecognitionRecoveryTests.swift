import Foundation
import Testing
@testable import MirrorProbeCore

@Suite("Recovery from a persistently obscured battle footer")
struct BattleRecognitionRecoveryTests {
    @Test("Thirty seconds bypasses only this recognition grace and requests measured retreat once")
    func recognitionTimeoutRetreats() throws {
        var policy = BattleRecognitionRecovery()
        var controller = controller()
        let initial = sample(at: 0, classification: battle())
        #expect(policy.observe(initial) == nil)
        #expect(controller.consume(snapshot(initial)) == .wait(.battleInProgress))

        for second in 1...30 {
            let current = sample(at: Double(second))
            let observed = policy.observe(current)
            let assessment = try #require(observed)
            #expect(assessment.elapsedSeconds == Double(second - 1))
            #expect(!assessment.isReady)
            #expect(controller.consume(snapshot(current), battleRecognitionRecovery: assessment)
                    == .wait(.battleRecognitionRecovery(remaining: Double(31 - second))))
            #expect(controller.actionsIssued == 0)
        }
        let final = sample(at: 31)
        let observed = policy.observe(final)
        let assessment = try #require(observed)
        #expect(assessment.isReady)
        #expect(final.classification.state == .unknown)
        #expect(final.classification.allowedActions.isEmpty)
        #expect(final.classification.policyGatedActions.isEmpty)
        let request = try action(controller.consume(snapshot(final), battleRecognitionRecovery: assessment))
        #expect(request.intent == .requestRetreat)
        #expect(request.observedState == .unknown)
        #expect(request.target.sourceText == VisualBattleEvidence.measuredRetreatSentinel)
        #expect(request.target.rect == VisualBattleEvidence.measuredRetreatRect)
        #expect(request.target.point == VisualBattleEvidence.measuredRetreatRect.center)
        #expect(controller.actionsIssued == 1)
        let posted = controller.markActionPosted(request, at: 31.1)
        #expect(posted)

        let after = sample(at: 32, classification: .init(state: .missionFailed, evidence: [], allowedActions: []))
        #expect(policy.observe(after) == nil)
        #expect(controller.consume(snapshot(after)) == .completedCycle(.init(count: 1, outcome: .failure)))
        #expect(controller.pendingActionAcknowledgementDeadline == nil)
        #expect(controller.actionsIssued == 1)
    }

    @Test("An unknown startup and a gap after a known battle never establish eligibility")
    func requiresRecentBattle() throws {
        var policy = BattleRecognitionRecovery()
        for second in 0...40 {
            #expect(policy.observe(sample(at: Double(second))) == nil)
        }
        #expect(policy.observe(sample(at: 41, classification: battle())) == nil)
        #expect(policy.observe(sample(at: 46.001)) == nil)
        #expect(policy.observe(sample(at: 47)) == nil)
        #expect(policy.observe(sample(at: 48, classification: battle())) == nil)
        let observed = policy.observe(sample(at: 53))
        let accepted = try #require(observed)
        #expect(accepted.elapsedSeconds == 0)
    }

    @Test("Every discontinuity revokes eligibility until another full battle is observed",
          arguments: Interruption.allCases)
    func interruptsContinuity(reason: Interruption) throws {
        var policy = BattleRecognitionRecovery()
        _ = policy.observe(sample(at: 0, classification: battle()))
        let firstObserved = policy.observe(sample(at: 1))
        _ = try #require(firstObserved)
        let secondObserved = policy.observe(sample(at: 2))
        _ = try #require(secondObserved)
        let interrupted: BattleRecognitionRecoverySample
        switch reason {
        case .missingRetreat:
            interrupted = sample(at: 3, classification: .init(state: .unknown, evidence: [], allowedActions: []))
        case .modal:
            interrupted = sample(at: 3, classification: .init(state: .wideModalTwoButtons, evidence: [], allowedActions: []))
        case .result:
            interrupted = sample(at: 3, classification: .init(state: .missionComplete, evidence: [], allowedActions: []))
        case .differentBattle:
            interrupted = sample(at: 3, battleID: "another-battle")
        case .input:
            interrupted = sample(at: 3, inputGeneration: 1)
        case .window:
            interrupted = sample(at: 3, identity: .init(processID: 44, windowID: 7))
        case .geometry:
            interrupted = sample(at: 3, originX: 101)
        case .gap:
            interrupted = sample(at: 7.001)
        case .duplicateTime:
            interrupted = sample(at: 2)
        case .backwardTime:
            interrupted = sample(at: 1.9)
        case .invalidTime:
            interrupted = sample(at: .nan)
        }
        #expect(policy.observe(interrupted) == nil)
        #expect(policy.observe(sample(at: 10)) == nil)
        #expect(policy.observe(sample(at: 11, classification: battle())) == nil)
        let observed = policy.observe(sample(at: 12))
        let restarted = try #require(observed)
        #expect(restarted.elapsedSeconds == 0)
    }

    @Test("A restored footer discards elapsed time and permits a new independent chain")
    func normalBattleResetsTimer() throws {
        var policy = BattleRecognitionRecovery()
        _ = policy.observe(sample(at: 0, classification: battle()))
        for second in 1...20 {
            let observed = policy.observe(sample(at: Double(second)))
            _ = try #require(observed)
        }
        #expect(policy.observe(sample(at: 21, classification: battle())) == nil)
        let observed = policy.observe(sample(at: 22))
        let restarted = try #require(observed)
        #expect(restarted.elapsedSeconds == 0)
        #expect(!restarted.isReady)
        policy.reset()
        #expect(policy.observe(sample(at: 23)) == nil)
    }

    @Test("The exact issued observation and fresh preflight cannot substitute a page or continuity")
    func authorizationBindings() throws {
        let (assessment, final) = try readyAssessment()
        #expect(assessment.matches(snapshot(final)))
        #expect(!assessment.matches(snapshot(sample(at: 31, fingerprint: "different-frame"))))
        #expect(!assessment.matches(snapshot(sample(at: 31, battleID: "other-battle"))))
        #expect(!assessment.matches(snapshot(sample(at: 31, identity: .init(processID: 44, windowID: 7)))))
        #expect(!assessment.matches(snapshot(sample(at: 32))))
        #expect(!assessment.matches(snapshot(sample(at: 31, classification: battle()))))
        #expect(assessment.canPreflight(sample(at: 32)))
        #expect(assessment.canPreflight(sample(at: 32, fingerprint: final.runtime.frameFingerprint)))
        #expect(assessment.canPreflight(sample(at: 42.999)))
        #expect(!assessment.canPreflight(sample(at: 43)))
        #expect(!assessment.canPreflight(final))
        #expect(!assessment.canPreflight(sample(at: 30.99)))
        #expect(!assessment.canPreflight(sample(at: 32, classification: battle())))
        #expect(!assessment.canPreflight(sample(at: 32, classification: .init(state: .wideModalOneButton, evidence: [], allowedActions: []))))
        #expect(!assessment.canPreflight(sample(at: 32, classification: .init(state: .unknown, evidence: [], allowedActions: []))))
        #expect(!assessment.canPreflight(sample(at: 32, inputGeneration: 1)))
        #expect(!assessment.canPreflight(sample(at: 32, battleID: "other-battle")))
        #expect(!assessment.canPreflight(sample(at: 32, originX: 101)))
        #expect(!assessment.canPreflight(sample(at: 32, identity: .init(processID: 44, windowID: 7))))
    }

    @Test("Recovery preserves action freshness, session caps, and pending acknowledgements")
    func controllerBoundaries() throws {
        let (assessment, final) = try readyAssessment()
        var freshController = controller()
        #expect(freshController.consume(snapshot(final), allowNewActions: false,
                                        battleRecognitionRecovery: assessment) == .wait(.freshObservationRequired))
        #expect(freshController.actionsIssued == 0)
        let request = try action(freshController.consume(snapshot(final), battleRecognitionRecovery: assessment))
        #expect(freshController.consume(snapshot(final), battleRecognitionRecovery: assessment)
                == .wait(.awaitingFrameChange(intent: .requestRetreat)))
        #expect(freshController.actionsIssued == 1)
        let cancelled = freshController.cancelUnpostedRetreat(request)
        #expect(cancelled)
        #expect(freshController.consume(snapshot(final), battleRecognitionRecovery: assessment)
                == .wait(.actionCooldown(remaining: 0.8)))
        #expect(freshController.actionsIssued == 1)

        var capped = controller(policy: .init(maxRuntime: 31))
        #expect(capped.consume(snapshot(final), battleRecognitionRecovery: assessment)
                == .stop(.maximumRuntimeReached(limit: 31)))
        var actionCapped = controller(policy: .init(maxActions: 1))
        let cappedRequest = try action(actionCapped.consume(snapshot(final), battleRecognitionRecovery: assessment))
        let cappedCancelled = actionCapped.cancelUnpostedRetreat(cappedRequest)
        #expect(cappedCancelled)
        #expect(actionCapped.consume(snapshot(final), battleRecognitionRecovery: assessment)
                == .stop(.maximumActionsReached(limit: 1)))

        var unrelated = controller()
        #expect(unrelated.consume(snapshot(sample(at: 31, fingerprint: "different-frame")),
                                  battleRecognitionRecovery: assessment)
                == .wait(.transientState(kind: .unknown, observationCount: 1)))
        #expect(unrelated.actionsIssued == 0)
    }

    @Test("A failed preflight cannot acknowledge an unposted retreat with a failure result")
    func unpostedFailureIsNotAcknowledgement() throws {
        let (assessment, final) = try readyAssessment()
        var controller = controller()
        _ = try action(controller.consume(snapshot(final), battleRecognitionRecovery: assessment))
        let failed = sample(at: 32, classification: .init(state: .missionFailed, evidence: [], allowedActions: []))
        #expect(controller.consume(snapshot(failed)) == .stop(.unexpectedTransition(
            intent: .requestRetreat, from: .unknown, to: .missionFailed
        )))
        #expect(controller.completedCycles == 0)
    }

    enum Interruption: String, CaseIterable, Sendable {
        case missingRetreat, modal, result, differentBattle, input, window, geometry, gap
        case duplicateTime, backwardTime, invalidTime
    }

    private func readyAssessment() throws -> (BattleRecognitionRecoveryAssessment, BattleRecognitionRecoverySample) {
        var policy = BattleRecognitionRecovery()
        _ = policy.observe(sample(at: 0, classification: battle()))
        for second in 1...30 {
            let observed = policy.observe(sample(at: Double(second)))
            _ = try #require(observed)
        }
        let final = sample(at: 31)
        let observed = policy.observe(final)
        return (try #require(observed), final)
    }

    private func controller(policy: AutoLevelPolicy = .init()) -> AutoLevelController {
        .init(session: .init(sessionID: "footer-recovery", startedAt: 0,
                             windowIdentity: .init(processID: 44, windowID: 6)), policy: policy)
    }

    private func snapshot(_ sample: BattleRecognitionRecoverySample) -> AutoLevelSnapshot {
        .init(classification: sample.classification, runtime: sample.runtime)
    }

    private func sample(
        at time: TimeInterval,
        classification: GameStateClassification? = nil,
        fingerprint: String? = nil,
        battleID: String = "battle-1",
        inputGeneration: UInt64 = 0,
        identity: AutoLevelWindowIdentity = .init(processID: 44, windowID: 6),
        originX: Double = 100
    ) -> BattleRecognitionRecoverySample {
        .init(classification: classification ?? obscured(),
              runtime: .init(observedAt: time, windowIdentity: identity,
                             frameFingerprint: fingerprint ?? "frame-\(time)", battleSessionID: battleID,
                             allAutoStatus: .active),
              context: .init(processID: identity.processID, windowID: identity.windowID,
                             originX: originX, originY: 200, width: 406, height: 890),
              inputGeneration: inputGeneration)
    }

    private func obscured() -> GameStateClassification {
        .init(state: .unknown, evidence: [
            marker(.retreatControl),
            .init(kind: .battleFooterOcclusion, observation: nil, detail: "incompleteFooterMarkers"),
            .init(kind: .lowConfidenceMarker, observation: nil, detail: "result markers absent"),
        ], allowedActions: [])
    }

    private func battle() -> GameStateClassification {
        .init(state: .battle, evidence: [marker(.skipControl), marker(.allAutoControl), marker(.retreatControl)],
              allowedActions: [])
    }

    private func marker(_ marker: VisualBattleMarker) -> GameStateEvidence {
        .init(kind: .battleMarker, observation: nil, detail: "synthetic measured marker",
              battleVisualMatch: .init(marker: marker, region: VisualBattleMatch.regions(for: marker)[0], similarity: 0.95))
    }

    private func action(_ decision: AutoLevelDecision) throws -> AutoLevelActionRequest {
        guard case let .requestAction(request) = decision else {
            Issue.record("Expected a retreat request, got \(decision)")
            throw TestFailure.expectedAction
        }
        return request
    }

    private enum TestFailure: Error { case expectedAction }
}
