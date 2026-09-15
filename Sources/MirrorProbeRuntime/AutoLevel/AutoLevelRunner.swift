import AppKit
import CoreGraphics
import Foundation
import MirrorProbeCore

extension MirrorProbeRuntime {
    static func performAutoLevelLoop(
        initialObservation: AutomationObservation,
        identity: AutoLevelWindowIdentity,
        initialFrame: CGRect,
        sessionID: String,
        inputMode: AutoLevelInputMode,
        captureLevel: AutoLevelCaptureLevel,
        captureRecorder: AutomationCaptureRecorder,
        windowRecovery: AutomationWindowRecoveryContext,
        startedAt: TimeInterval,
        maximumCycles: Int?,
        maximumMinutes: Double?,
        maximumActions: Int?,
        pollInterval: TimeInterval,
        directoryURL: URL,
        reportURL: URL,
        stopURL: URL,
        report: inout AutomationRunReport
    ) async throws {
        let policy = AutoLevelPolicy(
            actionCooldown: 0.8,
            postActionTimeout: 12,
            uncertainStateGraceDuration: 15,
            uncertainStateGraceSnapshots: 8,
            maxCycles: maximumCycles,
            maxRuntime: maximumMinutes.map { $0 * 60 },
            maxActions: maximumActions
        )
        let retainsActionPairs = AutoLevelCaptureRetentionPolicy(level: captureLevel)
            .plan(for: .expectedLimit)
            .retainsActionPairs
        let session = AutoLevelSessionMetadata(
            sessionID: sessionID,
            startedAt: startedAt,
            windowIdentity: identity
        )
        var controller = AutoLevelController(session: session, policy: policy)
        var battleTracker = AutomationBattleTracker()
        var autoEnabledBattleIDs = Set<String>()
        var stallDetector = BattleStallDetector(configuration: BattleStallConfiguration(
            suspectedAfter: 3,
            confirmedAfter: 5,
            maximumSampleGap: 3,
            maximumStableROIDifference: 0.002,
            minimumStableSampleCount: 5
        ))
        var stallAssessment = stallDetector.reset()
        var resumableStallProgressByBattleID: [String: BattleStallProgressResumeState] = [:]
        var allAutoProgressValidator = AllAutoProgressValidator()
        var battleActivityProgressDetector = BattleActivityProgressDetector()
        var verifiedAutomaticBattleProgress: VerifiedAutomaticBattleProgress?
        var startupBattleRecovery: StartupBattleRecovery?
        var inputGeneration: UInt64 = 0
        var previousTemporalFrame: AutomationTemporalFrame?
        var currentObservation: AutomationObservation? = initialObservation
        var lastObservation: AutomationObservation? = initialObservation
        var lastLoggedSignature: String?
        var lastHeartbeatAt = startedAt
        var handledWindowContinuityGeneration: UInt64 = 0
        var needsProgressAfterWindowRecovery = false
        var freshnessRecovery = AutoLevelObservationFreshnessRecovery(
            maximumAgeSeconds: policy.postActionTimeout,
            maximumRecaptures: 2
        )

        automationLoop: while true {
            if applicationStopRequest.isRequested(stopFileURL: stopURL) {
                try finishAutomationRun(
                    status: "stopped",
                    reason: applicationStopRequest.reportReason,
                    terminationKind: .userStop,
                    observation: currentObservation ?? lastObservation,
                    captureLevel: captureLevel,
                    captureRecorder: captureRecorder,
                    startedAt: startedAt,
                    directoryURL: directoryURL,
                    reportURL: reportURL,
                    report: &report
                )
                return
            }

            var observation: AutomationObservation
            if let supplied = currentObservation {
                observation = supplied
                currentObservation = nil
            } else {
                try await Task.sleep(for: .seconds(pollInterval))
                observation = try await captureAutomationObservation(
                    requestedID: identity.windowID,
                    expectedIdentity: identity,
                    expectedFrame: initialFrame,
                    captureRecorder: captureRecorder,
                    recovery: windowRecovery,
                    phase: "observation",
                    actionDeadline: controller.pendingActionAcknowledgementDeadline
                )
            }
            let windowContinuityChanged = observation.windowContinuityGeneration
                != handledWindowContinuityGeneration
            if windowContinuityChanged {
                startupBattleRecovery = nil
                handledWindowContinuityGeneration = observation.windowContinuityGeneration
                needsProgressAfterWindowRecovery = true
                inputGeneration &+= 1
                previousTemporalFrame = nil
                verifiedAutomaticBattleProgress = nil
                resumableStallProgressByBattleID.removeAll()
                stallAssessment = stallDetector.reset()
                battleActivityProgressDetector.reset()
                try appendAutomationEvent(
                    kind: "windowAvailabilityRecovered",
                    state: observation.classification.state,
                    decision: "rebuildVisualEvidence",
                    action: nil, target: nil,
                    frameFingerprint: observation.fingerprint,
                    detail: "sameProcessAndWindowVerified=true, continuityGeneration=\(handledWindowContinuityGeneration), stalePixelEvidenceDiscarded=true",
                    screenshotPath: nil,
                    elapsed: observation.capturedAt - startedAt,
                    report: &report, reportURL: reportURL
                )
            }
            lastObservation = observation

            try windowRecovery.checkSessionBoundary()
            let observationDecisionAt = ProcessInfo.processInfo.systemUptime
            let freshness = freshnessRecovery.evaluate(
                capturedAt: observation.capturedAt, now: observationDecisionAt
            )
            if freshness != .fresh {
                startupBattleRecovery = nil
                guard freshness != .invalidTiming else {
                    throw ProbeError.unsafeWindow("the observation freshness timing was invalid")
                }
                // A delayed recognition result may still prove that a posted action advanced at capture
                // time. Preserve that acknowledgement and result counting, but never issue a
                // new request from expired pixels or carry temporal retreat proof across the gap.
                inputGeneration &+= 1
                previousTemporalFrame = nil
                verifiedAutomaticBattleProgress = nil
                resumableStallProgressByBattleID.removeAll()
                stallAssessment = stallDetector.reset()
                battleActivityProgressDetector.reset()
                needsProgressAfterWindowRecovery = true
                let staleSnapshot = AutoLevelSnapshot(
                    classification: observation.classification,
                    runtime: AutoLevelRuntimeMetadata(
                        observedAt: observation.capturedAt,
                        windowIdentity: identity,
                        frameFingerprint: observation.fingerprint,
                        battleSessionID: battleTracker.currentID,
                        allAutoStatus: observation.classification.state == .battle ? .active : .unknown,
                        battleStatus: observation.classification.state == .battle ? .inProgress : .unknown
                    )
                )
                let staleDecision = controller.consume(staleSnapshot, allowNewActions: false)
                report.completedCycles = controller.completedCycles
                let age = observationDecisionAt - observation.capturedAt
                let staleDetail = "captureAgeSeconds=\(age), "
                    + "recognitionDurationSeconds=\(observation.recognitionDurationSeconds), "
                    + "maximumAgeSeconds=\(policy.postActionTimeout), recovery=\(freshness), "
                    + "noInputPosted=true, temporalEvidenceDiscarded=true"
                try appendAutomationEvent(
                    kind: "staleObservation",
                    state: observation.classification.state,
                    decision: String(describing: staleDecision),
                    action: nil, target: nil,
                    frameFingerprint: observation.fingerprint,
                    detail: staleDetail,
                    screenshotPath: nil,
                    elapsed: observationDecisionAt - startedAt,
                    report: &report, reportURL: reportURL
                )
                let staleStopReason: AutoLevelStopReason?
                switch staleDecision {
                case let .stop(reason):
                    staleStopReason = reason
                case .completedCycle:
                    // The capture already proves the requested final cycle completed. A fresh
                    // frame is needed only for another input, not to delay successful shutdown.
                    staleStopReason = policy.maxCycles.flatMap { limit in
                        controller.completedCycles >= limit ? .maximumCyclesReached(limit: limit) : nil
                    }
                default:
                    staleStopReason = nil
                }
                if let reason = staleStopReason {
                    let completed: Bool
                    if case .maximumCyclesReached = reason { completed = true } else { completed = false }
                    try finishAutomationRun(
                        status: completed ? "completed" : "stopped",
                        reason: String(describing: reason),
                        terminationKind: captureTerminationKind(for: reason),
                        observation: observation, captureLevel: captureLevel,
                        captureRecorder: captureRecorder, startedAt: startedAt,
                        directoryURL: directoryURL, reportURL: reportURL, report: &report
                    )
                    return
                }
                if case .requestAction = staleDecision {
                    throw ProbeError.unsafeWindow("an expired observation unexpectedly issued a new action")
                }
                if freshness == .exhausted {
                    try finishAutomationRun(
                        status: "stopped",
                        reason: "staleObservationExceededRecovery(maximumRecaptures: 2); \(staleDetail)",
                        terminationKind: .safetyStop,
                        observation: observation, captureLevel: captureLevel,
                        captureRecorder: captureRecorder, startedAt: startedAt,
                        directoryURL: directoryURL, reportURL: reportURL, report: &report
                    )
                    return
                }
                continue automationLoop
            }

            let battleID = battleTracker.observe(
                state: observation.classification.state,
                sessionID: sessionID
            )
            let newlyAssumedAutomaticBattleID: String?
            if observation.classification.state == .battle,
               let battleID,
               autoEnabledBattleIDs.insert(battleID).inserted
            {
                // Knight & Dragon IV carries the user's configured 全部自動 setting into
                // each battle. Treat that default as already on; clicking the visible control
                // would toggle it off. This is an observation-time assumption, not an input, so
                // inputGeneration intentionally remains unchanged. The validators below still
                // require independently observed battle progress within their bounded timeout.
                newlyAssumedAutomaticBattleID = battleID
                verifiedAutomaticBattleProgress = nil
            } else {
                newlyAssumedAutomaticBattleID = nil
            }
            let allAutoStatus: AutoLevelAllAutoStatus
            if let battleID, autoEnabledBattleIDs.contains(battleID) {
                allAutoStatus = .active
            } else {
                allAutoStatus = .unknown
            }
            let battleContext = automationBattleContext(
                for: observation,
                identity: identity
            )
            let regionDifference = try automationBattleRegionDifference(
                previous: previousTemporalFrame,
                current: observation,
                context: battleContext,
                inputGeneration: inputGeneration
            )
            let stallFrameEvidence = observation.stallEvidence
            let sample = BattleStallSample(
                monotonicTime: observation.capturedAt,
                context: battleContext,
                battleScreenConfirmed: observation.classification.state == .battle,
                modalPresent: isAutomationModal(observation.classification.state),
                paused: !VisualBattleEvidence.hasRunningBattleEvidence(in: observation.classification),
                inputGeneration: inputGeneration,
                frameEvidence: stallFrameEvidence,
                battleROIDifferenceFromPrevious: regionDifference
            )
            let activityProgressAssessment: BattleActivityProgressAssessment
            if let newlyAssumedAutomaticBattleID {
                needsProgressAfterWindowRecovery = false
                resumableStallProgressByBattleID.removeValue(
                    forKey: newlyAssumedAutomaticBattleID
                )
                stallAssessment = stallDetector.automaticBattleEnabled(
                    at: observation.capturedAt,
                    context: battleContext,
                    inputGeneration: inputGeneration
                )
                _ = allAutoProgressValidator.automaticBattleExpected(
                    at: observation.capturedAt,
                    battleSessionID: newlyAssumedAutomaticBattleID
                )
                activityProgressAssessment = battleActivityProgressDetector
                    .automaticBattleExpected(
                        at: observation.capturedAt,
                        battleSessionID: newlyAssumedAutomaticBattleID,
                        context: battleContext,
                        inputGeneration: inputGeneration
                    )
            } else if needsProgressAfterWindowRecovery, let battleID,
                      observation.classification.state == .battle {
                // The first recovered frame may be a loading/unknown page. Keep this reset
                // pending until a real battle frame can establish new temporal baselines.
                needsProgressAfterWindowRecovery = false
                stallAssessment = stallDetector.automaticBattleEnabled(
                    at: observation.capturedAt, context: battleContext,
                    inputGeneration: inputGeneration
                )
                if !allAutoProgressValidator.isAwaitingProgress {
                    _ = allAutoProgressValidator.automaticBattleExpected(
                        at: observation.capturedAt, battleSessionID: battleID
                    )
                }
                activityProgressAssessment = battleActivityProgressDetector.automaticBattleExpected(
                    at: observation.capturedAt, battleSessionID: battleID,
                    context: battleContext, inputGeneration: inputGeneration
                )
            } else {
                stallAssessment = stallDetector.observe(sample)
                if let battleID {
                    activityProgressAssessment = battleActivityProgressDetector.observe(
                        BattleActivityProgressSample(
                            monotonicTime: observation.capturedAt,
                            battleSessionID: battleID,
                            context: battleContext,
                            inputGeneration: inputGeneration,
                            evidence: observation.activityEvidence,
                            battleROIDifferenceFromPrevious: regionDifference
                        )
                    )
                } else {
                    battleActivityProgressDetector.reset()
                    activityProgressAssessment = .inactive
                }
            }
            let stallResetReason = stallAssessment.resetReason
            let mayResumeEstablishedProgress = stallResetReason == .incompleteBattleEvidence
                || stallResetReason == .sampleGap
            if stallAssessment.phase == .inactive,
               !mayResumeEstablishedProgress,
               stallResetReason != nil,
               let battleID
            {
                resumableStallProgressByBattleID.removeValue(forKey: battleID)
            }
            if stallAssessment.isArmed,
               let battleID,
               let resumeState = stallDetector.progressResumeState
            {
                // This map is populated only from detector-issued, already-armed evidence. The
                // battle ID is the runtime's independent boundary between otherwise identical
                // window contexts.
                resumableStallProgressByBattleID[battleID] = resumeState
            }
            if stallAssessment.phase == .inactive,
               let battleID,
               autoEnabledBattleIDs.contains(battleID),
               observation.classification.state == .battle
            {
                if mayResumeEstablishedProgress,
                   let resumeState = resumableStallProgressByBattleID[battleID]
                {
                    stallAssessment = stallDetector.resumeMonitoring(
                        from: resumeState,
                        at: observation.capturedAt,
                        context: battleContext,
                        inputGeneration: inputGeneration
                    )
                    if stallAssessment.phase == .inactive {
                        resumableStallProgressByBattleID.removeValue(forKey: battleID)
                    }
                }
                if stallAssessment.phase == .inactive {
                    // Automatic mode remains latched for this battle, but no prior progress is
                    // inferred across other reset causes or an identity mismatch.
                    stallAssessment = stallDetector.automaticBattleEnabled(
                        at: observation.capturedAt,
                        context: battleContext,
                        inputGeneration: inputGeneration
                    )
                }
            }
            previousTemporalFrame = AutomationTemporalFrame(
                rgba: observation.rgba,
                context: battleContext,
                inputGeneration: inputGeneration
            )
            let allAutoValidation = allAutoProgressValidator.observe(
                at: observation.capturedAt,
                battleSessionID: battleID,
                state: observation.classification.state,
                genuineProgressObserved: stallAssessment.isArmed
                    || activityProgressAssessment.didObserveProgress
            )
            if observation.capturedAt == initialObservation.capturedAt,
               inputGeneration == 0,
               let battleID
            {
                // Only a battle already visible when this session starts gets this recovery
                // path. A later battle or a lost capture baseline must prove normal activity.
                startupBattleRecovery = StartupBattleRecovery(
                    sample: sample, battleSessionID: battleID,
                    configuration: stallDetector.configuration,
                    minimumObservationDuration: allAutoProgressValidator.configuration.timeout
                )
            } else {
                _ = startupBattleRecovery?.observe(
                    sample, battleSessionID: battleID,
                    genuineProgressObserved: stallAssessment.isArmed
                        || activityProgressAssessment.didObserveProgress
                )
            }
            if case .validated(.genuineBattleProgress) = allAutoValidation,
               let battleID
            {
                verifiedAutomaticBattleProgress = VerifiedAutomaticBattleProgress(
                    battleSessionID: battleID,
                    inputGeneration: inputGeneration
                )
            }
            if verifiedAutomaticBattleProgress?.matches(
                battleSessionID: battleID,
                inputGeneration: inputGeneration
            ) == true,
               observation.classification.state == .battle,
               !stallAssessment.isArmed
            {
                // Normal automatic combat was independently proven by significant changes
                // in fixed HP/log regions plus moving battle pixels. From here, use dense
                // five-second visual stability; no HP numbers are inferred.
                stallAssessment = stallDetector.markVerifiedNormalBattleProgress(
                    at: observation.capturedAt,
                    context: battleContext,
                    inputGeneration: inputGeneration
                )
            }
            var startupVisualConfirmation: BattleVisualStabilityConfirmation?
            if case let .timedOut(unresponsiveBattleID) = allAutoValidation {
                startupVisualConfirmation = startupBattleRecovery?.beginVisualConfirmation(
                    from: sample, battleSessionID: unresponsiveBattleID
                )
                if startupVisualConfirmation != nil {
                    // Preserve the original, already-expired deadline until retreat is posted.
                    // If the burst or preflight is cancelled, the next observation must prove
                    // real progress/forward transition or stop; it cannot retry startup recovery
                    // or silently continue without a validator.
                    _ = allAutoProgressValidator.automaticBattleExpected(
                        at: initialObservation.capturedAt,
                        battleSessionID: unresponsiveBattleID
                    )
                    try appendAutomationEvent(
                        kind: "startupBattleRecoveryStarted",
                        state: observation.classification.state,
                        decision: "confirmFrozenStartupBattle",
                        action: nil, target: nil,
                        frameFingerprint: observation.fingerprint,
                        detail: "battleSessionID=\(unresponsiveBattleID), "
                            + "noProgressSeconds=\(observation.capturedAt - initialObservation.capturedAt), "
                            + "minimumStableSeconds=5, genuineProgressObserved=false, noInputPosted=true",
                        screenshotPath: nil,
                        elapsed: observation.capturedAt - startedAt,
                        report: &report, reportURL: reportURL
                    )
                }
            }
            if case let .timedOut(unresponsiveBattleID) = allAutoValidation,
               startupVisualConfirmation == nil
            {
                try finishAutomationRun(
                    status: "stopped",
                    reason: "allAutoDidNotProduceProgress(battleSessionID: \(unresponsiveBattleID), timeout: 30.0)",
                    terminationKind: .safetyStop,
                    observation: observation,
                    captureLevel: captureLevel,
                    captureRecorder: captureRecorder,
                    startedAt: startedAt,
                    directoryURL: directoryURL,
                    reportURL: reportURL,
                    report: &report
                )
                return
            }
            var retreatVisualConfirmation: BattleVisualStabilityConfirmation?
            let retreatVisualAnchor = observation.rgba
            var visualConfirmationCandidate = startupVisualConfirmation
            if visualConfirmationCandidate == nil,
               stallAssessment.isArmed,
               verifiedAutomaticBattleProgress?.matches(
                   battleSessionID: battleID,
                   inputGeneration: inputGeneration
               ) == true,
               allAutoStatus == .active,
               let regionDifference,
               regionDifference <= stallDetector.configuration.maximumStableROIDifference
            {
                visualConfirmationCandidate = stallDetector.beginVisualConfirmation(from: sample)
            }
            if let confirmation = visualConfirmationCandidate {
                let result = try await confirmAutomationVisualStability(
                    confirmation,
                    anchor: observation,
                    identity: identity,
                    expectedFrame: initialFrame,
                    inputGeneration: inputGeneration,
                    sessionDeadline: windowRecovery.sessionDeadline,
                    stopURL: stopURL,
                    captureRecorder: captureRecorder,
                    windowRecovery: windowRecovery
                )
                switch result {
                case let .confirmed(confirmation, final, assessment):
                    retreatVisualConfirmation = confirmation
                    observation = final
                    lastObservation = final
                    stallAssessment = assessment
                    previousTemporalFrame = AutomationTemporalFrame(
                        rgba: final.rgba,
                        context: battleContext,
                        inputGeneration: inputGeneration
                    )
                    try appendAutomationEvent(
                        kind: "battleVisualStabilityConfirmed",
                        state: final.classification.state,
                        decision: "freshBattleVisualConfirmed",
                        action: nil,
                        target: nil,
                        frameFingerprint: final.fingerprint,
                        detail: automationStallDetail(assessment) + ", fixedAnchorCompared=true, "
                            + "recoveryBasis=\(startupVisualConfirmation != nil ? "frozenAtStartup" : "verifiedBattleProgress")",
                        screenshotPath: nil,
                        elapsed: final.capturedAt - startedAt,
                        report: &report,
                        reportURL: reportURL
                    )
                case let .rejected(final, detail):
                    currentObservation = final
                    lastObservation = final
                    try appendAutomationEvent(
                        kind: "battleVisualStabilityCancelled",
                        state: final.classification.state,
                        decision: "continueObservation",
                        action: nil,
                        target: nil,
                        frameFingerprint: final.fingerprint,
                        detail: detail + ", noInputPosted=true",
                        screenshotPath: nil,
                        elapsed: final.capturedAt - startedAt,
                        report: &report,
                        reportURL: reportURL
                    )
                    continue automationLoop
                case let .interrupted(interruption):
                    // Preserve the observed cause even if the STOP file is removed before
                    // this caller runs; an unlimited session cannot expire its runtime.
                    let stoppedByUser = interruption == .stopRequested
                    try finishAutomationRun(
                        status: "stopped",
                        reason: try automationInterruptionReason(
                            stoppedByUser: stoppedByUser, maximumRuntime: policy.maxRuntime
                        ),
                        terminationKind: stoppedByUser ? .userStop : .expectedLimit,
                        observation: lastObservation,
                        captureLevel: captureLevel,
                        captureRecorder: captureRecorder,
                        startedAt: startedAt,
                        directoryURL: directoryURL,
                        reportURL: reportURL,
                        report: &report
                    )
                    return
                }
            }
            let battleStatus: AutoLevelBattleStatus
            if stallAssessment.isConfirmedEvidence,
               retreatVisualConfirmation != nil,
               stallAssessment.isArmed,
               (startupVisualConfirmation != nil || verifiedAutomaticBattleProgress?.matches(
                   battleSessionID: battleID,
                   inputGeneration: inputGeneration
               ) == true),
               allAutoStatus == .active
            {
                // Both recovery paths require the same dense pixel confirmation and fresh
                // preflight. The startup exception never manufactures normal-combat progress.
                battleStatus = .stalledAfterDefeat
            } else if observation.classification.state == .battle {
                battleStatus = .inProgress
            } else {
                battleStatus = .unknown
            }
            let runtime = AutoLevelRuntimeMetadata(
                observedAt: observation.capturedAt,
                windowIdentity: identity,
                frameFingerprint: observation.fingerprint,
                battleSessionID: battleID,
                allAutoStatus: allAutoStatus,
                battleStatus: battleStatus
            )
            let snapshot = AutoLevelSnapshot(
                classification: observation.classification,
                runtime: runtime
            )
            let decision = controller.consume(snapshot)
            report.completedCycles = controller.completedCycles

            let signature = "\(observation.classification.state.rawValue)|"
                + "\(String(describing: decision))|\(stallAssessment.phase.rawValue)"
            let shouldLog = signature != lastLoggedSignature
                || observation.capturedAt - lastHeartbeatAt >= 30
            if shouldLog {
                var detail = automationStallDetail(stallAssessment)
                    + ", captureAgeSeconds=\(ProcessInfo.processInfo.systemUptime - observation.capturedAt)"
                    + ", recognitionDurationSeconds=\(observation.recognitionDurationSeconds)"
                    + ", startupRecoveryEligible=\(startupBattleRecovery?.isEligible == true)"
                let evidence = observation.classification.evidence.map { item in
                    "\(item.kind.rawValue): \(item.detail)"
                }.joined(separator: "; ")
                detail += ", recognitionMode=visualRegions, classificationEvidence=[\(evidence)]"
                try appendAutomationEvent(
                    kind: "observation",
                    state: observation.classification.state,
                    decision: String(describing: decision),
                    action: nil,
                    target: nil,
                    frameFingerprint: observation.fingerprint,
                    detail: detail,
                    screenshotPath: nil,
                    elapsed: observation.capturedAt - startedAt,
                    report: &report,
                    reportURL: reportURL
                )
                lastLoggedSignature = signature
                lastHeartbeatAt = observation.capturedAt
            }

            switch decision {
            case .wait:
                continue

            case let .completedCycle(completion):
                report.completedCycles = completion.count
                try appendAutomationEvent(
                    kind: "cycleCompleted",
                    state: observation.classification.state,
                    decision: String(describing: decision),
                    action: nil,
                    target: nil,
                    frameFingerprint: observation.fingerprint,
                    detail: "cycle=\(completion.count), outcome=\(completion.outcome.rawValue)",
                    screenshotPath: nil,
                    elapsed: observation.capturedAt - startedAt,
                    report: &report,
                    reportURL: reportURL
                )
                // The controller intentionally reports the new cycle before choosing the result
                // page action. Reuse this exact, already trusted observation immediately instead
                // of taking another sample after the already-confirmed visual state.
                // Action preflight still performs a fresh capture and full target validation.
                currentObservation = observation
                continue

            case let .requestAction(request):
                let actionDeadline = observation.capturedAt + policy.postActionTimeout
                let sessionDeadline = windowRecovery.sessionDeadline
                let expectedResultPage = MissionSuccessPageIdentity.resolve(
                    in: observation.classification
                )
                let actionStem = String(format: "action-%04llu-%@", request.requestID, request.intent.rawValue)
                let beforeURL: URL?
                let afterURL: URL?
                if retainsActionPairs {
                    let framesURL = directoryURL.appendingPathComponent(
                        "frames",
                        isDirectory: true
                    )
                    beforeURL = framesURL.appendingPathComponent("\(actionStem)-before.png")
                    afterURL = framesURL.appendingPathComponent("\(actionStem)-after.png")
                } else {
                    beforeURL = nil
                    afterURL = nil
                }
                var activationRetry = AutoLevelForegroundActivationRetryState()
                var activationFailureDetails: [String] = []
                var applicationResolutionFailures = 0
                var resultObservationFailures = 0
                var postedPreflight: AutomationObservation?
                var postedAfter: AutomationObservation?
                var postedActionTime: TimeInterval?

                activationAttemptLoop: while true {
                    if applicationStopRequest.isRequested(stopFileURL: stopURL) {
                        try finishAutomationRun(
                            status: "stopped",
                            reason: applicationStopRequest.reportReason,
                            terminationKind: .userStop,
                            observation: lastObservation,
                            captureLevel: captureLevel,
                            captureRecorder: captureRecorder,
                            startedAt: startedAt,
                            directoryURL: directoryURL,
                            reportURL: reportURL,
                            report: &report
                        )
                        return
                    }
                    let retryBoundaryNow = ProcessInfo.processInfo.systemUptime
                    guard retryBoundaryNow.isFinite,
                          retryBoundaryNow >= 0,
                          actionDeadline.isFinite,
                          sessionDeadline?.isFinite != false
                    else {
                        throw ProbeError.unsafeWindow(
                            "the action confirmation retry timing was invalid"
                        )
                    }
                    if let sessionDeadline, let maximumRuntime = policy.maxRuntime,
                       retryBoundaryNow >= sessionDeadline {
                        let reason = AutoLevelStopReason.maximumRuntimeReached(
                            limit: maximumRuntime
                        )
                        try finishAutomationRun(
                            status: "stopped",
                            reason: String(describing: reason),
                            terminationKind: .expectedLimit,
                            observation: lastObservation,
                            captureLevel: captureLevel,
                            captureRecorder: captureRecorder,
                            startedAt: startedAt,
                            directoryURL: directoryURL,
                            reportURL: reportURL,
                            report: &report
                        )
                        return
                    }
                    guard retryBoundaryNow < actionDeadline else {
                        let phase = activationRetry.currentAttempt == 1
                            ? "before the first foreground activation attempt"
                            : "during an action confirmation retry"
                        throw ProbeError.unsafeWindow(
                            "the action authorization expired \(phase); "
                                + "attempt=\(activationRetry.currentAttempt), "
                                + "resultObservationFailures=\(resultObservationFailures), "
                                + "captureAgeSeconds=\(retryBoundaryNow - observation.capturedAt), "
                                + "recognitionDurationSeconds=\(observation.recognitionDurationSeconds), "
                                + "authorizationSeconds=\(policy.postActionTimeout), noInputPosted=true"
                        )
                    }

                    var focusBorrow = inputMode == .foreground
                        ? ForegroundFocusBorrow(targetProcessID: identity.processID)
                        : nil
                    guard inputMode != .foreground || focusBorrow != nil else {
                        // macOS can briefly return AXError.noValue while the user switches
                        // applications. No activation or input has happened in this attempt.
                        // Spend the same bounded budget, then read the original app anew; never
                        // substitute a cached PID or renew the action/session deadlines.
                        let failureDetail = "phase=focusBorrow, "
                            + "attempt=\(activationRetry.currentAttempt)/"
                            + "\(AutoLevelForegroundActivationRetryState.maximumAttempts), "
                            + "focusSource=Accessibility, "
                            + "result=focusedApplicationUnavailable, noInputPosted=true"
                        activationFailureDetails.append(failureDetail)
                        let retryDecision = activationRetry.recordUnpostedFocusFailure()
                        let detail: String
                        let kind: String
                        switch retryDecision {
                        case let .retry(_, delayMilliseconds):
                            kind = "activationRetry"
                            detail = failureDetail + ", nextDelayMilliseconds=\(delayMilliseconds)"
                        case .exhausted:
                            kind = "activationRetryExhausted"
                            detail = failureDetail
                        }
                        try appendAutomationEvent(
                            kind: kind,
                            state: observation.classification.state,
                            decision: String(describing: decision),
                            action: request.intent,
                            target: request.target,
                            frameFingerprint: observation.fingerprint,
                            detail: detail,
                            screenshotPath: nil,
                            elapsed: retryBoundaryNow - startedAt,
                            report: &report,
                            reportURL: reportURL
                        )
                        switch retryDecision {
                        case let .retry(_, delayMilliseconds):
                            try await Task.sleep(for: .milliseconds(delayMilliseconds))
                            continue activationAttemptLoop
                        case let .exhausted(attempts):
                            throw ProbeError.unsafeWindow(
                                "the current focused application remained unavailable after "
                                    + "\(attempts) attempts; "
                                    + activationFailureDetails.joined(separator: " | ")
                            )
                        }
                    }
                    defer { focusBorrow?.restore() }
                    let preflightResult = try await activateAndPreflightAutomationAction(
                        request,
                        identity: identity,
                        expectedFrame: initialFrame,
                        inputMode: inputMode,
                        expectedFocusSourceProcessID: focusBorrow?.previousProcessID,
                        activationAttempt: activationRetry.currentAttempt,
                        activationSettleDelayMilliseconds: activationRetry
                            .settleDelayMilliseconds,
                        battleSessionID: battleID,
                        allAutoStatus: allAutoStatus,
                        battleStatus: battleStatus,
                        captureRecorder: captureRecorder,
                        windowRecovery: windowRecovery,
                        actionDeadline: actionDeadline,
                        expectedResultPage: expectedResultPage
                    )
                    let preflight: AutomationObservation
                    let confirmedTarget: AutoLevelActionTarget
                    let activation: AutomationForegroundActivationSnapshot?
                    switch preflightResult {
                    case let .applicationUnavailable(processIsRunning, resolutionDetail):
                        // Restore/cancel this borrow before waiting. A retry starts a new borrow
                        // and a complete preflight of this same unposted action, never a new run.
                        focusBorrow?.restore()
                        applicationResolutionFailures += 1
                        let failedAttempt = activationRetry.currentAttempt
                        let failureDetail = "phase=applicationResolution, requestID=\(request.requestID), "
                            + "attempt=\(failedAttempt)/\(AutoLevelForegroundActivationRetryState.maximumAttempts), "
                            + resolutionDetail + ", noInputPosted=true"
                        activationFailureDetails.append(failureDetail)
                        let retryDecision = activationRetry.recordUnpostedApplicationResolutionFailure(
                            processIsRunning: processIsRunning,
                            inputWasPosted: false
                        )
                        let kind: String
                        let detail: String
                        switch retryDecision {
                        case let .retry(_, delayMilliseconds):
                            kind = "applicationResolutionRetry"
                            detail = failureDetail + ", nextDelayMilliseconds=\(delayMilliseconds)"
                        case .exhausted:
                            kind = "applicationResolutionRetryExhausted"
                            detail = failureDetail
                        case nil:
                            kind = "applicationResolutionRetryRefused"
                            detail = failureDetail + ", reason=processNotConfirmedRunning"
                        }
                        try appendAutomationEvent(
                            kind: kind,
                            state: observation.classification.state,
                            decision: String(describing: decision),
                            action: request.intent,
                            target: request.target,
                            frameFingerprint: observation.fingerprint,
                            detail: detail,
                            screenshotPath: nil,
                            elapsed: ProcessInfo.processInfo.systemUptime - startedAt,
                            report: &report,
                            reportURL: reportURL
                        )
                        switch retryDecision {
                        case let .retry(_, delayMilliseconds):
                            try await Task.sleep(for: .milliseconds(delayMilliseconds))
                            continue activationAttemptLoop
                        case let .exhausted(attempts):
                            throw ProbeError.unsafeWindow(
                                "could not resolve the iPhone Mirroring application within "
                                    + "\(attempts) shared action attempts; "
                                    + activationFailureDetails.joined(separator: " | ")
                            )
                        case nil:
                            throw ProbeError.unsafeWindow(
                                "could not resolve the iPhone Mirroring application; " + detail
                            )
                        }

                    case let .confirmed(observation, target, activationSnapshot):
                        preflight = observation
                        confirmedTarget = target
                        activation = activationSnapshot
                        if applicationResolutionFailures > 0 {
                            try appendAutomationEvent(
                                kind: "applicationResolutionRecovered",
                                state: observation.classification.state,
                                decision: "freshPreflightConfirmed",
                                action: request.intent,
                                target: target,
                                frameFingerprint: observation.fingerprint,
                                detail: "requestID=\(request.requestID), expectedPID=\(identity.processID), "
                                    + "expectedWindowID=\(identity.windowID), "
                                    + "attempt=\(activationRetry.currentAttempt), "
                                    + "applicationResolutionFailures=\(applicationResolutionFailures), "
                                    + "sameProcessAndWindowVerified=true, noInputPosted=true",
                                screenshotPath: nil,
                                elapsed: observation.capturedAt - startedAt,
                                report: &report,
                                reportURL: reportURL
                            )
                        }

                    case let .stateChanged(observation, activationSnapshot):
                        focusBorrow?.restore()
                        let confirmationEvidence = observation.classification.evidence.map {
                            "\($0.kind.rawValue): \($0.detail)"
                        }.joined(separator: " | ")
                        // A brief overlay can hide the result title. Keep this same unposted
                        // request and its original deadline/page/target; never feed the unknown
                        // frame back into the controller to mint a fresh authorization. Every
                        // retry goes through complete activation, capture and input validation.
                        let failedAttempt = activationRetry.currentAttempt
                        if let retryDecision = activationRetry.recordUnpostedResultObservationFailure(
                            intent: request.intent,
                            classification: observation.classification,
                            inputWasPosted: false
                        ) {
                            lastObservation = observation
                            resultObservationFailures += 1
                            let confirmationNow = ProcessInfo.processInfo.systemUptime
                            let failureDetail = "requestID=\(request.requestID), "
                                + "attempt=\(failedAttempt)/\(AutoLevelForegroundActivationRetryState.maximumAttempts), "
                                + "expectedPage=\(String(describing: expectedResultPage)), "
                                + "captureAgeSeconds=\(confirmationNow - observation.capturedAt), "
                                + "authorizationRemainingSeconds=\(actionDeadline - confirmationNow), "
                                + "resultObservationFailures=\(resultObservationFailures), noInputPosted=true, "
                                + "evidence=\(confirmationEvidence)"
                            let kind: String
                            let detail: String
                            switch retryDecision {
                            case let .retry(_, delayMilliseconds):
                                kind = "resultConfirmationRetry"
                                detail = failureDetail + ", nextDelayMilliseconds=\(delayMilliseconds)"
                            case .exhausted:
                                kind = "resultConfirmationRetryExhausted"
                                detail = failureDetail
                            }
                            try appendAutomationEvent(
                                kind: kind,
                                state: observation.classification.state,
                                decision: String(describing: decision),
                                action: request.intent,
                                target: request.target,
                                frameFingerprint: observation.fingerprint,
                                detail: detail,
                                screenshotPath: nil,
                                elapsed: confirmationNow - startedAt,
                                report: &report,
                                reportURL: reportURL
                            )
                            switch retryDecision {
                            case let .retry(_, delayMilliseconds):
                                try await Task.sleep(for: .milliseconds(delayMilliseconds))
                                continue activationAttemptLoop
                            case let .exhausted(attempts):
                                throw ProbeError.unsafeWindow(
                                    "the result page remained unknown after \(attempts) "
                                        + "action confirmation attempts; " + failureDetail
                                )
                            }
                        }
                        if activationRetry.currentAttempt > 1,
                           let activationSnapshot
                        {
                            try appendAutomationEvent(
                                kind: resultObservationFailures > 0
                                    ? "confirmationRecovered" : "activationRecovered",
                                state: observation.classification.state,
                                decision: String(describing: decision),
                                action: request.intent,
                                target: request.target,
                                frameFingerprint: observation.fingerprint,
                                detail: activationSnapshot.detail(
                                    phase: "preflight",
                                    result: "readyWithStateChange"
                                ),
                                screenshotPath: nil,
                                elapsed: observation.capturedAt - startedAt,
                                report: &report,
                                reportURL: reportURL
                            )
                        }
                        let cancellationReason: String
                        if request.intent == .requestRetreat,
                           controller.cancelUnpostedRetreat(request)
                        {
                            cancellationReason = "retreatStateChanged"
                        } else if controller.cancelUnpostedActionAfterForwardResultTransition(
                            request,
                            observedState: observation.classification.state
                        ) {
                            cancellationReason = "forwardResultTransition"
                        } else if controller.cancelUnpostedSuccessAdvanceAfterPageTransition(
                            request, observedClassification: observation.classification
                        ) {
                            cancellationReason = "experienceToLootPageTransition"
                        } else if controller.cancelUnpostedActionForObservedModal(
                            request,
                            observedState: observation.classification.state
                        ) {
                            cancellationReason = "newGeometryModal"
                        } else {
                            throw ProbeError.unsafeWindow(
                                "the game state changed from \(request.observedState.rawValue) to "
                                    + "\(observation.classification.state.rawValue), or its result page changed, during action confirmation; "
                                    + "evidence=\(confirmationEvidence)"
                            )
                        }
                        currentObservation = observation
                        lastObservation = observation
                        try appendAutomationEvent(
                            kind: "actionAlreadySatisfied",
                            state: observation.classification.state,
                            decision: String(describing: decision),
                            action: request.intent,
                            target: request.target,
                            frameFingerprint: observation.fingerprint,
                            detail: "noInputPosted=true, requestID=\(request.requestID), "
                                + "transition=\(request.observedState.rawValue)->"
                                + "\(observation.classification.state.rawValue); stale authorization "
                                + "cancelledReason=\(cancellationReason); confirmation capture will "
                                + "be processed as the next observation",
                            screenshotPath: nil,
                            elapsed: observation.capturedAt - startedAt,
                            report: &report,
                            reportURL: reportURL
                        )
                        continue automationLoop

                    case let .activationContended(observation, activationSnapshot):
                        focusBorrow?.restore()
                        lastObservation = observation
                        if request.intent == .requestRetreat {
                            // This is a new captured frame even though focus was contested.
                            // Discard the proof rather than skip potentially moving/modal pixels
                            // and later reuse it after an apparently stable retry frame.
                            guard controller.cancelUnpostedRetreat(request) else {
                                throw ProbeError.unsafeWindow("the contested retreat request could not be cancelled")
                            }
                            currentObservation = observation
                            try appendAutomationEvent(
                                kind: "battleVisualStabilityCancelled",
                                state: observation.classification.state,
                                decision: "continueObservation",
                                action: request.intent,
                                target: request.target,
                                frameFingerprint: observation.fingerprint,
                                detail: "retreatFocusContended, noInputPosted=true",
                                screenshotPath: nil,
                                elapsed: observation.capturedAt - startedAt,
                                report: &report,
                                reportURL: reportURL
                            )
                            continue automationLoop
                        }
                        let failureDetail = activationSnapshot.detail(
                            phase: "preflight",
                            result: "focusContended"
                        )
                        activationFailureDetails.append(failureDetail)
                        let retryDecision = activationRetry.recordUnpostedFocusFailure()
                        switch retryDecision {
                        case let .retry(_, delayMilliseconds):
                            try appendAutomationEvent(
                                kind: "activationRetry",
                                state: observation.classification.state,
                                decision: String(describing: decision),
                                action: request.intent,
                                target: request.target,
                                frameFingerprint: observation.fingerprint,
                                detail: "\(failureDetail), nextDelayMilliseconds=\(delayMilliseconds)",
                                screenshotPath: nil,
                                elapsed: observation.capturedAt - startedAt,
                                report: &report,
                                reportURL: reportURL
                            )
                            try await Task.sleep(for: .milliseconds(delayMilliseconds))
                            continue activationAttemptLoop

                        case let .exhausted(attempts):
                            try appendAutomationEvent(
                                kind: "activationRetryExhausted",
                                state: observation.classification.state,
                                decision: String(describing: decision),
                                action: request.intent,
                                target: request.target,
                                frameFingerprint: observation.fingerprint,
                                detail: failureDetail,
                                screenshotPath: nil,
                                elapsed: observation.capturedAt - startedAt,
                                report: &report,
                                reportURL: reportURL
                            )
                            throw ProbeError.unsafeWindow(
                                "iPhone Mirroring could not be made active and frontmost after "
                                    + "\(attempts) attempts; "
                                    + activationFailureDetails.joined(separator: " | ")
                            )
                        }
                    }

                    if request.intent == .requestRetreat {
                        if preflight.windowContinuityGeneration != observation.windowContinuityGeneration {
                            retreatVisualConfirmation = nil
                        }
                        let preflightContext = automationBattleContext(
                            for: preflight,
                            identity: identity
                        )
                        let preflightDifference = try automationBattleRegionDifference(
                            previous: previousTemporalFrame,
                            current: preflight,
                            context: preflightContext,
                            inputGeneration: inputGeneration
                        )
                        let preflightSample = BattleStallSample(
                            monotonicTime: preflight.capturedAt,
                            context: preflightContext,
                            battleScreenConfirmed: preflight.classification.state == .battle,
                            modalPresent: isAutomationModal(preflight.classification.state),
                            paused: !VisualBattleEvidence.hasRunningBattleEvidence(in: preflight.classification),
                            inputGeneration: inputGeneration,
                            frameEvidence: preflight.stallEvidence,
                            battleROIDifferenceFromPrevious: preflightDifference
                        )
                        let preflightAssessment = retreatVisualConfirmation?.validate(
                            preflightSample,
                            differenceFromAnchor: try automationBattlePixelDifference(
                                retreatVisualAnchor, preflight.rgba
                            )
                        )
                        guard let preflightAssessment else {
                            focusBorrow?.restore()
                            guard controller.cancelUnpostedRetreat(request) else {
                                throw ProbeError.unsafeWindow("the stale retreat request could not be cancelled")
                            }
                            currentObservation = preflight
                            lastObservation = preflight
                            try appendAutomationEvent(
                                kind: "battleVisualStabilityCancelled",
                                state: preflight.classification.state,
                                decision: "continueObservation",
                                action: request.intent,
                                target: request.target,
                                frameFingerprint: preflight.fingerprint,
                                detail: "retreatPreflightContinuityLost, noInputPosted=true",
                                screenshotPath: nil,
                                elapsed: preflight.capturedAt - startedAt,
                                report: &report,
                                reportURL: reportURL
                            )
                            continue automationLoop
                        }
                        stallAssessment = preflightAssessment
                        previousTemporalFrame = AutomationTemporalFrame(
                            rgba: preflight.rgba,
                            context: preflightContext,
                            inputGeneration: inputGeneration
                        )
                    }

                    let clickResult = try postAutomationClick(
                        request,
                        confirmedTarget: confirmedTarget,
                        using: preflight,
                        activation: activation,
                        identity: identity,
                        expectedFrame: initialFrame,
                        inputMode: inputMode,
                        actionDeadline: actionDeadline,
                        sessionDeadline: sessionDeadline,
                        stopURL: stopURL
                    )
                    switch clickResult {
                    case let .posted(postedAt):
                        guard controller.markActionPosted(request, at: postedAt) else {
                            throw ProbeError.unsafeWindow(
                                "the controller refused the posted action acknowledgement window"
                            )
                        }
                        report.actionsPosted += 1
                        if request.intent == .requestRetreat, startupVisualConfirmation != nil {
                            allAutoProgressValidator.reset()
                        }
                        postedPreflight = preflight
                        postedActionTime = postedAt
                        // CGEvent.post queues the mouse-up; it is not a delivery acknowledgement.
                        // Keep the successful borrow alive through the existing first after-frame,
                        // including the loop's defer. Do not repost a toggle if it has not changed.
                        let remainingRuntime = sessionDeadline.map {
                            max(0, $0 - ProcessInfo.processInfo.systemUptime)
                        }
                        try await Task.sleep(for: .seconds(min(1, remainingRuntime ?? 1)))
                        let stoppedByUser = applicationStopRequest.isRequested(stopFileURL: stopURL)
                        if stoppedByUser || sessionDeadline.map({
                            ProcessInfo.processInfo.systemUptime >= $0
                        }) == true {
                            focusBorrow?.restore()
                            try finishAutomationRun(
                                status: "stopped",
                                reason: try automationInterruptionReason(
                                    stoppedByUser: stoppedByUser, maximumRuntime: policy.maxRuntime
                                ),
                                terminationKind: stoppedByUser ? .userStop : .expectedLimit,
                                observation: preflight,
                                captureLevel: captureLevel,
                                captureRecorder: captureRecorder,
                                startedAt: startedAt,
                                directoryURL: directoryURL,
                                reportURL: reportURL,
                                report: &report
                            )
                            return
                        }
                        postedAfter = try await captureAutomationObservation(
                            requestedID: identity.windowID,
                            expectedIdentity: identity,
                            expectedFrame: initialFrame,
                            captureRecorder: captureRecorder,
                            recovery: windowRecovery,
                            phase: "afterPost",
                            actionDeadline: postedAt + policy.postActionTimeout
                        )
                        focusBorrow?.restore()
                        break activationAttemptLoop

                    case .stopRequested:
                        focusBorrow?.restore()
                        try finishAutomationRun(
                            status: "stopped",
                            reason: applicationStopRequest.reportReason,
                            terminationKind: .userStop,
                            observation: preflight,
                            captureLevel: captureLevel,
                            captureRecorder: captureRecorder,
                            startedAt: startedAt,
                            directoryURL: directoryURL,
                            reportURL: reportURL,
                            report: &report
                        )
                        return

                    case .maximumRuntimeReached:
                        focusBorrow?.restore()
                        let reason = try automationInterruptionReason(
                            stoppedByUser: false, maximumRuntime: policy.maxRuntime
                        )
                        try finishAutomationRun(
                            status: "stopped",
                            reason: reason,
                            terminationKind: .expectedLimit,
                            observation: preflight,
                            captureLevel: captureLevel,
                            captureRecorder: captureRecorder,
                            startedAt: startedAt,
                            directoryURL: directoryURL,
                            reportURL: reportURL,
                            report: &report
                        )
                        return

                    case let .foregroundActivationContended(detail):
                        focusBorrow?.restore()
                        lastObservation = preflight
                        activationFailureDetails.append(detail)
                        let retryDecision = activationRetry.recordUnpostedFocusFailure()
                        switch retryDecision {
                        case let .retry(_, delayMilliseconds):
                            try appendAutomationEvent(
                                kind: "activationRetry",
                                state: preflight.classification.state,
                                decision: String(describing: decision),
                                action: request.intent,
                                target: request.target,
                                frameFingerprint: preflight.fingerprint,
                                detail: "\(detail), nextDelayMilliseconds=\(delayMilliseconds)",
                                screenshotPath: nil,
                                elapsed: ProcessInfo.processInfo.systemUptime - startedAt,
                                report: &report,
                                reportURL: reportURL
                            )
                            try await Task.sleep(for: .milliseconds(delayMilliseconds))
                            continue activationAttemptLoop

                        case let .exhausted(attempts):
                            try appendAutomationEvent(
                                kind: "activationRetryExhausted",
                                state: preflight.classification.state,
                                decision: String(describing: decision),
                                action: request.intent,
                                target: request.target,
                                frameFingerprint: preflight.fingerprint,
                                detail: detail,
                                screenshotPath: nil,
                                elapsed: ProcessInfo.processInfo.systemUptime - startedAt,
                                report: &report,
                                reportURL: reportURL
                            )
                            throw ProbeError.unsafeWindow(
                                "iPhone Mirroring could not obtain an unobscured foreground input point on all "
                                    + "\(attempts) attempts; "
                                    + activationFailureDetails.joined(separator: " | ")
                            )
                        }
                    }
                }

                guard let preflight = postedPreflight,
                      let after = postedAfter,
                      let postedAt = postedActionTime
                else {
                    throw ProbeError.unsafeWindow(
                        "foreground activation ended without posting or a classified stop"
                    )
                }
                inputGeneration &+= 1
                verifiedAutomaticBattleProgress = nil
                previousTemporalFrame = nil
                battleActivityProgressDetector.reset()
                if let battleID {
                    resumableStallProgressByBattleID.removeValue(forKey: battleID)
                }
                if request.intent == .enableAllAuto, let battleID {
                    autoEnabledBattleIDs.insert(battleID)
                    let autoPostedAt = postedAt
                    stallAssessment = stallDetector.automaticBattleEnabled(
                        at: autoPostedAt,
                        context: automationBattleContext(for: preflight, identity: identity),
                        inputGeneration: inputGeneration
                    )
                    _ = allAutoProgressValidator.automaticBattlePosted(
                        at: autoPostedAt,
                        battleSessionID: battleID
                    )
                    _ = battleActivityProgressDetector.automaticBattlePosted(
                        at: autoPostedAt,
                        battleSessionID: battleID,
                        context: automationBattleContext(for: preflight, identity: identity),
                        inputGeneration: inputGeneration
                    )
                } else if (request.intent == .closeBattlePrompt
                            || request.intent == .pressWideModalTopButton),
                          let battleID,
                          autoEnabledBattleIDs.contains(battleID)
                {
                    // Closing a modal within an already-automatic battle changes the input
                    // generation and invalidates both temporal baselines. Start a fresh bounded
                    // progress expectation for the same battle; the prompt itself never counts
                    // as proof that automatic combat is running.
                    let resumedAt = postedAt
                    stallAssessment = stallDetector.automaticBattleEnabled(
                        at: resumedAt,
                        context: automationBattleContext(for: preflight, identity: identity),
                        inputGeneration: inputGeneration
                    )
                    _ = allAutoProgressValidator.automaticBattleExpected(
                        at: resumedAt,
                        battleSessionID: battleID
                    )
                    _ = battleActivityProgressDetector.automaticBattleExpected(
                        at: resumedAt,
                        battleSessionID: battleID,
                        context: automationBattleContext(for: preflight, identity: identity),
                        inputGeneration: inputGeneration
                    )
                } else {
                    stallAssessment = stallDetector.reset()
                }

                if let beforeURL, let afterURL {
                    try writePNG(preflight.image, to: beforeURL)
                    try writePNG(after.image, to: afterURL)
                }
                let frameDifference = try FrameAnalyzer.meanAbsoluteDifferenceRGBA(
                    preflight.rgba.bytes,
                    after.rgba.bytes,
                    width: preflight.rgba.width,
                    height: preflight.rgba.height,
                    bytesPerRow: preflight.rgba.bytesPerRow
                )
                let captureDetail = afterURL.map { "after=\($0.path)" }
                    ?? "actionScreenshotsPersisted=false"
                try appendAutomationEvent(
                    kind: "actionPosted",
                    state: preflight.classification.state,
                    decision: String(describing: decision),
                    action: request.intent,
                    target: request.target,
                    frameFingerprint: preflight.fingerprint,
                    detail: "inputMode=\(inputMode.rawValue), captureLevel=\(captureLevel.rawValue), "
                        + "activationAttempts=\(activationRetry.currentAttempt), "
                        + "resultObservationFailures=\(resultObservationFailures), \(captureDetail), "
                        + "focusRestorationAfterPostCapture=\(inputMode == .foreground), "
                        + "meanAbsoluteDifference=\(frameDifference)",
                    screenshotPath: beforeURL?.path,
                    elapsed: after.capturedAt - startedAt,
                    report: &report,
                    reportURL: reportURL
                )
                // Reuse the already captured post-action frame as the controller's next input.
                // This shortens acknowledgement latency and gives the temporal detector its
                // earliest possible post-auto baseline without posting another event.
                currentObservation = after
                continue

            case let .stop(reason):
                let limitReached: Bool
                switch reason {
                case .maximumCyclesReached:
                    limitReached = true
                default:
                    limitReached = false
                }
                try finishAutomationRun(
                    status: limitReached ? "completed" : "stopped",
                    reason: String(describing: reason),
                    terminationKind: captureTerminationKind(for: reason),
                    observation: observation,
                    captureLevel: captureLevel,
                    captureRecorder: captureRecorder,
                    startedAt: startedAt,
                    directoryURL: directoryURL,
                    reportURL: reportURL,
                    report: &report
                )
                return
            }
        }
    }
}
