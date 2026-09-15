import CoreGraphics
import Foundation
import MirrorProbeCore
import ScreenCaptureKit

extension MirrorProbeRuntime {
    static func captureCharacterRerollObservation(
        requestedID: UInt32,
        expectedIdentity: AutoLevelWindowIdentity,
        expectedFrame: CGRect,
        minimumTotal: Int
    ) async throws -> CharacterRerollObservation {
        let window = try await selectMirrorWindow(requestedID: requestedID)
        guard let application = window.owningApplication,
              application.processID == expectedIdentity.processID,
              window.windowID == expectedIdentity.windowID
        else {
            throw ProbeError.unsafeWindow("the iPhone Mirroring process or window identity changed")
        }
        guard approximatelyEqual(window.frame, expectedFrame, tolerance: 0.5) else {
            throw ProbeError.unsafeWindow(
                "the iPhone Mirroring window moved or resized during character reroll"
            )
        }

        // The authorization age starts before ScreenCaptureKit reads the pixels. Measuring it
        // after Vision completes would make an old frame appear artificially fresh under load.
        let captureStartedAt = ProcessInfo.processInfo.systemUptime
        let image = try await capture(window: window)
        let rgba = try rgbaFrame(from: image)
        return try analyzeCharacterRerollObservation(
            image: image,
            rgba: rgba,
            window: window,
            capturedAt: captureStartedAt,
            minimumTotal: minimumTotal
        )
    }

    static func analyzeCharacterRerollObservation(
        image: CGImage,
        rgba: RGBAFrame,
        window: SCWindow,
        capturedAt: TimeInterval,
        minimumTotal: Int
    ) throws -> CharacterRerollObservation {
        let frameMetrics = try FrameAnalyzer.analyzeRGBA(
            rgba.bytes,
            width: rgba.width,
            height: rgba.height,
            bytesPerRow: rgba.bytesPerRow
        )
        guard !frameMetrics.isBlank else {
            throw ProbeError.unsafeWindow(
                "the character-reroll capture was blank, transparent, or nearly black"
            )
        }
        let observations = try recognizeText(in: image)
        let fullFrameResolution = CharacterFullFrameTotalResolver.resolve(
            observations: observations
        )
        let credibleFullFrameTotals: [Int]
        let fullFrameTotal: Int?
        let fullFrameWasContaminated: Bool
        switch fullFrameResolution {
        case let .exact(read):
            credibleFullFrameTotals = [read.value]
            fullFrameTotal = read.value
            fullFrameWasContaminated = false
        case let .contaminated(reads):
            credibleFullFrameTotals = reads.map(\.value)
            fullFrameTotal = nil
            fullFrameWasContaminated = true
        case .unavailable:
            credibleFullFrameTotals = []
            fullFrameTotal = nil
            fullFrameWasContaminated = false
        }
        // These independent reads run for every nonblank frame, even if an unrelated page anchor
        // fails. A credible high result therefore reaches the sticky boundary latch on its own.
        let focusedResolution = (try? focusedCharacterRerollTotalResolution(in: image))
            ?? .unavailable
        let credibleFocusedTotals: [Int]
        let focusedRead: CharacterFocusedTotalRead?
        let focusedWasContaminated: Bool
        switch focusedResolution {
        case let .exact(read):
            credibleFocusedTotals = [read.value]
            focusedRead = read
            focusedWasContaminated = false
        case let .contaminated(reads):
            credibleFocusedTotals = reads.map(\.value)
            focusedRead = nil
            focusedWasContaminated = true
        case .unavailable:
            credibleFocusedTotals = []
            focusedRead = nil
            focusedWasContaminated = false
        }
        let renderedDigitDetection = CharacterTotalDigitDetector.detectRGBA(
            rgba.bytes,
            width: rgba.width,
            height: rgba.height,
            bytesPerRow: rgba.bytesPerRow
        )
        let renderedDigitCount: Int?
        switch renderedDigitDetection {
        case let .digitCount(count):
            renderedDigitCount = count
        case .boundaryAmbiguous, .unsafe:
            renderedDigitCount = nil
        }
        let boundaryEvidence = CharacterTotalBoundaryEvidenceResolver.resolve(
            fullFrame: fullFrameResolution,
            focused: focusedResolution,
            renderedDigitDetection: renderedDigitDetection,
            minimumTotal: minimumTotal
        )
        var decision = CharacterRerollDetector.detect(
            observations: observations,
            minimumTotal: minimumTotal
        )
        switch decision {
        case .rerollRequired where boundaryEvidence != .belowThreshold:
            decision = .unsafe(
                reason: boundaryEvidence == .boundaryConflict
                    ? .totalBoundaryConflict
                    : renderedDigitCount == nil && focusedRead != nil
                        ? .totalGlyphDetectionFailed
                        : .totalCorroborationMismatch
            )
        case .thresholdReached where boundaryEvidence != .thresholdReached:
            decision = .unsafe(
                reason: boundaryEvidence == .boundaryConflict
                    ? .totalBoundaryConflict
                    : .totalCorroborationMismatch
            )
        default:
            break
        }
        return CharacterRerollObservation(
            capturedAt: capturedAt,
            window: window,
            decision: decision,
            boundaryEvidence: boundaryEvidence,
            credibleFullFrameTotals: credibleFullFrameTotals,
            credibleFocusedTotals: credibleFocusedTotals,
            fullFrameWasContaminated: fullFrameWasContaminated,
            focusedWasContaminated: focusedWasContaminated,
            fullFrameTotal: fullFrameTotal,
            focusedTotal: focusedRead?.value,
            renderedDigitCount: renderedDigitCount,
            image: image,
            rgba: rgba
        )
    }

    /// A focused Vision request presents only the total area. It must agree with full-frame OCR
    /// on digit count; rendered pixels independently guard the two-to-three digit boundary.
    static func focusedCharacterRerollTotalResolution(
        in image: CGImage
    ) throws -> CharacterFocusedTotalResolution {
        let totalRegion = CGRect(x: 0.72, y: 0.64, width: 0.27, height: 0.08)
        let observations = try recognizeText(
            in: image,
            regionOfInterest: totalRegion,
            minimumTextHeight: 0.01,
            languages: ["en-US"]
        )
        return CharacterFocusedTotalResolver.resolveEvidence(observations: observations)
    }

    static func stableCharacterRerollObservation(
        requestedID: UInt32,
        expectedIdentity: AutoLevelWindowIdentity,
        expectedFrame: CGRect,
        minimumTotal: Int,
        sessionDeadline: TimeInterval,
        stabilityTimeout: TimeInterval,
        stopURL: URL?
    ) async -> CharacterRerollStabilityOutcome {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let deadline = min(sessionDeadline, startedAt + stabilityTimeout)
        var prior: CharacterRerollObservation?
        var latest: CharacterRerollObservation?
        var lastUnsafeReason: CharacterRerollUnsafeReason?
        var boundaryLatch = CharacterTotalBoundaryLatch()
        var keeperOrConflictWasObserved = false

        do {
            while ProcessInfo.processInfo.systemUptime < deadline {
                if characterRerollStopRequested(stopURL) {
                    throw CharacterRerollInterruption.stopRequested
                }
                if ProcessInfo.processInfo.systemUptime >= sessionDeadline {
                    throw CharacterRerollInterruption.maximumRuntimeReached
                }
                let observation = try await captureCharacterRerollObservation(
                    requestedID: requestedID,
                    expectedIdentity: expectedIdentity,
                    expectedFrame: expectedFrame,
                    minimumTotal: minimumTotal
                )
                // Keep the latest screen before a boundary latch or stability comparison can stop
                // the routine, so callers can persist the actual terminal evidence.
                latest = observation
                if observation.boundaryEvidence == .thresholdReached
                    || observation.boundaryEvidence == .boundaryConflict
                {
                    keeperOrConflictWasObserved = true
                }
                if boundaryLatch.observe(observation.boundaryEvidence) == .terminalVeto {
                    throw ProbeError.unsafeWindow(
                        "conflicting total evidence reached or obscured the configured boundary; "
                            + "the snapshot is terminal and will not be retried"
                    )
                }
                switch observation.decision {
                case let .unsafe(reason):
                    lastUnsafeReason = reason
                    prior = nil
                case .rerollRequired:
                    if let prior,
                       characterRerollStableDecisionsMatch(
                           prior.decision,
                           observation.decision
                       ),
                       try characterRerollFramesAreQuiescent(prior.rgba, observation.rgba)
                    {
                        return .stable(observation)
                    }
                    prior = observation
                case .thresholdReached:
                    if let prior,
                       characterRerollStableDecisionsMatch(
                           prior.decision,
                           observation.decision
                       ),
                       try characterRerollFramesAreQuiescent(prior.rgba, observation.rgba)
                    {
                        return .stable(observation)
                    }
                    prior = observation
                }
                try await Task.sleep(for: .milliseconds(250))
            }

            if characterRerollStopRequested(stopURL) {
                throw CharacterRerollInterruption.stopRequested
            }
            if ProcessInfo.processInfo.systemUptime >= sessionDeadline {
                throw CharacterRerollInterruption.maximumRuntimeReached
            }
            let suffix = lastUnsafeReason.map { " (last detector result: \($0.rawValue))" } ?? ""
            throw ProbeError.unsafeWindow(
                "the custom-character page did not produce two matching safe snapshots\(suffix)"
            )
        } catch CharacterRerollInterruption.stopRequested {
            return .ended(
                latest: latest,
                keeperOrConflictWasObserved: keeperOrConflictWasObserved,
                reason: .stopRequested
            )
        } catch CharacterRerollInterruption.maximumRuntimeReached {
            return .ended(
                latest: latest,
                keeperOrConflictWasObserved: keeperOrConflictWasObserved,
                reason: .maximumRuntimeReached
            )
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            return .ended(
                latest: latest,
                keeperOrConflictWasObserved: keeperOrConflictWasObserved,
                reason: .failed(message)
            )
        }
    }

    static func awaitCharacterRerollAcknowledgement(
        previousObservation: CharacterRerollObservation,
        postedAt: TimeInterval,
        requestedID: UInt32,
        expectedIdentity: AutoLevelWindowIdentity,
        expectedFrame: CGRect,
        minimumTotal: Int,
        sessionDeadline: TimeInterval,
        acknowledgementTimeout: TimeInterval,
        stopURL: URL?
    ) async -> CharacterRerollAcknowledgementOutcome {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let deadline = min(sessionDeadline, startedAt + acknowledgementTimeout)
        // The local UI updates immediately in measured runs. Waiting well beyond that transition,
        // then requiring two pixel-quiescent result frames, prevents a staged name/total update
        // from authorizing the next click.
        let settleNotBefore = postedAt + 0.1
        var changedCandidate: CharacterRerollObservation?
        var latestPostClick: CharacterRerollObservation?
        var lastUnsafeReason: CharacterRerollUnsafeReason?
        var boundaryLatch = CharacterTotalBoundaryLatch()
        var keeperOrConflictWasObserved = false

        do {
            while ProcessInfo.processInfo.systemUptime < deadline {
                if characterRerollStopRequested(stopURL) {
                    throw CharacterRerollInterruption.stopRequested
                }
                if ProcessInfo.processInfo.systemUptime >= sessionDeadline {
                    throw CharacterRerollInterruption.maximumRuntimeReached
                }
                let now = ProcessInfo.processInfo.systemUptime
                if now < settleNotBefore {
                    try await Task.sleep(for: .milliseconds(250))
                    continue
                }
                let observation = try await captureCharacterRerollObservation(
                    requestedID: requestedID,
                    expectedIdentity: expectedIdentity,
                    expectedFrame: expectedFrame,
                    minimumTotal: minimumTotal
                )
                // Preserve the latest screen obtained after the posted action before any later
                // validation can terminate. Terminal reporting can then never masquerade the
                // pre-click character as the phone's latest observed state.
                latestPostClick = observation
                if observation.boundaryEvidence == .thresholdReached
                    || observation.boundaryEvidence == .boundaryConflict
                {
                    keeperOrConflictWasObserved = true
                }
                if boundaryLatch.observe(observation.boundaryEvidence) == .terminalVeto {
                    throw ProbeError.unsafeWindow(
                        "conflicting post-click total evidence reached or obscured the configured "
                            + "boundary; no further click is permitted"
                    )
                }
                switch observation.decision {
                case let .unsafe(reason):
                    lastUnsafeReason = reason
                    changedCandidate = nil
                case .rerollRequired:
                    let changeFromPreClick = try characterRerollResultDifference(
                        previousObservation.rgba,
                        observation.rgba
                    )
                    guard changeFromPreClick >= characterRerollMinimumChangedDifference else {
                        changedCandidate = nil
                        try await Task.sleep(for: .milliseconds(250))
                        continue
                    }
                    if let changedCandidate,
                       characterRerollStableDecisionsMatch(
                           changedCandidate.decision,
                           observation.decision
                       ),
                       try characterRerollFramesAreQuiescent(
                           changedCandidate.rgba,
                           observation.rgba
                       )
                    {
                        return .acknowledged(observation)
                    }
                    changedCandidate = observation
                case .thresholdReached:
                    let changeFromPreClick = try characterRerollResultDifference(
                        previousObservation.rgba,
                        observation.rgba
                    )
                    guard changeFromPreClick >= characterRerollMinimumChangedDifference else {
                        changedCandidate = nil
                        try await Task.sleep(for: .milliseconds(250))
                        continue
                    }
                    if let changedCandidate,
                       characterRerollStableDecisionsMatch(
                           changedCandidate.decision,
                           observation.decision
                       ),
                       try characterRerollFramesAreQuiescent(
                           changedCandidate.rgba,
                           observation.rgba
                       )
                    {
                        return .acknowledged(observation)
                    }
                    changedCandidate = observation
                }
                try await Task.sleep(for: .milliseconds(250))
            }

            if characterRerollStopRequested(stopURL) {
                throw CharacterRerollInterruption.stopRequested
            }
            if ProcessInfo.processInfo.systemUptime >= sessionDeadline {
                throw CharacterRerollInterruption.maximumRuntimeReached
            }
            let suffix = lastUnsafeReason.map { " (last detector result: \($0.rawValue))" } ?? ""
            throw ProbeError.unsafeWindow(
                "the Random click was not acknowledged by two settled, pixel-stable changed "
                    + "snapshots" + suffix
            )
        } catch CharacterRerollInterruption.stopRequested {
            return .ended(
                latestPostClick: latestPostClick,
                keeperOrConflictWasObserved: keeperOrConflictWasObserved,
                reason: .stopRequested
            )
        } catch CharacterRerollInterruption.maximumRuntimeReached {
            return .ended(
                latestPostClick: latestPostClick,
                keeperOrConflictWasObserved: keeperOrConflictWasObserved,
                reason: .maximumRuntimeReached
            )
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            return .ended(
                latestPostClick: latestPostClick,
                keeperOrConflictWasObserved: keeperOrConflictWasObserved,
                reason: .failed(message)
            )
        }
    }
}
