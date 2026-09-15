import Foundation
import MirrorProbeCore

extension MirrorProbeRuntime {
    static func automationInterruptionReason(
        stoppedByUser: Bool, maximumRuntime: TimeInterval?
    ) throws -> String {
        if stoppedByUser { return applicationStopRequest.reportReason }
        guard let maximumRuntime else {
            throw ProbeError.unsafeWindow("session expiry was reported without a configured time limit")
        }
        return String(describing: AutoLevelStopReason.maximumRuntimeReached(limit: maximumRuntime))
    }

    static func appendAutomationEvent(
        kind: String,
        state: GameState?,
        decision: String?,
        action: AutoLevelActionIntent?,
        target: AutoLevelActionTarget?,
        frameFingerprint: String?,
        detail: String?,
        screenshotPath: String?,
        elapsed: TimeInterval,
        report: inout AutomationRunReport,
        reportURL: URL
    ) throws {
        report.events.append(AutomationRunEvent(
            sequence: report.events.count + 1,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            elapsedSeconds: max(0, elapsed),
            kind: kind,
            state: state,
            decision: decision,
            action: action,
            target: target,
            frameFingerprint: frameFingerprint,
            detail: detail,
            screenshotPath: screenshotPath
        ))
        try writeJSON(report, to: reportURL)
    }

    static func finishAutomationRun(
        status: String,
        reason: String,
        terminationKind: AutoLevelCaptureTerminationKind,
        observation: AutomationObservation?,
        captureLevel: AutoLevelCaptureLevel,
        captureRecorder: AutomationCaptureRecorder,
        startedAt: TimeInterval,
        directoryURL: URL,
        reportURL: URL,
        report: inout AutomationRunReport
    ) throws {
        let diagnosticResult = persistAutomationTerminationScreenshots(
            captureLevel: captureLevel,
            terminationKind: terminationKind,
            observation: observation,
            captureRecorder: captureRecorder,
            startedAt: startedAt,
            directoryURL: directoryURL
        )
        report.diagnosticScreenshots.append(contentsOf: diagnosticResult.screenshots)
        report.diagnosticPersistenceErrors.append(contentsOf: diagnosticResult.errors)
        report.status = status
        report.endedAt = ISO8601DateFormatter().string(from: Date())
        report.finalReason = reason
        try appendAutomationEvent(
            kind: "sessionEnded",
            state: observation?.classification.state,
            decision: nil,
            action: nil,
            target: nil,
            frameFingerprint: observation?.fingerprint,
            detail: diagnosticResult.errors.isEmpty
                ? reason
                : "\(reason); diagnosticPersistenceErrors="
                    + diagnosticResult.errors.joined(separator: " | "),
            screenshotPath: diagnosticResult.finalPath,
            elapsed: ProcessInfo.processInfo.systemUptime - startedAt,
            report: &report,
            reportURL: reportURL
        )
    }

    static func captureTerminationKind(
        for reason: AutoLevelStopReason
    ) -> AutoLevelCaptureTerminationKind {
        switch reason {
        case .maximumCyclesReached, .maximumRuntimeReached:
            return .expectedLimit
        default:
            return .safetyStop
        }
    }

    /// Writes screenshots only after the termination category is known. Every write is
    /// best-effort so a full disk or encoding failure cannot replace the original stop reason.
    static func persistAutomationTerminationScreenshots(
        captureLevel: AutoLevelCaptureLevel,
        terminationKind: AutoLevelCaptureTerminationKind,
        observation: AutomationObservation?,
        captureRecorder: AutomationCaptureRecorder,
        startedAt: TimeInterval,
        directoryURL: URL
    ) -> AutomationDiagnosticPersistenceResult {
        let plan = AutoLevelCaptureRetentionPolicy(level: captureLevel)
            .plan(for: terminationKind)
        guard plan.retainsRecent || plan.retainsFinal else {
            return AutomationDiagnosticPersistenceResult(
                finalPath: nil,
                screenshots: [],
                errors: []
            )
        }

        var captures = captureRecorder.capturesOldestFirst
        if captures.isEmpty, let observation {
            // Successful automation captures are normally recorded immediately. This fallback
            // keeps a final frame if a future caller supplies an independently built observation.
            captures = [BufferedAutomationCapture(
                sequence: 0,
                capturedAt: observation.capturedAt,
                state: observation.classification.state,
                fingerprint: observation.fingerprint,
                image: observation.image
            )]
        }

        var screenshots: [AutomationDiagnosticScreenshotReport] = []
        var errors: [String] = []
        var finalPath: String?

        func persist(
            _ capture: BufferedAutomationCapture,
            to url: URL,
            role: AutomationDiagnosticScreenshotRole
        ) {
            do {
                try writePNG(capture.image, to: url)
                screenshots.append(AutomationDiagnosticScreenshotReport(
                    captureSequence: capture.sequence,
                    capturedAtElapsedSeconds: max(0, capture.capturedAt - startedAt),
                    state: capture.state,
                    frameFingerprint: capture.fingerprint,
                    path: url.path,
                    role: role
                ))
                if role == .final {
                    finalPath = url.path
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                errors.append("\(url.path): \(message)")
            }
        }

        if plan.retainsRecent, !captures.isEmpty {
            // The newest retained sample becomes final.png instead of being duplicated. Thus an
            // error-level run writes at most eight PNG files in total.
            for capture in captures.dropLast() {
                let filename = String(format: "capture-%04llu.png", capture.sequence)
                let url = directoryURL
                    .appendingPathComponent("diagnostics", isDirectory: true)
                    .appendingPathComponent(filename)
                persist(capture, to: url, role: .recent)
            }
            if plan.retainsFinal, let newest = captures.last {
                persist(
                    newest,
                    to: directoryURL.appendingPathComponent("final.png"),
                    role: .final
                )
            }
        } else if plan.retainsFinal, let newest = captures.last {
            persist(
                newest,
                to: directoryURL.appendingPathComponent("final.png"),
                role: .final
            )
        }

        return AutomationDiagnosticPersistenceResult(
            finalPath: finalPath,
            screenshots: screenshots,
            errors: errors
        )
    }
}
