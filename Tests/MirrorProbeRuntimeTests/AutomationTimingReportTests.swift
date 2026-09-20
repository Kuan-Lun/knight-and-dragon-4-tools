import Foundation
import Testing
@testable import MirrorProbeRuntime

@Suite("Auto-level cycle timing")
struct AutomationTimingReportTests {
    @Test("Completed-cycle averages exclude the unfinished tail; throughput includes it")
    func measuredCycles() {
        var timing = AutomationTimingReport()
        timing.recordCompletedCycle(count: 1, elapsed: 10.25)
        timing.recordCompletedCycle(count: 2, elapsed: 40.75)
        timing.recordCompletedCycle(count: 3, elapsed: 60)
        timing.updateElapsed(75)

        #expect(timing.elapsedSeconds == 75)
        #expect(timing.completedCycleCount == 3)
        #expect(timing.completedCycleTotalSeconds == 60)
        #expect(timing.averageCycleSeconds == 20)
        #expect(timing.medianCycleSeconds == 19.25)
        #expect(timing.fastestCycleSeconds == 10.25)
        #expect(timing.slowestCycleSeconds == 30.5)
        #expect(timing.lastCycleSeconds == 19.25)
        #expect(timing.secondsSinceLastCycle == 15)
        #expect(timing.cyclesPerHour == 144)
    }

    @Test("No completions have unavailable cycle timings, including at zero elapsed")
    func noCycles() throws {
        var timing = AutomationTimingReport()
        #expect(timing.cyclesPerHour == nil)
        timing.updateElapsed(12.5)
        #expect(timing.averageCycleSeconds == nil)
        #expect(timing.medianCycleSeconds == nil)
        #expect(timing.fastestCycleSeconds == nil)
        #expect(timing.slowestCycleSeconds == nil)
        #expect(timing.lastCycleSeconds == nil)
        #expect(timing.secondsSinceLastCycle == nil)
        #expect(timing.cyclesPerHour == 0)

        let data = try JSONEncoder().encode(timing)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["averageCycleSeconds", "medianCycleSeconds", "fastestCycleSeconds", "slowestCycleSeconds",
                    "lastCycleSeconds", "secondsSinceLastCycle"] {
            #expect(object[key] is NSNull)
        }
    }

    @Test("Reused observations neither double-count nor move elapsed time backwards")
    func reusedObservations() {
        var timing = AutomationTimingReport()
        timing.recordCompletedCycle(count: 1, elapsed: 12)
        timing.updateElapsed(18)
        timing.recordCompletedCycle(count: 1, elapsed: 19)
        timing.updateElapsed(12)
        #expect(timing.completedCycleCount == 1)
        #expect(timing.averageCycleSeconds == 12)
        #expect(timing.medianCycleSeconds == 12)
        #expect(timing.lastCycleSeconds == 12)
        #expect(timing.elapsedSeconds == 18)
        #expect(timing.secondsSinceLastCycle == 6)

        // A delayed recognition can prove a completion captured before the last log.
        timing.recordCompletedCycle(count: 2, elapsed: 16)
        #expect(timing.elapsedSeconds == 18)
        #expect(timing.averageCycleSeconds == 8)
        #expect(timing.medianCycleSeconds == 8)
        #expect(timing.lastCycleSeconds == 4)
        #expect(timing.secondsSinceLastCycle == 2)
    }

    @Test("Missing counts or invalid clocks cannot fabricate duration samples")
    func invalidSamples() {
        var timing = AutomationTimingReport()
        timing.recordCompletedCycle(count: 2, elapsed: 20)
        for elapsed in [Double.nan, .infinity, -.infinity, -1] {
            timing.updateElapsed(elapsed)
            timing.recordCompletedCycle(count: 1, elapsed: elapsed)
        }
        #expect(timing.completedCycleCount == 0)
        #expect(timing.elapsedSeconds == 0)
        timing.recordCompletedCycle(count: 1, elapsed: 10)
        timing.recordCompletedCycle(count: 2, elapsed: 9)
        #expect(timing.completedCycleCount == 1)
        #expect(timing.averageCycleSeconds == 10)
        #expect(timing.medianCycleSeconds == 10)
    }

    @Test("Median uses the middle sample or middle pair, including fractional and outlier durations")
    func medianSamples() {
        var timing = AutomationTimingReport()
        var elapsed: Double = 0
        let durations = [30.5, 10.25, 1_000, 20.75, 30.5]
        let medians = [30.5, 20.375, 30.5, 25.625, 30.5]
        for index in durations.indices {
            elapsed += durations[index]
            timing.recordCompletedCycle(count: index + 1, elapsed: elapsed)
            #expect(timing.medianCycleSeconds == medians[index])
        }
        timing.updateElapsed(elapsed + 500)
        #expect(timing.medianCycleSeconds == 30.5)
        #expect(timing.averageCycleSeconds == 218.4)
    }

    @Test("Serialized samples preserve the exact median when more cycles complete")
    func medianRoundTrip() throws {
        var timing = AutomationTimingReport()
        timing.recordCompletedCycle(count: 1, elapsed: 30)
        timing.recordCompletedCycle(count: 2, elapsed: 40)
        let data = try JSONEncoder().encode(timing)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["medianCycleSeconds"] as? Double == 20)
        #expect(object["cycleDurationsSeconds"] as? [Double] == [30, 10])
        var decoded = try JSONDecoder().decode(AutomationTimingReport.self, from: data)
        decoded.recordCompletedCycle(count: 3, elapsed: 1_040)
        #expect(decoded.medianCycleSeconds == 30)
    }

    @Test("Older timing summaries decode without inventing missing median samples")
    func legacyTiming() throws {
        var timing = AutomationTimingReport()
        timing.recordCompletedCycle(count: 1, elapsed: 30)
        let data = try JSONEncoder().encode(timing)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "medianCycleSeconds")
        object.removeValue(forKey: "cycleDurationsSeconds")
        var decoded = try JSONDecoder().decode(
            AutomationTimingReport.self, from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(decoded.medianCycleSeconds == nil)
        #expect(decoded.averageCycleSeconds == 30)
        decoded.recordCompletedCycle(count: 2, elapsed: 40)
        #expect(decoded.averageCycleSeconds == 20)
        #expect(decoded.medianCycleSeconds == nil)
    }

    @Test("Timing persists on completion, Quit, and runtime-error events",
          arguments: ["sessionEnded", "sessionError"])
    func eventPersistence(terminalKind: String) throws {
        let directory = try RuntimeTestDirectory()
        defer { directory.remove() }
        let output = directory.url.appendingPathComponent("run-report.json")
        var report = runtimeTestReport(directory: directory.url)
        report.completedCycles = 0
        report.timing = AutomationTimingReport()

        report.recordCompletedCycles(1, elapsed: 10)
        try append("cycleCompleted", elapsed: 10, report: &report, to: output)
        // Same production count hook serves delayed recognition and fresh frames.
        report.recordCompletedCycles(2, elapsed: 40)
        try append("staleObservation", elapsed: 43, report: &report, to: output)
        try append("observation", elapsed: 40, report: &report, to: output)
        report.status = terminalKind == "sessionError" ? "error" : "stopped"
        report.finalReason = terminalKind == "sessionError" ? "fixture error" : "applicationQuitRequested"
        try append(terminalKind, elapsed: 50, report: &report, to: output)

        let decoded = try JSONDecoder().decode(AutomationRunReport.self, from: Data(contentsOf: output))
        let timing = try #require(decoded.timing)
        #expect(decoded.completedCycles == timing.completedCycleCount)
        #expect(timing.elapsedSeconds == 50)
        #expect(timing.averageCycleSeconds == 20)
        #expect(timing.medianCycleSeconds == 20)
        #expect(timing.lastCycleSeconds == 30)
        #expect(timing.secondsSinceLastCycle == 10)
        #expect(timing.cyclesPerHour == 144)
        #expect(decoded.finalReason == report.finalReason)
    }

    @Test("Terminal persistence captures the current duration even with no new observation")
    func terminalDuration() throws {
        let directory = try RuntimeTestDirectory()
        defer { directory.remove() }
        let output = directory.url.appendingPathComponent("run-report.json")
        var report = runtimeTestReport(directory: directory.url)
        report.completedCycles = 0
        report.timing = AutomationTimingReport()
        let startedAt = ProcessInfo.processInfo.systemUptime - 50
        report.recordCompletedCycles(1, elapsed: 10)
        try MirrorProbeRuntime.finishAutomationRun(
            status: "stopped", reason: "applicationQuitRequested", terminationKind: .userStop,
            observation: nil, captureLevel: .error, captureRecorder: AutomationCaptureRecorder(),
            startedAt: startedAt, directoryURL: directory.url, reportURL: output, report: &report
        )
        let decoded = try JSONDecoder().decode(AutomationRunReport.self, from: Data(contentsOf: output))
        let timing = try #require(decoded.timing)
        #expect(timing.elapsedSeconds >= 50)
        #expect(timing.elapsedSeconds == decoded.events.last?.elapsedSeconds)
        #expect(timing.averageCycleSeconds == 10)
        #expect(timing.secondsSinceLastCycle == timing.elapsedSeconds - 10)
        #expect(decoded.endedAt != nil)
    }

    @Test("Older reports decode without inventing timing statistics")
    func legacyReport() throws {
        let report = runtimeTestReport(directory: URL(fileURLWithPath: "/tmp/legacy-run"))
        let decoded = try JSONDecoder().decode(AutomationRunReport.self, from: JSONEncoder().encode(report))
        #expect(decoded.timing == nil)
        #expect(decoded.completedCycles == 2)
    }

    private func append(
        _ kind: String, elapsed: Double, report: inout AutomationRunReport, to url: URL
    ) throws {
        try MirrorProbeRuntime.appendAutomationEvent(
            kind: kind, state: nil, decision: nil, action: nil, target: nil,
            frameFingerprint: nil, detail: nil, screenshotPath: nil,
            elapsed: elapsed, report: &report, reportURL: url
        )
    }
}
