import Foundation
import Testing
@testable import MirrorProbeCore

@Suite("Auto-level optional session limits")
struct AutoLevelUnlimitedRunTests {
    @Test("One default session continues past 500 cycles, 10000 actions, and eight hours")
    func defaultSessionKeepsItsStateBeyondFormerLimits() throws {
        var controller = makeController()
        #expect(controller.policy.maxCycles == nil)
        #expect(controller.policy.maxActions == nil)
        #expect(controller.policy.maxRuntime == nil)
        var now: TimeInterval = 0
        var postedActions = 0

        for cycle in 1...510 {
            #expect(controller.consume(snapshot(.battle, at: now)) == .wait(.battleInProgress))
            now += 2
            for _ in 0..<21 {
                let request = try action(controller.consume(snapshot(.wideModalOneButton, at: now)))
                postedActions += 1
                #expect(request.requestID == UInt64(postedActions))
                let marked = controller.markActionPosted(request, at: now + 0.1)
                #expect(marked)
                now += 2
                #expect(controller.consume(snapshot(.battle, at: now)) == .wait(.battleInProgress))
                now += 2
            }
            #expect(controller.consume(snapshot(.missionComplete, at: now)) == .completedCycle(
                .init(count: cycle, outcome: .success)
            ))
            now += 2
        }

        #expect(now > 8 * 60 * 60)
        #expect(controller.completedCycles == 510)
        #expect(controller.actionsIssued == 10_710)
        #expect(controller.consume(snapshot(.battle, at: now)) == .wait(.battleInProgress))
        let next = try action(controller.consume(snapshot(.wideModalOneButton, at: now + 2)))
        #expect(next.requestID == 10_711)
        let marked = controller.markActionPosted(next, at: now + 2.1)
        #expect(marked)
    }

    @Test("Explicit cycle limits still stop at the requested count")
    func explicitCycleLimitIsPreserved() {
        var controller = makeController(policy: AutoLevelPolicy(maxCycles: 2))
        #expect(controller.consume(snapshot(.missionComplete, at: 1)) == .completedCycle(
            .init(count: 1, outcome: .success)
        ))
        #expect(controller.consume(snapshot(.battle, at: 2)) == .wait(.battleInProgress))
        #expect(controller.consume(snapshot(.missionComplete, at: 3)) == .completedCycle(
            .init(count: 2, outcome: .success)
        ))
        #expect(controller.consume(snapshot(.battle, at: 4)) == .stop(.maximumCyclesReached(limit: 2)))
        #expect(controller.completedCycles == 2)
        #expect(controller.actionsIssued == 0)
    }

    @Test("Explicit action limits still stop at the requested count")
    func explicitActionLimitIsPreserved() throws {
        var controller = makeController(policy: AutoLevelPolicy(maxActions: 2))
        let first = try action(controller.consume(snapshot(.wideModalOneButton, at: 1)))
        let firstMarked = controller.markActionPosted(first, at: 1.1)
        #expect(firstMarked)
        #expect(controller.consume(snapshot(.battle, at: 2)) == .wait(.battleInProgress))
        let second = try action(controller.consume(snapshot(.wideModalOneButton, at: 3)))
        let secondMarked = controller.markActionPosted(second, at: 3.1)
        #expect(secondMarked)
        #expect(controller.consume(snapshot(.battle, at: 4)) == .stop(.maximumActionsReached(limit: 2)))
        #expect(controller.actionsIssued == 2)
    }

    @Test("Explicit runtime limits still reject observations and posting at the deadline")
    func explicitRuntimeLimitIsPreserved() throws {
        var controller = makeController(policy: AutoLevelPolicy(maxRuntime: 10))
        let request = try action(controller.consume(snapshot(.wideModalOneButton, at: 9)))
        let marked = controller.markActionPosted(request, at: 10)
        #expect(!marked)
        #expect(controller.consume(snapshot(.battle, at: 10)) == .stop(.maximumRuntimeReached(limit: 10)))
        #expect(controller.consume(snapshot(.battle, at: 11)) == .stop(.maximumRuntimeReached(limit: 10)))
    }

    @Test("Unlimited sessions retain their per-action posting deadline")
    func unlimitedSessionDoesNotRemoveActionTimeouts() throws {
        var controller = makeController()
        let request = try action(controller.consume(snapshot(.wideModalOneButton, at: 30_000)))
        let marked = controller.markActionPosted(request, at: 30_008)
        #expect(!marked)
        #expect(controller.consume(snapshot(.wideModalOneButton, at: 30_008)) == .stop(
            .actionDidNotAdvance(intent: .pressWideModalTopButton)
        ))
    }

    @Test("Explicit nonpositive count caps remain invalid", arguments: [0, -1])
    func nonpositiveCountCapsAreInvalid(limit: Int) {
        for policy in [AutoLevelPolicy(maxCycles: limit), AutoLevelPolicy(maxActions: limit)] {
            var controller = makeController(policy: policy)
            #expect(controller.consume(snapshot(.battle, at: 1)) == .stop(.invalidPolicy))
        }
    }

    @Test("Explicit nonfinite and nonpositive runtime caps remain invalid",
          arguments: [TimeInterval.zero, -1, .infinity, -.infinity, .nan])
    func invalidRuntimeCapsAreRejected(limit: TimeInterval) {
        var controller = makeController(policy: AutoLevelPolicy(maxRuntime: limit))
        #expect(controller.consume(snapshot(.battle, at: 1)) == .stop(.invalidPolicy))
    }

    @Test("Finite, omitted, and partially omitted policy caps round-trip through Codable")
    func policyLimitsRoundTrip() throws {
        let policies = [
            AutoLevelPolicy(),
            AutoLevelPolicy(maxCycles: 750, maxRuntime: 36_000, maxActions: 12_000),
            AutoLevelPolicy(maxCycles: 750),
            AutoLevelPolicy(maxRuntime: 60),
            AutoLevelPolicy(maxActions: 3),
        ]
        for policy in policies {
            let data = try JSONEncoder().encode(policy)
            #expect(try JSONDecoder().decode(AutoLevelPolicy.self, from: data) == policy)
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect((object["maxCycles"] as? Int) == policy.maxCycles)
            #expect((object["maxActions"] as? Int) == policy.maxActions)
            #expect((object["maxRuntime"] as? TimeInterval) == policy.maxRuntime)
        }
    }

    @Test("Legacy numeric policy caps and explicit null caps remain readable")
    func legacyAndNullPolicyLimitsDecode() throws {
        let finite = Data("""
            {"actionCooldown":0.8,"postActionTimeout":8,"uncertainStateGraceDuration":2,
             "uncertainStateGraceSnapshots":2,"maxCycles":100,"maxRuntime":28800,"maxActions":2000}
            """.utf8)
        #expect(try JSONDecoder().decode(AutoLevelPolicy.self, from: finite) == AutoLevelPolicy(
            maxCycles: 100, maxRuntime: 28_800, maxActions: 2_000
        ))
        let unlimited = Data("""
            {"actionCooldown":0.8,"postActionTimeout":8,"uncertainStateGraceDuration":2,
             "uncertainStateGraceSnapshots":2,"maxCycles":null,"maxRuntime":null,"maxActions":null}
            """.utf8)
        #expect(try JSONDecoder().decode(AutoLevelPolicy.self, from: unlimited) == AutoLevelPolicy())
    }

    private var identity: AutoLevelWindowIdentity {
        .init(processID: 42, windowID: 43)
    }

    private func makeController(policy: AutoLevelPolicy = AutoLevelPolicy()) -> AutoLevelController {
        AutoLevelController(session: .init(
            sessionID: "unlimited-test", startedAt: 0, windowIdentity: identity
        ), policy: policy)
    }

    private func snapshot(_ state: GameState, at time: TimeInterval) -> AutoLevelSnapshot {
        let actions: [AutoLevelActionCandidate] = state == .wideModalOneButton ? [
            .init(intent: .pressWideModalTopButton, target: .init(
                name: GameTargetName.wideModalTopButton.rawValue,
                sourceText: "close",
                rect: NormalizedRect(x: 0.3, y: 0.7, width: 0.4, height: 0.1)
            )),
        ] : []
        return AutoLevelSnapshot(
            classification: .init(state: state, evidence: [], allowedActions: []),
            runtime: .init(
                observedAt: time,
                windowIdentity: identity,
                frameFingerprint: "\(state.rawValue)-\(time)",
                allAutoStatus: .active,
                battleStatus: .inProgress
            ),
            supplementalActionCandidates: actions
        )
    }

    private func action(_ decision: AutoLevelDecision) throws -> AutoLevelActionRequest {
        let request: AutoLevelActionRequest?
        if case let .requestAction(value) = decision {
            request = value
        } else {
            request = nil
        }
        return try #require(request)
    }
}
