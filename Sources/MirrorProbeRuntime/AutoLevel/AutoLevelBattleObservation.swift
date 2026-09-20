import CoreGraphics
import Foundation
import MirrorProbeCore
import ScreenCaptureKit

extension MirrorProbeRuntime {
    static func automationBattleRecognitionSample(
        _ observation: AutomationObservation,
        identity: AutoLevelWindowIdentity,
        battleSessionID: String?,
        inputGeneration: UInt64
    ) -> BattleRecognitionRecoverySample {
        .init(
            classification: observation.classification,
            runtime: .init(
                observedAt: observation.capturedAt, windowIdentity: identity,
                frameFingerprint: observation.fingerprint, battleSessionID: battleSessionID
            ),
            context: automationBattleContext(for: observation, identity: identity),
            inputGeneration: inputGeneration
        )
    }

    static func automationBattleContext(
        for observation: AutomationObservation,
        identity: AutoLevelWindowIdentity
    ) -> BattleWindowContext {
        automationBattleContext(window: observation.window, rgba: observation.rgba, identity: identity)
    }

    static func automationBattleContext(
        window: SCWindow,
        rgba: RGBAFrame,
        identity: AutoLevelWindowIdentity
    ) -> BattleWindowContext {
        let frame = window.frame
        let scaleFactor = frame.width > 0
            ? Double(rgba.width) / Double(frame.width)
            : 1
        return BattleWindowContext(
            processID: identity.processID,
            windowID: identity.windowID,
            originX: Double(frame.origin.x),
            originY: Double(frame.origin.y),
            width: rgba.width,
            height: rgba.height,
            scaleFactor: scaleFactor
        )
    }

    static func automationBattleRegionDifference(
        previous: AutomationTemporalFrame?,
        current: AutomationObservation,
        context: BattleWindowContext,
        inputGeneration: UInt64
    ) throws -> Double? {
        guard let previous,
              previous.context == context,
              previous.inputGeneration == inputGeneration,
              previous.rgba.width == current.rgba.width,
              previous.rgba.height == current.rgba.height,
              previous.rgba.bytesPerRow == current.rgba.bytesPerRow
        else {
            return nil
        }
        return try automationBattlePixelDifference(previous.rgba, current.rgba)
    }

    static func automationBattlePixelDifference(
        _ previous: RGBAFrame,
        _ current: RGBAFrame
    ) throws -> Double? {
        guard previous.width == current.width,
              previous.height == current.height,
              previous.bytesPerRow == current.bytesPerRow
        else { return nil }
        return try FrameAnalyzer.meanAbsoluteDifferenceRGBA(
            previous.bytes,
            current.bytes,
            width: current.width,
            height: current.height,
            bytesPerRow: current.bytesPerRow,
            region: BattleStallDetector.battleROI
        )
    }

    static func automationActionFrameDifference(
        before: RGBAFrame,
        after: RGBAFrame,
        continuityUnchanged: Bool
    ) throws -> Double? {
        guard continuityUnchanged,
              before.width == after.width,
              before.height == after.height,
              before.bytesPerRow == after.bytesPerRow
        else { return nil }
        return try FrameAnalyzer.meanAbsoluteDifferenceRGBA(
            before.bytes, after.bytes, width: before.width, height: before.height,
            bytesPerRow: before.bytesPerRow
        )
    }

    /// A bounded capture-only burst. Visual classification runs at the two boundaries;
    /// fast frames establish pixel continuity. No focus or input is used.
    static func confirmAutomationVisualStability(
        _ initialConfirmation: BattleVisualStabilityConfirmation,
        anchor: AutomationObservation,
        identity: AutoLevelWindowIdentity,
        expectedFrame: CGRect,
        inputGeneration: UInt64,
        sessionDeadline: TimeInterval?,
        stopURL: URL,
        captureRecorder: AutomationCaptureRecorder,
        windowRecovery: AutomationWindowRecoveryContext
    ) async throws -> AutomationVisualConfirmationResult {
        var confirmation = initialConfirmation
        var previous = anchor.rgba
        let burstDeadline = ProcessInfo.processInfo.systemUptime + 7
        func interruption() -> AutomationCaptureInterruption? {
            if applicationStopRequest.isRequested(stopFileURL: stopURL) { return .stopRequested }
            if let sessionDeadline, ProcessInfo.processInfo.systemUptime >= sessionDeadline {
                return .sessionExpired
            }
            return nil
        }
        while !confirmation.isComplete {
            if let reason = interruption() { return .interrupted(reason) }
            try await Task.sleep(for: .milliseconds(400))
            if let reason = interruption() { return .interrupted(reason) }
            let frame = try await captureAutomationFrame(
                requestedID: identity.windowID,
                expectedIdentity: identity,
                expectedFrame: expectedFrame,
                recovery: windowRecovery,
                phase: "densePixels"
            )
            if let reason = interruption() { return .interrupted(reason) }
            if frame.windowContinuityGeneration != anchor.windowContinuityGeneration {
                let fresh = try recognizeAutomationFrame(frame, captureRecorder: captureRecorder)
                return .rejected(fresh, detail: "windowAvailabilityInterruptedPixelContinuity")
            }
            let context = automationBattleContext(window: frame.window, rgba: frame.rgba, identity: identity)
            let previousDifference = try automationBattlePixelDifference(previous, frame.rgba)
            let anchorDifference = try automationBattlePixelDifference(anchor.rgba, frame.rgba)
            let accepted = confirmation.observe(
                monotonicTime: frame.capturedAt,
                context: context,
                inputGeneration: inputGeneration,
                differenceFromPrevious: previousDifference,
                differenceFromAnchor: anchorDifference
            )
            guard accepted, frame.capturedAt <= burstDeadline else {
                let observation = try recognizeAutomationFrame(frame, captureRecorder: captureRecorder)
                return .rejected(observation, detail: "pixelChangeOrSampleDiscontinuity, "
                    + "previousMAD=\(previousDifference.map(String.init(describing:)) ?? "unavailable"), "
                    + "anchorMAD=\(anchorDifference.map(String.init(describing:)) ?? "unavailable")")
            }
            previous = frame.rgba
        }
        if let reason = interruption() { return .interrupted(reason) }
        let final = try await captureAutomationObservation(
            requestedID: identity.windowID,
            expectedIdentity: identity,
            expectedFrame: expectedFrame,
            captureRecorder: captureRecorder,
            recovery: windowRecovery,
            phase: "denseFinalVisual"
        )
        if let reason = interruption() { return .interrupted(reason) }
        guard final.windowContinuityGeneration == anchor.windowContinuityGeneration else {
            return .rejected(final, detail: "windowAvailabilityInterruptedFinalContinuity")
        }
        let finalSample = BattleStallSample(
            monotonicTime: final.capturedAt,
            context: automationBattleContext(for: final, identity: identity),
            battleScreenConfirmed: final.classification.state == .battle,
            modalPresent: isAutomationModal(final.classification.state),
            paused: !VisualBattleEvidence.hasRunningBattleEvidence(in: final.classification),
            inputGeneration: inputGeneration,
            frameEvidence: final.stallEvidence,
            battleROIDifferenceFromPrevious: try automationBattlePixelDifference(previous, final.rgba)
        )
        guard let assessment = confirmation.validate(
            finalSample,
            differenceFromAnchor: try automationBattlePixelDifference(anchor.rgba, final.rgba)
        ) else {
            return .rejected(final, detail: "finalBattleClassificationOrContinuityLost")
        }
        return .confirmed(confirmation, final, assessment)
    }

    static func isAutomationModal(_ state: GameState) -> Bool {
        switch state {
        case .battleEncounterPrompt, .battleEventPrompt, .defeatPrompt,
             .retreatConfirmation, .lootCollectionConfirmation,
             .adventurerRecruitment, .missionComplete,
             .missionCompleteRepeatSelected, .missionFailed,
             .missionFailedRepeatSelected, .wideModalOneButton,
             .wideModalTwoButtons, .inventoryFull:
            return true
        case .battle, .defeat, .unknown:
            return false
        }
    }

    static func automationStallDetail(
        _ assessment: BattleStallAssessment
    ) -> String {
        let reset = assessment.resetReason?.rawValue ?? "none"
        return "stallPhase=\(assessment.phase.rawValue), armed=\(assessment.isArmed), "
            + "stableSeconds=\(assessment.stableDuration), samples=\(assessment.stableSampleCount), "
            + "strictBattleBackground=\(assessment.strictBattleBackground), reset=\(reset)"
    }
}
