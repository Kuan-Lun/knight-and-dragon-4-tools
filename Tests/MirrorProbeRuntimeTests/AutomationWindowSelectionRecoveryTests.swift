import CoreGraphics
import Foundation
import MirrorProbeCore
import Testing
@testable import MirrorProbeRuntime

@Suite("Production window selection recovery")
struct AutomationWindowSelectionRecoveryTests {
    private let identity = AutoLevelWindowIdentity(processID: 20, windowID: 10)
    private let frame = CGRect(x: 40, y: 80, width: 406, height: 890)

    @Test("An unchanged window returns immediately without interrupting visual continuity")
    func unchangedWindow() async throws {
        let directory = try RuntimeTestDirectory()
        defer { directory.remove() }
        let recovery = context(directory)
        let harness = SelectionRecoveryHarness()
        let selected = try await select([[candidate()]], recovery: recovery, harness: harness)
        #expect(selected == 10)
        #expect(harness.queryCount == 1)
        #expect(harness.pauses.isEmpty)
        #expect(harness.diagnostics.isEmpty)
        #expect(recovery.generation == 0)
    }

    @Test("A transient move or resize can return immediately to the original geometry",
          arguments: [CGRect(x: 70, y: 80, width: 406, height: 890),
                      CGRect(x: 40, y: 80, width: 450, height: 970)])
    func transientGeometry(changed: CGRect) async throws {
        let directory = try RuntimeTestDirectory()
        defer { directory.remove() }
        let recovery = context(directory)
        let harness = SelectionRecoveryHarness()
        let selected = try await select(
            [[candidate(frame: changed)], [candidate()]], recovery: recovery, harness: harness
        )
        #expect(selected == 10)
        #expect(harness.queryCount == 2)
        #expect(harness.diagnostics.map(\.outcome) == ["geometryMismatch", "recovered"])
        #expect(harness.diagnostics.last?.detail.contains("sameIdentityAndGeometry=true") == true)
        #expect(harness.pauses.allSatisfy { $0 > 0 && $0 <= 0.1 })
        #expect(recovery.generation == 1)
        #expect(recovery.currentFrame == nil)
    }

    @Test("A moved or resized window is accepted after two identical samples a second apart",
          arguments: [CGRect(x: 70, y: 80, width: 406, height: 890),
                      CGRect(x: 40, y: 80, width: 450, height: 970)])
    func stableGeometry(changed: CGRect) async throws {
        let directory = try RuntimeTestDirectory()
        defer { directory.remove() }
        let recovery = context(directory)
        let harness = SelectionRecoveryHarness()
        let selected = try await select([[candidate(frame: changed)]],
                                        recovery: recovery, harness: harness)
        #expect(selected == 10)
        #expect(harness.queryCount == 2)
        #expect(harness.queryTimes[1] - harness.queryTimes[0] >= 1)
        #expect(harness.diagnostics.map(\.outcome) == ["geometryMismatch", "geometryRecovered"])
        #expect(recovery.currentFrame == changed)
        #expect(recovery.generation == 1)

        // A later selection uses the accepted frame even when its caller still supplies the
        // session's original frame. It must not start another recovery for the same geometry.
        let pauseCount = harness.pauses.count
        _ = try await select([[candidate(frame: changed)]], recovery: recovery, harness: harness)
        #expect(harness.queryCount == 3)
        #expect(harness.pauses.count == pauseCount)
        #expect(harness.diagnostics.count == 2)
        #expect(recovery.generation == 1)
    }

    @Test("Disconnecting a display may settle the same 404-point window from height 886 to 874")
    func displayDisconnectHeight() async throws {
        let directory = try RuntimeTestDirectory()
        defer { directory.remove() }
        let recovery = context(directory)
        let harness = SelectionRecoveryHarness()
        let original = CGRect(x: 1, y: 30, width: 404, height: 886)
        let changed = CGRect(x: 1, y: 30, width: 404, height: 874)
        _ = try await select([[candidate(frame: changed)]], recovery: recovery, harness: harness,
                             expectedFrame: original)
        #expect(harness.queryCount == 2)
        #expect(recovery.currentFrame == changed)
        #expect(recovery.generation == 1)
        let terminal = try #require(harness.diagnostics.last)
        #expect(terminal.outcome == "geometryRecovered")
        #expect(terminal.detail.contains("oldFrame=[x=1.0,y=30.0,width=404.0,height=886.0]"))
        #expect(terminal.detail.contains("newFrame=[x=1.0,y=30.0,width=404.0,height=874.0]"))
    }

    @Test("Even subpoint drift cannot accumulate into stable geometry within the four queries")
    func driftingGeometry() async throws {
        let directory = try RuntimeTestDirectory()
        defer { directory.remove() }
        let recovery = context(directory)
        let harness = SelectionRecoveryHarness()
        let samples = [140.0, 140.1, 140.2, 140.3].map {
            [candidate(frame: CGRect(x: $0, y: 80, width: 406, height: 890))]
        }
        await #expect(throws: ProbeError.self) {
            try await select(samples, recovery: recovery, harness: harness)
        }
        #expect(harness.queryCount == 4)
        #expect(recovery.generation == 1)
        let terminal = try #require(harness.diagnostics.last)
        #expect(terminal.outcome == "exhausted")
        #expect(terminal.detail.contains("reason=geometryMismatch"))
        #expect(terminal.detail.contains("expectedFrame=[x=40.0"))
        #expect(terminal.detail.contains("actualFrame=[x=140.3"))
        #expect(terminal.detail.contains("recoveryStop=attemptsExhausted"))
        #expect(recovery.currentFrame == nil)
    }

    @Test("Missing or ineligible samples interrupt geometry stability without renewing recovery",
          arguments: [true, false])
    func interruptedStability(missing: Bool) async throws {
        let directory = try RuntimeTestDirectory()
        defer { directory.remove() }
        let recovery = context(directory)
        let harness = SelectionRecoveryHarness()
        let changed = frame.offsetBy(dx: 30, dy: 0)
        let moved = candidate(frame: changed)
        let interruption = missing ? [] : [candidate(frame: changed, isEligible: false)]
        _ = try await select([[moved], interruption, [moved], [moved]],
                             recovery: recovery, harness: harness)
        #expect(harness.queryCount == 4)
        #expect(harness.diagnostics.map(\.outcome)
            == ["geometryMismatch", "missing", "geometryMismatch", "geometryRecovered"])
        #expect(Set(harness.diagnostics.map(\.startedAt)).count == 1)
        #expect(recovery.currentFrame == changed)
        #expect(recovery.generation == 1)
    }

    @Test("Invalid or empty geometry cannot become an accepted stable frame",
          arguments: [CGRect(x: 40, y: 80, width: 0, height: 890),
                      CGRect(x: 40, y: 80, width: -20, height: 890),
                      CGRect(x: Double.infinity, y: 80, width: 406, height: 890)])
    func invalidStableGeometry(changed: CGRect) async throws {
        let directory = try RuntimeTestDirectory()
        defer { directory.remove() }
        let recovery = context(directory)
        let harness = SelectionRecoveryHarness()
        await #expect(throws: ProbeError.self) {
            try await select([[candidate(frame: changed)]], recovery: recovery, harness: harness)
        }
        #expect(harness.queryCount == 4)
        #expect(recovery.currentFrame == nil)
        #expect(harness.diagnostics.last?.outcome == "exhausted")
    }

    @Test("Alternating missing and moved samples share the original recovery budget")
    func alternatingFailures() async throws {
        let directory = try RuntimeTestDirectory()
        defer { directory.remove() }
        let recovery = context(directory)
        let harness = SelectionRecoveryHarness()
        let moved = candidate(frame: frame.offsetBy(dx: 30, dy: 0))
        await #expect(throws: ProbeError.self) {
            try await select([[], [moved], [], [moved]], recovery: recovery, harness: harness)
        }
        #expect(harness.queryCount == 4)
        #expect(recovery.generation == 1)
        #expect(harness.diagnostics.map(\.outcome)
            == ["missing", "geometryMismatch", "missing", "geometryMismatch", "exhausted"])
        #expect(Set(harness.diagnostics.map(\.startedAt)).count == 1)
        #expect(harness.diagnostics.map(\.attempt) == [1, 2, 3, 4, 4])
    }

    @Test("A matching window number owned by a different process is rejected without retry")
    func changedIdentity() async throws {
        let directory = try RuntimeTestDirectory()
        defer { directory.remove() }
        let recovery = context(directory)
        let harness = SelectionRecoveryHarness()
        let replacement = candidate(identity: .init(processID: 21, windowID: 10))
        await #expect(throws: ProbeError.self) {
            try await select([[replacement]], recovery: recovery, harness: harness)
        }
        #expect(harness.queryCount == 1)
        #expect(harness.pauses.isEmpty)
        #expect(harness.diagnostics.isEmpty)
        #expect(recovery.generation == 0)
    }

    @Test("Another window number never replaces the locked window")
    func differentWindowRemainsMissing() async throws {
        let directory = try RuntimeTestDirectory()
        defer { directory.remove() }
        let recovery = context(directory)
        let harness = SelectionRecoveryHarness()
        let replacement = candidate(identity: .init(processID: 20, windowID: 11))
        await #expect(throws: ProbeError.self) {
            try await select([[replacement]], recovery: recovery, harness: harness)
        }
        #expect(harness.queryCount == 4)
        #expect(harness.diagnostics.last?.detail.contains("reason=missing") == true)
        #expect(harness.diagnostics.last?.detail.contains("actualFrame=unavailable") == true)
    }

    @Test("Action expiry during a sliced wait stops before another window query")
    func actionDeadlineDuringWait() async throws {
        let directory = try RuntimeTestDirectory()
        defer { directory.remove() }
        let recovery = context(directory)
        let harness = SelectionRecoveryHarness()
        let deadline = harness.time + 0.25
        await #expect(throws: ProbeError.self) {
            try await select([[], [candidate()]], recovery: recovery, harness: harness,
                             actionDeadline: deadline)
        }
        #expect(harness.queryCount == 1)
        #expect(harness.diagnostics.last?.outcome == "exhausted")
        #expect(harness.diagnostics.last?.detail.contains("recoveryStop=actionExpired") == true)
    }

    @Test("A slow second stable sample cannot adopt geometry after action or recovery expiry",
          arguments: [true, false])
    func slowRecoveredQuery(actionExpiresFirst: Bool) async throws {
        let directory = try RuntimeTestDirectory()
        defer { directory.remove() }
        let recovery = context(directory)
        let harness = SelectionRecoveryHarness()
        let actionDeadline = actionExpiresFirst ? harness.time + 2 : nil
        let moved = candidate(frame: frame.offsetBy(dx: 30, dy: 0))
        harness.onQuery = { query in
            if query == 2 { harness.time += 5 }
        }
        await #expect(throws: ProbeError.self) {
            try await select([[moved], [moved]], recovery: recovery, harness: harness,
                             actionDeadline: actionDeadline)
        }
        #expect(harness.queryCount == 2)
        #expect(harness.diagnostics.map(\.outcome) == ["geometryMismatch", "exhausted"])
        #expect(recovery.currentFrame == nil)
        let reason = actionExpiresFirst ? "actionExpired" : "recoveryExpired"
        #expect(harness.diagnostics.last?.detail.contains("recoveryStop=\(reason)") == true)
    }

    @Test("The first successful query also rejects an expired action")
    func initialQueryActionDeadline() async throws {
        let directory = try RuntimeTestDirectory()
        defer { directory.remove() }
        let recovery = context(directory)
        let harness = SelectionRecoveryHarness()
        let deadline = harness.time + 0.25
        harness.onQuery = { _ in harness.time += 1 }
        await #expect(throws: ProbeError.self) {
            try await select([[candidate()]], recovery: recovery, harness: harness,
                             actionDeadline: deadline)
        }
        #expect(harness.queryCount == 1)
        #expect(recovery.generation == 0)
    }

    @Test("Session expiry during recovery stops before a second query")
    func sessionDeadline() async throws {
        let directory = try RuntimeTestDirectory()
        defer { directory.remove() }
        let harness = SelectionRecoveryHarness()
        // The injected clock drives this test's expiry; wall-clock scheduling cannot expire
        // the real context before its first query has established a recovery budget.
        harness.time += 60
        let recovery = context(directory, sessionDeadline: harness.time + 0.25)
        await #expect(throws: AutomationCaptureInterruption.self) {
            try await select([[], [candidate()]], recovery: recovery, harness: harness)
        }
        #expect(harness.queryCount == 1)
        #expect(harness.diagnostics.last?.outcome == "exhausted")
    }

    @Test("A preexisting STOP or expired session prevents even the first query",
          arguments: [true, false])
    func initialInterruption(stoppedByFile: Bool) async throws {
        let directory = try RuntimeTestDirectory()
        defer { directory.remove() }
        let recovery = context(directory, sessionDeadline: stoppedByFile ? nil : 0)
        let harness = SelectionRecoveryHarness()
        if stoppedByFile { try Data().write(to: recovery.stopURL) }
        await #expect(throws: AutomationCaptureInterruption.self) {
            try await select([[candidate()]], recovery: recovery, harness: harness)
        }
        #expect(harness.queryCount == 0)
        #expect(harness.pauses.isEmpty)
        #expect(recovery.generation == 0)
    }

    @Test("A STOP file written during a wait interrupts within one short slice")
    func stopDuringWait() async throws {
        let directory = try RuntimeTestDirectory()
        defer { directory.remove() }
        let recovery = context(directory)
        let harness = SelectionRecoveryHarness()
        harness.onPause = { try Data().write(to: recovery.stopURL) }
        await #expect(throws: AutomationCaptureInterruption.self) {
            try await select([[], [candidate()]], recovery: recovery, harness: harness)
        }
        #expect(harness.queryCount == 1)
        #expect(harness.pauses.count == 1)
        #expect(harness.pauses[0] <= 0.1)
        #expect(harness.diagnostics.last?.outcome == "exhausted")
    }

    @Test("Query errors propagate immediately rather than becoming window availability retries",
          arguments: [1, 2])
    func queryErrors(failureQuery: Int) async throws {
        let directory = try RuntimeTestDirectory()
        defer { directory.remove() }
        let recovery = context(directory)
        let harness = SelectionRecoveryHarness()
        harness.onQuery = { query in
            if query == failureQuery { throw SelectionRecoveryQueryError.failed }
        }
        await #expect(throws: SelectionRecoveryQueryError.self) {
            try await select([[], [candidate()]], recovery: recovery, harness: harness)
        }
        #expect(harness.queryCount == failureQuery)
        #expect(recovery.generation == (failureQuery == 1 ? 0 : 1))
        #expect(harness.diagnostics.count == (failureQuery == 1 ? 0 : 1))
    }

    private func context(_ directory: RuntimeTestDirectory,
                         sessionDeadline: TimeInterval? = nil) -> AutomationWindowRecoveryContext {
        AutomationWindowRecoveryContext(stopURL: directory.url.appendingPathComponent("STOP"),
                                        sessionDeadline: sessionDeadline)
    }

    private func candidate(frame: CGRect? = nil,
                           identity: AutoLevelWindowIdentity? = nil,
                           isEligible: Bool = true)
        -> AutomationWindowSelectionCandidate<Int> {
        .init(window: 10, identity: identity ?? self.identity,
              frame: frame ?? self.frame, isEligible: isEligible)
    }

    private func select(_ samples: [[AutomationWindowSelectionCandidate<Int>]],
                        recovery: AutomationWindowRecoveryContext,
                        harness: SelectionRecoveryHarness,
                        actionDeadline: TimeInterval? = nil,
                        expectedFrame: CGRect? = nil) async throws -> Int {
        try await AutomationWindowSelectionRecovery.select(
            expectedIdentity: identity, expectedFrame: expectedFrame ?? frame, recovery: recovery,
            deadline: actionDeadline.map(AutomationCaptureDeadline.inputAuthorization),
            query: {
                harness.queryCount += 1
                try harness.onQuery?(harness.queryCount)
                harness.queryTimes.append(harness.time)
                return samples[min(harness.queryCount - 1, samples.count - 1)]
            },
            now: { harness.time },
            pause: { delay in
                harness.pauses.append(delay)
                harness.time += delay
                try harness.onPause?()
            },
            diagnostic: { outcome, _, budget, detail in
                harness.diagnostics.append(.init(outcome: outcome, startedAt: budget.startedAt,
                                                 attempt: budget.attempt, detail: detail))
            }
        )
    }
}

private enum SelectionRecoveryQueryError: Error { case failed }

private final class SelectionRecoveryHarness {
    struct Diagnostic {
        let outcome: String
        let startedAt: TimeInterval
        let attempt: Int
        let detail: String
    }

    var time = ProcessInfo.processInfo.systemUptime
    var queryCount = 0
    var queryTimes: [TimeInterval] = []
    var pauses: [TimeInterval] = []
    var diagnostics: [Diagnostic] = []
    var onQuery: ((Int) throws -> Void)?
    var onPause: (() throws -> Void)?
}
