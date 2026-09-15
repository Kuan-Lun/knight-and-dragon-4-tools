import Foundation
import Testing
@testable import MirrorProbeRuntime

@Suite("Production runtime persistence integration")
struct RuntimePersistenceIntegrationTests {
    @Test("Events reach the real JSON report with sequence and unlimited-limit fields intact")
    func eventPersistence() throws {
        let directory = try RuntimeTestDirectory()
        defer { directory.remove() }
        let output = directory.url.appendingPathComponent("reports/run-report.json")
        var report = runtimeTestReport(directory: directory.url)

        for kind in ["sessionStarted", "cycleCompleted"] {
            try MirrorProbeRuntime.appendAutomationEvent(
                kind: kind, state: .battle, decision: nil, action: nil, target: nil,
                frameFingerprint: "fixture", detail: "persisted", screenshotPath: nil,
                elapsed: 2, report: &report, reportURL: output
            )
        }

        let data = try Data(contentsOf: output)
        let decoded = try JSONDecoder().decode(AutomationRunReport.self, from: data)
        #expect(decoded.events.map(\.sequence) == [1, 2])
        #expect(decoded.events.map(\.kind) == ["sessionStarted", "cycleCompleted"])
        #expect(decoded.completedCycles == 2)
        #expect(decoded.actionsPosted == 4)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let limits = try #require(object["limits"] as? [String: Any])
        #expect(limits["maximumCycles"] is NSNull)
        #expect(limits["maximumMinutes"] is NSNull)
        #expect(limits["maximumActions"] is NSNull)
    }

    @Test("Encoding failure leaves the previous atomic report unchanged")
    func encodingFailurePreservesReport() throws {
        let directory = try RuntimeTestDirectory()
        defer { directory.remove() }
        let output = directory.url.appendingPathComponent("run-report.json")
        let report = runtimeTestReport(directory: directory.url)
        try MirrorProbeRuntime.writeJSON(report, to: output)
        let original = try Data(contentsOf: output)

        #expect(throws: (any Error).self) {
            try MirrorProbeRuntime.writeJSON(["invalidClock": Double.nan], to: output)
        }
        #expect(try Data(contentsOf: output) == original)
    }

    @Test("Report destination failures propagate instead of reporting successful persistence")
    func writeFailure() throws {
        let directory = try RuntimeTestDirectory()
        defer { directory.remove() }
        let blocker = directory.url.appendingPathComponent("not-a-directory")
        try Data("existing file".utf8).write(to: blocker)
        var report = runtimeTestReport(directory: directory.url)

        #expect(throws: (any Error).self) {
            try MirrorProbeRuntime.appendAutomationEvent(
                kind: "sessionStarted", state: nil, decision: nil, action: nil, target: nil,
                frameFingerprint: nil, detail: nil, screenshotPath: nil,
                elapsed: 0, report: &report,
                reportURL: blocker.appendingPathComponent("report.json")
            )
        }
        #expect(try String(contentsOf: blocker, encoding: .utf8) == "existing file")
    }

    @Test("A normal termination writes the terminal report without retaining screenshots")
    func expectedTermination() throws {
        let directory = try RuntimeTestDirectory()
        defer { directory.remove() }
        let output = directory.url.appendingPathComponent("run-report.json")
        var report = runtimeTestReport(directory: directory.url)
        let recorder = AutomationCaptureRecorder()
        recorder.record(image: try runtimeTestImage(), capturedAt: 1, state: .battle, fingerprint: "frame")

        try MirrorProbeRuntime.finishAutomationRun(
            status: "completed", reason: "maximumCyclesReached", terminationKind: .expectedLimit,
            observation: nil, captureLevel: .error, captureRecorder: recorder,
            startedAt: 0, directoryURL: directory.url, reportURL: output, report: &report
        )

        let terminal = try JSONDecoder().decode(AutomationRunReport.self, from: Data(contentsOf: output))
        #expect(terminal.status == "completed")
        #expect(terminal.endedAt != nil)
        #expect(terminal.finalReason == "maximumCyclesReached")
        #expect(terminal.events.last?.kind == "sessionEnded")
        #expect(terminal.diagnosticScreenshots.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path) == ["run-report.json"])
    }

    @Test("Runtime-error persistence writes only the latest eight real PNG captures")
    func boundedDiagnosticPersistence() throws {
        let directory = try RuntimeTestDirectory()
        defer { directory.remove() }
        let recorder = AutomationCaptureRecorder()
        let image = try runtimeTestImage()
        for sequence in 1...10 {
            recorder.record(
                image: image, capturedAt: Double(sequence), state: .battle,
                fingerprint: "frame-\(sequence)"
            )
        }

        let result = MirrorProbeRuntime.persistAutomationTerminationScreenshots(
            captureLevel: .error, terminationKind: .runtimeError, observation: nil,
            captureRecorder: recorder, startedAt: 0, directoryURL: directory.url
        )

        #expect(result.errors.isEmpty)
        #expect(result.screenshots.map(\.captureSequence) == Array(UInt64(3)...10))
        #expect(result.screenshots.map(\.frameFingerprint) == (3...10).map { "frame-\($0)" })
        #expect(result.screenshots.filter { $0.role == .final }.count == 1)
        #expect(result.finalPath == directory.url.appendingPathComponent("final.png").path)
        for screenshot in result.screenshots {
            let decoded = try MirrorProbeRuntime.loadPNG(at: URL(fileURLWithPath: screenshot.path))
            #expect(decoded.image.width == image.width)
            #expect(decoded.image.height == image.height)
        }
    }

    @Test("Diagnostic screenshot failure preserves the original terminal reason in a writable report")
    func diagnosticFailureKeepsReason() throws {
        let directory = try RuntimeTestDirectory()
        defer { directory.remove() }
        let blocker = directory.url.appendingPathComponent("not-a-directory")
        try Data("blocker".utf8).write(to: blocker)
        let output = directory.url.appendingPathComponent("run-report.json")
        let recorder = AutomationCaptureRecorder()
        recorder.record(image: try runtimeTestImage(), capturedAt: 1, state: .battle, fingerprint: "frame")
        var report = runtimeTestReport(directory: directory.url)

        try MirrorProbeRuntime.finishAutomationRun(
            status: "stopped", reason: "original safety reason", terminationKind: .safetyStop,
            observation: nil, captureLevel: .error, captureRecorder: recorder,
            startedAt: 0, directoryURL: blocker, reportURL: output, report: &report
        )

        let terminal = try JSONDecoder().decode(AutomationRunReport.self, from: Data(contentsOf: output))
        #expect(terminal.finalReason == "original safety reason")
        #expect(terminal.status == "stopped")
        #expect(terminal.diagnosticScreenshots.isEmpty)
        #expect(terminal.diagnosticPersistenceErrors.count == 1)
        #expect(terminal.events.last?.detail?.contains("original safety reason") == true)
        #expect(terminal.events.last?.detail?.contains("diagnosticPersistenceErrors=") == true)
    }

    @Test("STOP and configured deadlines are enforced at the production capture boundary")
    func captureBoundary() throws {
        let directory = try RuntimeTestDirectory()
        defer { directory.remove() }
        let stopURL = directory.url.appendingPathComponent("STOP")
        let unlimited = AutomationWindowRecoveryContext(stopURL: stopURL, sessionDeadline: nil)
        try unlimited.checkSessionBoundary()
        unlimited.interruptContinuity()
        #expect(unlimited.generation == 1)

        let expired = AutomationWindowRecoveryContext(stopURL: stopURL, sessionDeadline: 0)
        #expect(throws: AutomationCaptureInterruption.sessionExpired) { try expired.checkSessionBoundary() }
        try Data().write(to: stopURL)
        #expect(throws: AutomationCaptureInterruption.stopRequested) { try unlimited.checkSessionBoundary() }
        #expect(throws: AutomationCaptureInterruption.stopRequested) { try expired.checkSessionBoundary() }
    }
}
