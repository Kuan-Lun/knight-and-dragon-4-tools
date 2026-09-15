import AppKit
import CoreGraphics
import Foundation
import MirrorProbeCore

extension MirrorProbeRuntime {
    static func characterRerollCommand(_ arguments: [String]) async throws {
        try validateOptions(
            arguments,
            valueOptions: [
                "--window-id", "--confirm", "--minimum-total", "--max-rerolls",
                "--max-minutes", "--stop-file", "--report",
            ]
        )
        try ensureScreenCapturePermission()
        try ensurePostEventPermission()

        guard option("--confirm", in: arguments) == characterRerollConfirmation else {
            throw ProbeError.invalidArguments(
                "reroll-character requires --confirm \(characterRerollConfirmation); only the "
                    + "verified top-right Random control may be pressed"
            )
        }
        let requestedID = try optionalWindowID(arguments)
        let minimumTotal = try boundedIntegerOption(
            "--minimum-total",
            in: arguments,
            defaultValue: 90,
            range: CharacterRerollDetector.supportedMinimumTotalRange
        )
        let maximumRerolls = try boundedIntegerOption(
            "--max-rerolls",
            in: arguments,
            defaultValue: 500,
            range: 1...5_000
        )
        let maximumMinutes = try boundedDoubleOption(
            "--max-minutes",
            in: arguments,
            defaultValue: 10,
            range: 0.1...60
        )
        let reportURL = try option("--report", in: arguments).map {
            try outputURL(for: $0)
        }
        let stopURL = option("--stop-file", in: arguments).map(inputFileURL)
        let limits = CharacterRerollLimitsReport(
            minimumTotal: minimumTotal,
            maximumRerolls: maximumRerolls,
            maximumMinutes: maximumMinutes
        )

        let startedDate = Date()
        let startedAt = ProcessInfo.processInfo.systemUptime
        let sessionDeadline = startedAt + maximumMinutes * 60
        guard sessionDeadline.isFinite else {
            throw ProbeError.invalidArguments("--max-minutes produced an invalid deadline")
        }

        let initialWindow = try await selectMirrorWindow(requestedID: requestedID)
        guard let application = initialWindow.owningApplication,
              application.processID > 0,
              let runningApplication = NSRunningApplication(
                  processIdentifier: application.processID
              )
        else {
            throw ProbeError.unsafeWindow("could not resolve the iPhone Mirroring process")
        }
        let identity = AutoLevelWindowIdentity(
            processID: application.processID,
            windowID: initialWindow.windowID
        )
        let initialFrame = initialWindow.frame
        let windowRunLock = try AutoLevelWindowRunLock.acquire(for: identity)
        defer { windowRunLock.release() }

        let initialStability = await stableCharacterRerollObservation(
            requestedID: identity.windowID,
            expectedIdentity: identity,
            expectedFrame: initialFrame,
            minimumTotal: minimumTotal,
            sessionDeadline: sessionDeadline,
            stabilityTimeout: 5,
            stopURL: stopURL
        )
        let initialObservation: CharacterRerollObservation
        switch initialStability {
        case let .stable(observation):
            initialObservation = observation
        case let .ended(latest, keeperOrConflictWasObserved, endReason):
            let status: String
            let reportReason: String
            let terminalMessage: String?
            switch endReason {
            case .stopRequested:
                status = "stopped"
                reportReason = applicationStopRequest.reportReason
                terminalMessage = nil
            case .maximumRuntimeReached:
                status = "limitReached"
                reportReason = "maximumRuntimeReached"
                terminalMessage = "the character reroll runtime limit was reached during initial "
                    + "stability checks"
            case let .failed(message):
                status = "error"
                reportReason = message
                terminalMessage = message
            }
            try emitCharacterRerollReport(
                status: status,
                reason: reportReason,
                startedDate: startedDate,
                window: latest?.window ?? initialWindow,
                limits: limits,
                initialTotal: latest.flatMap(characterRerollUnambiguousTotal),
                finalTotal: latest.flatMap(characterRerollUnambiguousTotal),
                rerollsPosted: 0,
                reportURL: reportURL,
                candidateObservation: latest,
                candidateRole: latest == nil ? nil : .latestPreClickUnverified,
                keeperOrConflictWasObserved: keeperOrConflictWasObserved
            )
            if let terminalMessage {
                throw CharacterRerollTerminalError(message: terminalMessage)
            }
            return
        }
        guard let initialTotal = characterRerollTotal(initialObservation.decision) else {
            throw ProbeError.unsafeWindow("the initial character total was unavailable")
        }

        var current = initialObservation
        var rerollsPosted = 0
        var terminalReportWasEmitted = false
        var candidateRole = CharacterRerollCandidateRole.lastVerifiedStable
        var keeperOrConflictWasObserved = false
        // Re-entering either authorization loop must not renew this unposted retry budget.
        // Only a posted click starts a new budget.
        var pixelGuardRecovery = CharacterRerollPixelGuardRecovery()

        try emitCharacterRerollReport(
            status: "running",
            reason: "sessionStarted",
            startedDate: startedDate,
            window: current.window,
            limits: limits,
            initialTotal: initialTotal,
            finalTotal: initialTotal,
            rerollsPosted: rerollsPosted,
            reportURL: reportURL,
            printToStandardOutput: false
        )

        do {
            characterLoop: while true {
            if characterRerollStopRequested(stopURL) {
                try emitCharacterRerollReport(
                    status: "stopped",
                    reason: applicationStopRequest.reportReason,
                    startedDate: startedDate,
                    window: current.window,
                    limits: limits,
                    initialTotal: initialTotal,
                    finalTotal: characterRerollUnambiguousTotal(current),
                    rerollsPosted: rerollsPosted,
                    reportURL: reportURL,
                    candidateObservation: current,
                    candidateRole: candidateRole,
                    keeperOrConflictWasObserved: keeperOrConflictWasObserved
                )
                terminalReportWasEmitted = true
                return
            }

            let now = ProcessInfo.processInfo.systemUptime
            guard now < sessionDeadline else {
                try emitCharacterRerollReport(
                    status: "limitReached",
                    reason: "maximumRuntimeReached",
                    startedDate: startedDate,
                    window: current.window,
                    limits: limits,
                    initialTotal: initialTotal,
                    finalTotal: characterRerollUnambiguousTotal(current),
                    rerollsPosted: rerollsPosted,
                    reportURL: reportURL,
                    candidateObservation: current,
                    candidateRole: candidateRole,
                    keeperOrConflictWasObserved: keeperOrConflictWasObserved
                )
                terminalReportWasEmitted = true
                throw ProbeError.unsafeWindow(
                    "the character reroll runtime limit was reached before total "
                        + "\(minimumTotal)"
                )
            }

            switch current.decision {
            case .thresholdReached:
                try emitCharacterRerollReport(
                    status: "completed",
                    reason: "minimumTotalReached",
                    startedDate: startedDate,
                    window: current.window,
                    limits: limits,
                    initialTotal: initialTotal,
                    finalTotal: characterRerollUnambiguousTotal(current),
                    rerollsPosted: rerollsPosted,
                    reportURL: reportURL,
                    candidateObservation: current
                )
                terminalReportWasEmitted = true
                return

            case let .unsafe(reason):
                throw ProbeError.unsafeWindow(
                    "the custom-character snapshot became unsafe (\(reason.rawValue))"
                )

            case .rerollRequired:
                break
            }

            guard rerollsPosted < maximumRerolls else {
                try emitCharacterRerollReport(
                    status: "limitReached",
                    reason: "maximumRerollsReached",
                    startedDate: startedDate,
                    window: current.window,
                    limits: limits,
                    initialTotal: initialTotal,
                    finalTotal: characterRerollUnambiguousTotal(current),
                    rerollsPosted: rerollsPosted,
                    reportURL: reportURL,
                    candidateObservation: current
                )
                terminalReportWasEmitted = true
                throw ProbeError.unsafeWindow(
                    "the maximum of \(maximumRerolls) rerolls was reached before total "
                        + "\(minimumTotal)"
                )
            }

            let authorizedObservation = current
            var activationRetry = AutoLevelForegroundActivationRetryState()

            activationLoop: while true {
                guard let foregroundProcessID = ForegroundApplicationFocus.currentApplication?
                    .processIdentifier,
                    foregroundProcessID > 0
                else {
                    throw ProbeError.unsafeWindow("the current focused application is unavailable")
                }
                // Reroll sessions keep Mirroring in front between clicks and when the run ends.
                // With focus maintained, later rounds skip activation and its settling delay.
                let alreadyFrontmost = foregroundProcessID == identity.processID
                let activateReturned: Bool? = alreadyFrontmost
                    ? nil
                    : ForegroundApplicationActivation.request(
                        runningApplication, options: [.activateAllWindows],
                        expectedCurrentProcessID: foregroundProcessID
                    ).accepted
                if !alreadyFrontmost {
                    try await Task.sleep(
                        for: .milliseconds(activationRetry.settleDelayMilliseconds)
                    )
                }

                if characterRerollStopRequested(stopURL) {
                    continue characterLoop
                }

                let preflightStability = await stableCharacterRerollObservation(
                    requestedID: identity.windowID,
                    expectedIdentity: identity,
                    expectedFrame: initialFrame,
                    minimumTotal: minimumTotal,
                    sessionDeadline: sessionDeadline,
                    stabilityTimeout: 3,
                    stopURL: stopURL
                )
                let preflight: CharacterRerollObservation
                switch preflightStability {
                case let .stable(observation):
                    preflight = observation
                case let .ended(latest, boundaryWasObserved, endReason):
                    keeperOrConflictWasObserved = boundaryWasObserved
                    if let latest {
                        current = latest
                        candidateRole = .latestPreClickUnverified
                    }
                    switch endReason {
                    case .stopRequested:
                        throw CharacterRerollInterruption.stopRequested
                    case .maximumRuntimeReached:
                        throw CharacterRerollInterruption.maximumRuntimeReached
                    case let .failed(message):
                        throw CharacterRerollTerminalError(message: message)
                    }
                }
                // Keeper or ambiguous boundary evidence must leave the entire activation retry
                // loop immediately. Otherwise a transient focus failure could discard this frame
                // and let a later low OCR sample revive the old authorization.
                guard preflight.boundaryEvidence == .belowThreshold,
                      case .rerollRequired = preflight.decision
                else {
                    current = preflight
                    continue characterLoop
                }
                current = preflight
                candidateRole = .lastVerifiedStable
                let focusReady = AutoLevelForegroundActivationRetryState.activationIsReady(
                    activateReturned: activateReturned ?? false,
                    targetApplicationIsActive: runningApplication.isActive,
                    frontmostProcessMatches: ForegroundApplicationFocus.currentApplication?
                        .processIdentifier == identity.processID
                )
                guard focusReady else {
                    switch activationRetry.recordUnpostedFocusFailure() {
                    case let .retry(_, delayMilliseconds):
                        try await Task.sleep(for: .milliseconds(delayMilliseconds))
                        continue activationLoop
                    case let .exhausted(attempts):
                        throw ProbeError.unsafeWindow(
                            "iPhone Mirroring could not be kept frontmost after \(attempts) attempts"
                        )
                    }
                }

                guard characterRerollRoll(preflight.decision)
                    == characterRerollRoll(authorizedObservation.decision),
                    try characterRerollFramesAreQuiescent(
                        authorizedObservation.rgba,
                        preflight.rgba
                    )
                else {
                    // The user or game changed the generated result after authorization. The
                    // fresh stable snapshot becomes the next observation; no stale click is sent.
                    current = preflight
                    continue characterLoop
                }
                guard case let .rerollRequired(_, authorizedTarget) =
                    authorizedObservation.decision,
                    case let .rerollRequired(_, confirmedTarget) = preflight.decision,
                    characterRerollTargetsMatch(authorizedTarget, confirmedTarget)
                else {
                    current = preflight
                    continue characterLoop
                }

                // Take one last content snapshot after activation and immediately before the
                // synchronous input boundary. It must still be the exact same low roll and target;
                // any keeper, ambiguity, or unrelated page change cancels the stale authorization.
                let finalObservation = try await captureCharacterRerollObservation(
                    requestedID: identity.windowID,
                    expectedIdentity: identity,
                    expectedFrame: initialFrame,
                    minimumTotal: minimumTotal
                )
                guard characterRerollStableDecisionsMatch(
                    preflight.decision,
                    finalObservation.decision
                ),
                    finalObservation.boundaryEvidence == .belowThreshold,
                    try characterRerollFramesAreQuiescent(
                        preflight.rgba,
                        finalObservation.rgba
                    ),
                    case let .rerollRequired(_, finalTarget) = finalObservation.decision,
                    characterRerollTargetsMatch(confirmedTarget, finalTarget)
                else {
                    current = finalObservation
                    candidateRole = .latestPreClickUnverified
                    throw CharacterRerollTerminalError(
                        message: "the final pre-click content changed or became ambiguous; no "
                            + "input was posted"
                    )
                }
                current = finalObservation
                candidateRole = .lastVerifiedStable

                // ScreenCaptureKit has no supported synchronous one-shot capture on macOS 15.
                // Use a final pixel-only guard and bind the event deadline to the start of that
                // capture, limiting the remaining non-atomic compositor-to-event window to 0.5 s.
                let pixelGuardStartedAt = ProcessInfo.processInfo.systemUptime
                let pixelGuardImage = try await capture(window: finalObservation.window)
                let pixelGuardFrame = try rgbaFrame(from: pixelGuardImage)
                let pixelDifferences = try characterRerollInputSurfaceDifferences(
                    finalObservation.rgba,
                    pixelGuardFrame
                )
                if !pixelDifferences.inputSurfaceIsQuiescent {
                    current = CharacterRerollObservation(
                        capturedAt: pixelGuardStartedAt,
                        window: finalObservation.window,
                        decision: .unsafe(reason: .invalidObservation),
                        boundaryEvidence: .unavailable,
                        credibleFullFrameTotals: [],
                        credibleFocusedTotals: [],
                        fullFrameWasContaminated: false,
                        focusedWasContaminated: false,
                        fullFrameTotal: nil,
                        focusedTotal: nil,
                        renderedDigitCount: nil,
                        image: pixelGuardImage,
                        rgba: pixelGuardFrame
                    )
                    candidateRole = .latestPreClickUnverified
                    try writeCharacterRerollPixelGuardDiagnostic(
                        before: finalObservation,
                        rejectedImage: pixelGuardImage,
                        differences: pixelDifferences,
                        rerollsPosted: rerollsPosted,
                        reportURL: reportURL
                    )
                    // Parse these exact rejected pixels before considering any new capture.
                    // A keeper, conflict, unknown total, changed roll, or replaced target must
                    // terminate here; a later low frame cannot erase that evidence.
                    current = try analyzeCharacterRerollObservation(
                        image: pixelGuardImage,
                        rgba: pixelGuardFrame,
                        window: finalObservation.window,
                        capturedAt: pixelGuardStartedAt,
                        minimumTotal: minimumTotal
                    )
                    keeperOrConflictWasObserved = keeperOrConflictWasObserved
                        || current.boundaryEvidence == .thresholdReached
                        || current.boundaryEvidence == .boundaryConflict
                    if characterRerollStopRequested(stopURL) {
                        throw CharacterRerollInterruption.stopRequested
                    }
                    if ProcessInfo.processInfo.systemUptime >= sessionDeadline {
                        throw CharacterRerollInterruption.maximumRuntimeReached
                    }
                    switch pixelGuardRecovery.evaluate(
                        authorized: finalObservation.decision,
                        observed: current.decision,
                        boundaryEvidence: current.boundaryEvidence,
                        differences: pixelDifferences
                    ) {
                    case let .retry(attempt):
                        FileHandle.standardError.write(Data(
                            "characterPixelGuard: revalidating unchanged low roll, attempt=\(attempt)\n"
                                .utf8
                        ))
                        try await Task.sleep(for: .milliseconds(250))
                        // This never reaches the old click. Fresh stabilization, OCR, target,
                        // focus, pixels, and a new capture deadline are all required again.
                        continue characterLoop
                    case .exhausted:
                        throw CharacterRerollTerminalError(
                            message: "the final input surface kept changing after 3 revalidations; "
                                + "no input was posted (difference=\(pixelDifferences.inputSurface))"
                        )
                    case .unsafe:
                        throw CharacterRerollTerminalError(
                            message: "the final input surface changed and the rejected frame was "
                                + "not the same verified low roll and Random target; no input was "
                                + "posted (difference=\(pixelDifferences.inputSurface))"
                        )
                    }
                }

                let clickResult = try postCharacterRerollClick(
                    target: finalTarget,
                    observation: finalObservation,
                    identity: identity,
                    expectedFrame: initialFrame,
                    actionDeadline: pixelGuardStartedAt + 0.5,
                    sessionDeadline: sessionDeadline,
                    stopURL: stopURL
                )
                switch clickResult {
                case .posted:
                    let postedAt = ProcessInfo.processInfo.systemUptime
                    rerollsPosted += 1
                    pixelGuardRecovery = CharacterRerollPixelGuardRecovery()
                    candidateRole = .preClickFallback
                    try emitCharacterRerollReport(
                        status: "running",
                        reason: "awaitingRerollAcknowledgement",
                        startedDate: startedDate,
                        window: finalObservation.window,
                        limits: limits,
                        initialTotal: initialTotal,
                        finalTotal: characterRerollTotal(finalObservation.decision),
                        rerollsPosted: rerollsPosted,
                        reportURL: reportURL,
                        printToStandardOutput: false
                    )
                    let acknowledgement = await awaitCharacterRerollAcknowledgement(
                        previousObservation: finalObservation,
                        postedAt: postedAt,
                        requestedID: identity.windowID,
                        expectedIdentity: identity,
                        expectedFrame: initialFrame,
                        minimumTotal: minimumTotal,
                        sessionDeadline: sessionDeadline,
                        acknowledgementTimeout: 10,
                        stopURL: stopURL
                    )
                    switch acknowledgement {
                    case let .acknowledged(observation):
                        current = observation
                        candidateRole = .lastVerifiedStable
                        continue characterLoop
                    case let .ended(latestPostClick, boundaryWasObserved, reason):
                        keeperOrConflictWasObserved = boundaryWasObserved
                        if let latestPostClick {
                            current = latestPostClick
                            candidateRole = .latestPostClickUnverified
                        } else {
                            current = finalObservation
                            candidateRole = .preClickFallback
                        }
                        switch reason {
                        case .stopRequested:
                            throw CharacterRerollInterruption.stopRequested
                        case .maximumRuntimeReached:
                            throw CharacterRerollInterruption.maximumRuntimeReached
                        case let .failed(message):
                            throw CharacterRerollTerminalError(message: message)
                        }
                    }

                case .focusContended:
                    switch activationRetry.recordUnpostedFocusFailure() {
                    case let .retry(_, delayMilliseconds):
                        try await Task.sleep(for: .milliseconds(delayMilliseconds))
                        continue activationLoop
                    case let .exhausted(attempts):
                        throw ProbeError.unsafeWindow(
                            "iPhone Mirroring lost focus before input on all \(attempts) attempts"
                        )
                    }

                case .stopRequested:
                    current = finalObservation
                    continue characterLoop

                case .maximumRuntimeReached:
                    current = finalObservation
                    continue characterLoop
                }
            }
            }
        } catch CharacterRerollInterruption.stopRequested {
            try emitCharacterRerollReport(
                status: "stopped",
                reason: applicationStopRequest.reportReason,
                startedDate: startedDate,
                window: current.window,
                limits: limits,
                initialTotal: initialTotal,
                finalTotal: characterRerollUnambiguousTotal(current),
                rerollsPosted: rerollsPosted,
                reportURL: reportURL,
                candidateObservation: current,
                candidateRole: candidateRole,
                keeperOrConflictWasObserved: keeperOrConflictWasObserved
            )
            return
        } catch CharacterRerollInterruption.maximumRuntimeReached {
            try emitCharacterRerollReport(
                status: "limitReached",
                reason: "maximumRuntimeReached",
                startedDate: startedDate,
                window: current.window,
                limits: limits,
                initialTotal: initialTotal,
                finalTotal: characterRerollUnambiguousTotal(current),
                rerollsPosted: rerollsPosted,
                reportURL: reportURL,
                candidateObservation: current,
                candidateRole: candidateRole,
                keeperOrConflictWasObserved: keeperOrConflictWasObserved
            )
            throw ProbeError.unsafeWindow(
                "the character reroll runtime limit was reached before total \(minimumTotal)"
            )
        } catch {
            if !terminalReportWasEmitted {
                let reason = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                try? emitCharacterRerollReport(
                    status: "error",
                    reason: reason,
                    startedDate: startedDate,
                    window: current.window,
                    limits: limits,
                    initialTotal: initialTotal,
                    finalTotal: characterRerollUnambiguousTotal(current),
                    rerollsPosted: rerollsPosted,
                    reportURL: reportURL,
                    candidateObservation: current,
                    candidateRole: candidateRole,
                    keeperOrConflictWasObserved: keeperOrConflictWasObserved
                )
            }
            throw error
        }
    }
}
