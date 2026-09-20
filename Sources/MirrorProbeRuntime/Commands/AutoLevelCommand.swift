import Foundation
import MirrorProbeCore

extension MirrorProbeRuntime {
    static func autoLevelCommand(_ arguments: [String]) async throws {
        try validateOptions(
            arguments,
            valueOptions: [
                "--window-id", "--confirm", "--input-mode", "--max-cycles", "--max-minutes",
                "--capture-level", "--output-dir",
            ]
        )
        try ensureScreenCapturePermission()
        try ensurePostEventPermission()

        guard let confirmation = option("--confirm", in: arguments),
              [autoLevelConfirmation, legacyAutoLevelConfirmation].contains(confirmation)
        else {
            throw ProbeError.invalidArguments(
                "run requires --confirm \(autoLevelConfirmation), authorizing automation "
                    + "including recovery from a confirmed stalled battle. Talisman use is unrestricted."
            )
        }
        let requestedID = try optionalWindowID(arguments)
        let inputModeText = option("--input-mode", in: arguments) ?? AutoLevelInputMode.foreground.rawValue
        guard let inputMode = AutoLevelInputMode(rawValue: inputModeText) else {
            throw ProbeError.invalidArguments("--input-mode must be foreground or process")
        }
        let captureLevelText = option("--capture-level", in: arguments)
            ?? AutoLevelCaptureLevel.error.rawValue
        guard let captureLevel = AutoLevelCaptureLevel(rawValue: captureLevelText) else {
            throw ProbeError.invalidArguments("--capture-level must be error or info")
        }
        let maximumCycles = try option("--max-cycles", in: arguments).map { _ in
            try boundedIntegerOption("--max-cycles", in: arguments, defaultValue: 1, range: 1...Int.max)
        }
        let maximumMinutes = try option("--max-minutes", in: arguments).map { _ in
            try boundedDoubleOption(
                "--max-minutes", in: arguments, defaultValue: 1,
                range: Double.leastNonzeroMagnitude...(Double.greatestFiniteMagnitude / 60)
            )
        }
        let maximumRuntime = maximumMinutes.map { $0 * 60 }
        let maximumActions: Int? = nil
        let pollInterval = 1.5
        let sessionID = automationSessionID()
        guard let outputDirectoryPath = option("--output-dir", in: arguments),
              outputDirectoryPath.hasPrefix("/")
        else {
            throw ProbeError.invalidArguments(
                "run requires --output-dir with an absolute path for durable logs and the STOP file"
            )
        }
        let directoryURL = try outputURL(for: outputDirectoryPath, isDirectory: true)
        let reportURL = directoryURL.appendingPathComponent("run-report.json")
        let stopURL = directoryURL.appendingPathComponent("STOP")
        let existingOutputEntries = try FileManager.default.contentsOfDirectory(
            atPath: directoryURL.path
        )
        guard existingOutputEntries.isEmpty else {
            throw ProbeError.invalidArguments(
                "--output-dir must be empty so no prior report or capture can be overwritten"
            )
        }

        let startedDate = Date()
        let startedAt = ProcessInfo.processInfo.systemUptime
        let sessionDeadline = maximumRuntime.map { startedAt + $0 }
        guard sessionDeadline?.isFinite != false else {
            throw ProbeError.invalidArguments("--max-minutes exceeds the supported clock range")
        }
        let captureRecorder = AutomationCaptureRecorder()
        // This operation was explicitly started by the user. Keep background recognition
        // out of App Nap until all captures and final report writes finish, while respecting
        // the user's system-sleep settings. The token is released on every return/error path.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Complete the user-requested auto-level session and its safety observations"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }
        // A window dragged off a zoom level is moved to the nearest calibrated size first;
        // the session then locks that geometry.
        let initialWindow = try await snapMirrorWindowToCalibratedSize(
            selectMirrorWindow(requestedID: requestedID)
        )
        guard let initialApplication = initialWindow.owningApplication,
              initialApplication.processID > 0
        else {
            throw ProbeError.unsafeWindow("could not resolve the iPhone Mirroring process")
        }
        let identity = AutoLevelWindowIdentity(
            processID: initialApplication.processID,
            windowID: initialWindow.windowID
        )
        let windowRunLock = try AutoLevelWindowRunLock.acquire(for: identity)
        defer { windowRunLock.release() }
        let initialFrame = initialWindow.frame
        let windowRecovery = AutomationWindowRecoveryContext(
            stopURL: stopURL, sessionDeadline: sessionDeadline, initialFrame: initialFrame
        )
        let limits = AutomationLimitsReport(
            maximumCycles: maximumCycles,
            maximumMinutes: maximumMinutes,
            maximumActions: maximumActions,
            pollIntervalSeconds: pollInterval
        )
        var report = AutomationRunReport(
            schemaVersion: automationSchemaVersion,
            recognitionMode: "visualRegions",
            sessionID: sessionID,
            status: "running",
            startedAt: ISO8601DateFormatter().string(from: startedDate),
            endedAt: nil,
            window: windowReport(initialWindow),
            talismanPolicy: "unrestricted",
            inputMode: inputMode,
            captureLevel: captureLevel,
            limits: limits,
            outputDirectory: directoryURL.path,
            stopFile: stopURL.path,
            completedCycles: 0,
            actionsPosted: 0,
            finalReason: nil,
            diagnosticScreenshots: [],
            diagnosticPersistenceErrors: [],
            events: [],
            timing: AutomationTimingReport()
        )
        do {
            let initialObservation = try await captureAutomationObservation(
                requestedID: initialWindow.windowID,
                expectedIdentity: identity,
                expectedFrame: initialFrame,
                captureRecorder: captureRecorder,
                recovery: windowRecovery,
                phase: "initial"
            )
            let routineCapturePlan = AutoLevelCaptureRetentionPolicy(level: captureLevel)
                .plan(for: .expectedLimit)
            let initialPath: String?
            if routineCapturePlan.retainsInitial {
                let initialURL = directoryURL.appendingPathComponent("initial.png")
                try writePNG(initialObservation.image, to: initialURL)
                initialPath = initialURL.path
            } else {
                initialPath = nil
            }

            try appendAutomationEvent(
                kind: "sessionStarted",
                state: initialObservation.classification.state,
                decision: nil,
                action: nil,
                target: nil,
                frameFingerprint: initialObservation.fingerprint,
                detail: "User entered the stage manually; automation acquired and locked the mirror window; inputMode=\(inputMode.rawValue), captureLevel=\(captureLevel.rawValue), activity=userInitiatedAllowingIdleSystemSleep.",
                screenshotPath: initialPath,
                elapsed: initialObservation.capturedAt - startedAt,
                report: &report,
                reportURL: reportURL
            )

            try await performAutoLevelLoop(
                initialObservation: initialObservation,
                identity: identity,
                initialFrame: initialFrame,
                sessionID: sessionID,
                inputMode: inputMode,
                captureLevel: captureLevel,
                captureRecorder: captureRecorder,
                windowRecovery: windowRecovery,
                startedAt: startedAt,
                maximumCycles: maximumCycles,
                maximumMinutes: maximumMinutes,
                maximumActions: maximumActions,
                pollInterval: pollInterval,
                directoryURL: directoryURL,
                reportURL: reportURL,
                stopURL: stopURL,
                report: &report
            )
        } catch let interruption as AutomationCaptureInterruption {
            let stoppedByUser = interruption == .stopRequested
            try finishAutomationRun(
                status: "stopped",
                reason: try automationInterruptionReason(
                    stoppedByUser: stoppedByUser, maximumRuntime: maximumRuntime
                ),
                terminationKind: stoppedByUser ? .userStop : .expectedLimit,
                observation: nil,
                captureLevel: captureLevel,
                captureRecorder: captureRecorder,
                startedAt: startedAt,
                directoryURL: directoryURL,
                reportURL: reportURL,
                report: &report
            )
        } catch {
            let originalReason = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            let diagnosticResult = persistAutomationTerminationScreenshots(
                captureLevel: captureLevel,
                terminationKind: .runtimeError,
                observation: nil,
                captureRecorder: captureRecorder,
                startedAt: startedAt,
                directoryURL: directoryURL
            )
            report.diagnosticScreenshots.append(contentsOf: diagnosticResult.screenshots)
            report.diagnosticPersistenceErrors.append(contentsOf: diagnosticResult.errors)
            let latestCapture = captureRecorder.capturesOldestFirst.last
            report.status = "error"
            report.endedAt = ISO8601DateFormatter().string(from: Date())
            report.finalReason = originalReason
            try? appendAutomationEvent(
                kind: "sessionError",
                state: latestCapture?.state,
                decision: nil,
                action: nil,
                target: nil,
                frameFingerprint: latestCapture?.fingerprint,
                detail: diagnosticResult.errors.isEmpty
                    ? originalReason
                    : "\(originalReason); diagnosticPersistenceErrors="
                        + diagnosticResult.errors.joined(separator: " | "),
                screenshotPath: diagnosticResult.finalPath,
                elapsed: ProcessInfo.processInfo.systemUptime - startedAt,
                report: &report,
                reportURL: reportURL
            )
            try? writeJSON(report, to: reportURL)
            throw error
        }

        try writeJSON(report, to: reportURL)
        try printJSON(report)
    }
}
