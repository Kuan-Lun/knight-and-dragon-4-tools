import Foundation
import Testing
@testable import MirrorProbeCore

@Suite("Unacknowledged experience-page replay")
struct MissionExperienceAdvanceReplayTests {
    @Test("The captured 23:00 EXP page retries after timeout, not after focus-only pixel changes")
    func actualFailureReceivesBoundedRecovery() throws {
        struct Fixture: Decodable { let classification: GameStateClassification }
        let url = try #require(Bundle.module.url(
            forResource: "mission-exp-unacknowledged", withExtension: "json"
        ))
        let classification = try JSONDecoder().decode(
            Fixture.self, from: Data(contentsOf: url)
        ).classification
        #expect(classification.state == .missionCompleteRepeatSelected)
        #expect(MissionSuccessPageIdentity.resolve(in: classification) == .experience)
        let identity = AutoLevelWindowIdentity(processID: 9823, windowID: 51767)
        var controller = AutoLevelController(
            session: .init(sessionID: "exp-replay", startedAt: 0, windowIdentity: identity),
            policy: .init(postActionTimeout: 12)
        )
        func snapshot(_ time: Double, borrowedFocus: Bool = false) -> AutoLevelSnapshot {
            AutoLevelSnapshot(
                classification: classification,
                runtime: .init(
                    observedAt: time, windowIdentity: identity,
                    frameFingerprint: borrowedFocus
                        ? "b8522908762cc6d7c9927a1332be9856cc8d4787cf418dd560cd1133a7b181aa"
                        : "89db8ae9dafd88cd0cddd1d0048ebce5a09ec8580754b6970b9078052dfe10a1"
                )
            )
        }
        #expect(controller.consume(snapshot(0.0766)) == .completedCycle(.init(
            count: 1, outcome: .success
        )))
        guard case let .requestAction(first) = controller.consume(snapshot(0.0766)) else {
            Issue.record("The measured EXP arrow should be available")
            return
        }
        let firstPosted = controller.markActionPosted(first, at: 1)
        #expect(firstPosted)
        #expect(controller.consume(snapshot(2.0406, borrowedFocus: true)) == .wait(
            .awaitingStateChange(intent: .advanceMissionSuccess)
        ))
        #expect(controller.consume(snapshot(3.7882)) == .wait(
            .awaitingFrameChange(intent: .advanceMissionSuccess)
        ))
        guard case let .requestAction(second) = controller.consume(snapshot(14.2015)) else {
            Issue.record("The unchanged EXP page must get its bounded second attempt")
            return
        }
        #expect(second.requestID != first.requestID)
        #expect(second.target == first.target)
        let secondPosted = controller.markActionPosted(second, at: 15)
        #expect(secondPosted)
        guard case let .requestAction(third) = controller.consume(snapshot(27.1)) else {
            Issue.record("The unchanged EXP page must get its final bounded attempt")
            return
        }
        let thirdPosted = controller.markActionPosted(third, at: 28)
        #expect(thirdPosted)
        #expect(controller.consume(snapshot(40.1)) == .stop(
            .actionDidNotAdvance(intent: .advanceMissionSuccess)
        ))
        #expect(controller.actionsIssued == 3)
        #expect(controller.completedCycles == 1)
    }
}
