import CoreGraphics
import Foundation
import MirrorProbeCore
import Testing
@testable import MirrorProbeRuntime

@Suite("Posted action acknowledgement capture deadlines")
struct AutomationAcknowledgementDeadlineTests {
    private let identity = AutoLevelWindowIdentity(processID: 20, windowID: 10)
    private let frame = CGRect(x: 1, y: 30, width: 404, height: 874)

    @Test("The retained timeout capture reaches the controller's bounded repeat retry",
          arguments: [false, true])
    func incidentCaptureReachesRetry(deadlineCrossedDuringQuery: Bool) async throws {
        let directory = try RuntimeTestDirectory()
        defer { directory.remove() }
        let recovery = context(directory)
        let harness = AcknowledgementDeadlineHarness()
        let fixture = try #require(Bundle.module.url(
            forResource: "visual-repeat-timeout-404x874", withExtension: "png"
        ))
        let loaded = try MirrorProbeRuntime.loadPNG(at: fixture)
        #expect(loaded.image.width == 404)
        #expect(loaded.image.height == 874)
        #expect(loaded.sha256 == "2f304ad2a6042549fd7ddf166c58de1ae93e2c6c656db3790d1192a4a22b9a54")
        let rgba = try MirrorProbeRuntime.rgbaFrame(from: loaded.image)
        let fingerprint = MirrorProbeRuntime.sha256Hex(of: Data(rgba.bytes))

        // Replay the real pixels for each fresh observation. Neither the selector nor this
        // deterministic controller harness can post any input to the running game.
        func snapshot() throws -> AutoLevelSnapshot {
            let classification = try MirrorProbeRuntime.recognizeGameState(in: loaded.image, rgba: rgba)
            #expect(classification.state == .missionFailed)
            #expect(classification.evidence.contains { $0.kind == .repeatUnselectedMarker })
            #expect(!classification.evidence.contains { $0.kind == .repeatSelectedMarker })
            return AutoLevelSnapshot(
                classification: classification,
                runtime: .init(observedAt: harness.time, windowIdentity: identity,
                               frameFingerprint: fingerprint)
            )
        }

        var controller = AutoLevelController(
            session: .init(sessionID: "retained-repeat-timeout", startedAt: harness.time,
                           windowIdentity: identity),
            policy: .init(actionCooldown: 0, postActionTimeout: 12)
        )
        #expect(controller.consume(try snapshot()) == .completedCycle(.init(count: 1, outcome: .failure)))
        var request = try #require(action(in: controller.consume(try snapshot())))
        #expect(request.intent == .selectMissionRepeat)
        #expect(request.repeatSelectionRetryPage == nil)

        for attempt in 1...3 {
            #expect(request.requestID == UInt64(attempt))
            #expect(request.completedCycles == 1)
            harness.time += 0.25
            let marked = controller.markActionPosted(request, at: harness.time)
            #expect(marked)
            let deadline = try #require(controller.pendingActionAcknowledgementDeadline)

            harness.time += 0.25
            #expect(controller.consume(try snapshot()) == .wait(.awaitingFrameChange(intent: .selectMissionRepeat)))
            #expect(controller.pendingActionAcknowledgementDeadline == deadline)
            harness.time = deadline + (deadlineCrossedDuringQuery ? -0.25 : 0.25)
            harness.queryDelay = deadlineCrossedDuringQuery ? 0.5 : 0
            let selected = try await select(
                [[candidate()]], recovery: recovery, harness: harness,
                deadline: .actionAcknowledgement(deadline)
            )
            #expect(selected == 10)
            #expect(harness.time > deadline)
            #expect(controller.pendingActionAcknowledgementDeadline == deadline)

            let decision = controller.consume(try snapshot())
            #expect(controller.completedCycles == 1)
            if attempt < 3 {
                let retry = try #require(action(in: decision))
                #expect(retry.requestID == request.requestID + 1)
                #expect(retry.intent == .selectMissionRepeat)
                #expect(retry.target == request.target)
                #expect(retry.repeatSelectionRetryPage == .experience)
                #expect(controller.pendingActionAcknowledgementDeadline == nil)
                request = retry
            } else {
                #expect(decision == .stop(.actionDidNotAdvance(intent: .selectMissionRepeat)))
            }
        }
        #expect(controller.actionsIssued == 3)
        #expect(harness.queryCount == 3)
        #expect(harness.pauses.isEmpty)
        #expect(harness.diagnostics.isEmpty)
        #expect(recovery.generation == 0)
    }

    @Test("Hard input authorization expiry still rejects before or after the first query",
          arguments: [false, true])
    func inputAuthorizationStillExpires(deadlineCrossedDuringQuery: Bool) async throws {
        let directory = try RuntimeTestDirectory()
        defer { directory.remove() }
        let recovery = context(directory)
        let harness = AcknowledgementDeadlineHarness()
        let deadline = harness.time + (deadlineCrossedDuringQuery ? 0.25 : 0)
        harness.queryDelay = deadlineCrossedDuringQuery ? 0.5 : 0
        do {
            _ = try await select([[candidate()]], recovery: recovery, harness: harness,
                                 deadline: .inputAuthorization(deadline))
            Issue.record("Expired input authorization unexpectedly selected a window")
        } catch ProbeError.unsafeWindow(let detail) {
            #expect(detail.contains("recoveryStop=actionExpired"))
            #expect(detail.contains(deadlineCrossedDuringQuery ? "reason=available" : "reason=notQueried"))
            #expect(detail.contains("queryCompleted=\(deadlineCrossedDuringQuery)"))
            #expect(!detail.contains("reason=missing"))
        }
        #expect(harness.queryCount == (deadlineCrossedDuringQuery ? 1 : 0))
        #expect(harness.pauses.isEmpty)
        #expect(recovery.generation == 0)
    }

    @Test("Both deadline purposes reject invalid clocks before any window query", arguments: [
        AutomationCaptureDeadline.inputAuthorization(-1), .inputAuthorization(.infinity),
        .inputAuthorization(.nan), .actionAcknowledgement(-1),
        .actionAcknowledgement(.infinity), .actionAcknowledgement(.nan),
    ])
    func invalidDeadlineIsRejected(deadline: AutomationCaptureDeadline) async throws {
        let directory = try RuntimeTestDirectory()
        defer { directory.remove() }
        let recovery = context(directory)
        let harness = AcknowledgementDeadlineHarness()
        do {
            _ = try await select([[candidate()]], recovery: recovery, harness: harness,
                                 deadline: deadline)
            Issue.record("Invalid deadline unexpectedly selected a window")
        } catch ProbeError.unsafeWindow(let detail) {
            #expect(detail.contains("recoveryStop=invalidClock"))
            #expect(detail.contains("reason=notQueried"))
            #expect(detail.contains("queryCompleted=false"))
        }
        #expect(harness.queryCount == 0)
        #expect(harness.pauses.isEmpty)
        #expect(recovery.generation == 0)
    }

    @Test("An expired acknowledgement permits one observation but cannot start window recovery",
          arguments: [false, true])
    func expiredAcknowledgementCannotRecover(moved: Bool) async throws {
        let directory = try RuntimeTestDirectory()
        defer { directory.remove() }
        let recovery = context(directory)
        let harness = AcknowledgementDeadlineHarness()
        let samples = moved ? [candidate(frame: frame.offsetBy(dx: 30, dy: 0))] : []
        await #expect(throws: ProbeError.self) {
            try await select([samples], recovery: recovery, harness: harness,
                             deadline: .actionAcknowledgement(harness.time - 1))
        }
        #expect(harness.queryCount == 1)
        #expect(harness.pauses.isEmpty)
        #expect(recovery.currentFrame == nil)
        let diagnostic = try #require(harness.diagnostics.last)
        #expect(diagnostic.outcome == "exhausted")
        #expect(diagnostic.detail.contains("recoveryStop=actionExpired"))
        #expect(diagnostic.detail.contains(moved ? "reason=geometryMismatch" : "reason=missing"))
    }

    @Test("A slow recovery query cannot return or adopt a window after the original acknowledgement deadline",
          arguments: [false, true])
    func recoveryCannotExtendAcknowledgement(moved: Bool) async throws {
        let directory = try RuntimeTestDirectory()
        defer { directory.remove() }
        let recovery = context(directory)
        let harness = AcknowledgementDeadlineHarness()
        let deadline = harness.time + 1.25
        let changed = candidate(frame: frame.offsetBy(dx: 30, dy: 0))
        let samples = moved ? [[changed], [changed]] : [[], [candidate()]]
        harness.onQuery = { query in
            if query == 2 { harness.time += 0.5 }
        }
        await #expect(throws: ProbeError.self) {
            try await select(samples, recovery: recovery, harness: harness,
                             deadline: .actionAcknowledgement(deadline))
        }
        #expect(harness.queryCount == 2)
        #expect(harness.time > deadline)
        #expect(recovery.currentFrame == nil)
        #expect(recovery.generation == 1)
        #expect(harness.diagnostics.last?.detail.contains("recoveryStop=actionExpired") == true)
    }

    @Test("A different process cannot reuse a window number after acknowledgement expiry")
    func changedProcessRemainsRejected() async throws {
        let directory = try RuntimeTestDirectory()
        defer { directory.remove() }
        let recovery = context(directory)
        let harness = AcknowledgementDeadlineHarness()
        let replacement = candidate(identity: .init(processID: 21, windowID: 10))
        do {
            _ = try await select([[replacement]], recovery: recovery, harness: harness,
                                 deadline: .actionAcknowledgement(harness.time - 1))
            Issue.record("Changed process unexpectedly selected the reused window number")
        } catch ProbeError.unsafeWindow(let detail) {
            #expect(detail.contains("identityChanged=true"))
            #expect(detail.contains("reason=identityChanged"))
            #expect(detail.contains("queryCompleted=true"))
        }
        #expect(harness.queryCount == 1)
        #expect(harness.pauses.isEmpty)
        #expect(recovery.generation == 0)
        #expect(recovery.currentFrame == nil)
    }

    private func action(in decision: AutoLevelDecision) -> AutoLevelActionRequest? {
        guard case let .requestAction(request) = decision else { return nil }
        return request
    }

    private func context(_ directory: RuntimeTestDirectory) -> AutomationWindowRecoveryContext {
        .init(stopURL: directory.url.appendingPathComponent("STOP"), sessionDeadline: nil)
    }

    private func candidate(frame: CGRect? = nil, identity: AutoLevelWindowIdentity? = nil)
        -> AutomationWindowSelectionCandidate<Int> {
        .init(window: 10, identity: identity ?? self.identity,
              frame: frame ?? self.frame, isEligible: true)
    }

    private func select(_ samples: [[AutomationWindowSelectionCandidate<Int>]],
                        recovery: AutomationWindowRecoveryContext,
                        harness: AcknowledgementDeadlineHarness,
                        deadline: AutomationCaptureDeadline) async throws -> Int {
        var localQueryCount = 0
        return try await AutomationWindowSelectionRecovery.select(
            expectedIdentity: identity, expectedFrame: frame, recovery: recovery,
            deadline: deadline,
            query: {
                localQueryCount += 1
                harness.queryCount += 1
                harness.time += harness.queryDelay
                harness.onQuery?(harness.queryCount)
                return samples[min(localQueryCount - 1, samples.count - 1)]
            },
            now: { harness.time },
            pause: { delay in
                harness.pauses.append(delay)
                harness.time += delay
            },
            diagnostic: { outcome, _, _, detail in
                harness.diagnostics.append(.init(outcome: outcome, detail: detail))
            }
        )
    }
}

private final class AcknowledgementDeadlineHarness {
    struct Diagnostic {
        let outcome: String
        let detail: String
    }

    var time = ProcessInfo.processInfo.systemUptime
    var queryCount = 0
    var queryDelay: TimeInterval = 0
    var pauses: [TimeInterval] = []
    var diagnostics: [Diagnostic] = []
    var onQuery: ((Int) -> Void)?
}
