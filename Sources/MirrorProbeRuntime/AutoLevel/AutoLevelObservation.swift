import CoreGraphics
import Foundation
import MirrorProbeCore

extension MirrorProbeRuntime {
    static func captureAutomationObservation(
        requestedID: UInt32,
        expectedIdentity: AutoLevelWindowIdentity,
        expectedFrame: CGRect,
        captureRecorder: AutomationCaptureRecorder,
        recovery: AutomationWindowRecoveryContext,
        phase: String,
        deadline: AutomationCaptureDeadline? = nil
    ) async throws -> AutomationObservation {
        let frame = try await captureAutomationFrame(
            requestedID: requestedID,
            expectedIdentity: expectedIdentity,
            expectedFrame: expectedFrame,
            recovery: recovery,
            phase: phase,
            deadline: deadline
        )
        let observation = try recognizeAutomationFrame(frame, captureRecorder: captureRecorder)
        try recovery.checkSessionBoundary()
        return observation
    }

    static func captureAutomationFrame(
        requestedID: UInt32,
        expectedIdentity: AutoLevelWindowIdentity,
        expectedFrame: CGRect,
        recovery: AutomationWindowRecoveryContext,
        phase: String,
        deadline: AutomationCaptureDeadline? = nil
    ) async throws -> AutomationCapturedFrame {
        let window = try await selectAutomationWindow(
            requestedID: requestedID, expectedIdentity: expectedIdentity,
            expectedFrame: expectedFrame, recovery: recovery,
            phase: phase, deadline: deadline
        )
        guard let application = window.owningApplication,
              application.processID == expectedIdentity.processID,
              window.windowID == expectedIdentity.windowID
        else {
            throw ProbeError.unsafeWindow("the iPhone Mirroring process or window identity changed")
        }
        let acceptedFrame = recovery.currentFrame ?? expectedFrame
        guard approximatelyEqual(window.frame, acceptedFrame, tolerance: 0.5) else {
            throw ProbeError.unsafeWindow(
                "the iPhone Mirroring window moved or resized before capture; phase=\(phase), "
                    + "expectedFrame=\(acceptedFrame), actualFrame=\(window.frame)"
            )
        }
        let image = try await capture(window: window)
        try recovery.checkSessionBoundary()
        let capturedAt = ProcessInfo.processInfo.systemUptime
        let rgba = try rgbaFrame(from: image)
        recovery.recordCaptureLayout(
            width: rgba.width, height: rgba.height, bytesPerRow: rgba.bytesPerRow
        )
        let frameMetrics = try FrameAnalyzer.analyzeRGBA(
            rgba.bytes,
            width: rgba.width,
            height: rgba.height,
            bytesPerRow: rgba.bytesPerRow
        )
        guard !frameMetrics.isBlank else {
            throw ProbeError.unsafeWindow("the automation capture was blank, transparent, or nearly black")
        }
        return AutomationCapturedFrame(
            capturedAt: capturedAt,
            windowContinuityGeneration: recovery.generation,
            window: window,
            image: image,
            rgba: rgba,
            metrics: frameMetrics
        )
    }

    static func recognizeAutomationFrame(
        _ frame: AutomationCapturedFrame,
        captureRecorder: AutomationCaptureRecorder
    ) throws -> AutomationObservation {
        let recognitionStartedAt = ProcessInfo.processInfo.systemUptime
        let classification = try recognizeGameState(in: frame.image, rgba: frame.rgba)
        let stallEvidence = BattleStallFrameEvidence.extractVisual(from: classification)
        let activityEvidence = try BattleActivityFrameEvidence.extractVisual(
            frame.rgba.bytes, width: frame.rgba.width, height: frame.rgba.height,
            bytesPerRow: frame.rgba.bytesPerRow, classification: classification
        )
        let fingerprint = sha256Hex(of: Data(frame.rgba.bytes))
        let observation = AutomationObservation(
            capturedAt: frame.capturedAt,
            recognitionDurationSeconds: ProcessInfo.processInfo.systemUptime - recognitionStartedAt,
            windowContinuityGeneration: frame.windowContinuityGeneration,
            window: frame.window,
            image: frame.image,
            rgba: frame.rgba,
            metrics: frame.metrics,
            stallEvidence: stallEvidence,
            activityEvidence: activityEvidence,
            classification: classification,
            fingerprint: fingerprint
        )
        captureRecorder.record(observation)
        return observation
    }
}
