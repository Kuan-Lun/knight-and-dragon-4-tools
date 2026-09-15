import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
@testable import MirrorProbeCore

@Suite("Already-frozen startup battle saved-image regression")
struct StartupFrozenBattleRegressionTests {
    @Test("The eight retained captures show trusted, stable battle pixels without normal progress")
    func originalCaptureSequenceRemainsFrozen() throws {
        let sequence = try sequence()
        #expect(sequence.originalActionsPosted == 0)
        #expect(sequence.originalCompletedCycles == 0)
        #expect(sequence.frames.map(\.captureSequence) == Array(13...20))
        #expect(Set(sequence.frames.map(\.pngSHA256)).count == 2)
        let firstCapture = try #require(sequence.frames.first)
        let lastCapture = try #require(sequence.frames.last)
        #expect(firstCapture.capturedAtElapsedSeconds == 19.475316416705027)
        #expect(lastCapture.capturedAtElapsedSeconds == 30.725790791679174)
        // Error retention kept only the final 11.25 seconds. Do not fabricate the missing
        // captures or count the time before the first saved image as proven stability.
        #expect(lastCapture.capturedAtElapsedSeconds - firstCapture.capturedAtElapsedSeconds < 30)

        var progress = BattleActivityProgressDetector()
        progress.automaticBattleExpected(
            at: sequence.originalSessionStartedAtElapsedSeconds,
            battleSessionID: sequence.battleSessionID, context: context, inputGeneration: 0
        )
        var normalStall = BattleStallDetector()
        _ = normalStall.automaticBattleEnabled(
            at: sequence.originalSessionStartedAtElapsedSeconds, context: context, inputGeneration: 0
        )
        let anchor = try fixture(firstCapture)
        #expect(anchor.width == 406 && anchor.height == 890)
        var previous: Frame?
        var previousActivity: VisualBattleActivityEvidence?
        var previousTime: Double?
        var changedCaptureSequences: [Int] = []

        for capture in sequence.frames {
            let frame = try fixture(capture)
            let classification = try classify(frame)
            #expect(classification.state == .battle)
            #expect(VisualBattleEvidence.hasRunningBattleEvidence(in: classification))
            #expect(VisualBattleEvidence.hasTrustedRetreat(in: classification))
            let activity = try evidence(frame, classification: classification)
            #expect(activity.hasStrictBattleBackground)
            #expect(activity.hpReadings.isEmpty && activity.combatLogSignature.isEmpty)
            let visualActivity = try #require(activity.visualActivity)
            let fromAnchor = try difference(anchor, frame)
            #expect(fromAnchor <= normalStall.configuration.maximumStableROIDifference)
            let fromPrevious = try previous.map { try difference($0, frame) }
            if let fromPrevious, let previous, let previousActivity, let previousTime {
                #expect(fromPrevious <= normalStall.configuration.maximumStableROIDifference)
                #expect(!visualActivity.hasSignificantChange(from: previousActivity))
                #expect(capture.capturedAtElapsedSeconds > previousTime)
                #expect(capture.capturedAtElapsedSeconds - previousTime < 2)
                if try difference(previous, frame, region: fullFrame) > 0 {
                    changedCaptureSequences.append(capture.captureSequence)
                    // The real transition has small changes throughout the image; it is
                    // stable under the measured threshold, not an identical-pixel claim.
                    #expect(fromPrevious > 0)
                }
            }
            let progressSample = BattleActivityProgressSample(
                monotonicTime: capture.capturedAtElapsedSeconds,
                battleSessionID: sequence.battleSessionID, context: context, inputGeneration: 0,
                evidence: activity, battleROIDifferenceFromPrevious: fromPrevious
            )
            let progressAssessment = progress.observe(progressSample)
            #expect(progressAssessment == .awaitingEvidence)

            let stallEvidence = BattleStallFrameEvidence.extractVisual(from: classification)
            #expect(stallEvidence.background.isStrict)
            #expect(stallEvidence.background.trustedRetreatAnchors == 1)
            #expect(stallEvidence.enemyHP == nil && stallEvidence.partyHP.isEmpty)
            #expect(stallEvidence.combatLogSignature.isEmpty)
            #expect(!stallEvidence.hasCompleteDefeatCandidateEvidence)
            let stallSample = BattleStallSample(
                monotonicTime: capture.capturedAtElapsedSeconds, context: context,
                battleScreenConfirmed: true, modalPresent: false, paused: false,
                inputGeneration: 0, frameEvidence: stallEvidence,
                battleROIDifferenceFromPrevious: fromPrevious
            )
            // This incident must not weaken the normal stall detector's progress prerequisite.
            #expect(normalStall.beginVisualConfirmation(from: stallSample) == nil)
            let normalAssessment = normalStall.observe(stallSample)
            #expect(!normalAssessment.isArmed)
            previous = frame
            previousActivity = visualActivity
            previousTime = capture.capturedAtElapsedSeconds
        }
        #expect(changedCaptureSequences == [18])
    }

    @Test("A labeled simulated continuation confirms startup recovery, retreats and repeats once")
    func simulatedContinuationRetreatsAndRepeats() throws {
        let sequence = try sequence()
        let firstCapture = try #require(sequence.frames.first)
        let lastCapture = try #require(sequence.frames.last)
        let firstFrame = try fixture(firstCapture)
        let lastFrame = try fixture(lastCapture)
        let lastClassification = try classify(lastFrame)
        let configuration = BattleStallConfiguration(
            suspectedAfter: 3, confirmedAfter: 5, maximumSampleGap: 3,
            maximumStableROIDifference: 0.002, minimumStableSampleCount: 5
        )
        var startup = try #require(StartupBattleRecovery(
            sample: stallSample(classification: classify(firstFrame),
                                at: firstCapture.capturedAtElapsedSeconds, difference: nil),
            battleSessionID: sequence.battleSessionID, configuration: configuration
        ))
        var previous = firstFrame
        // First replay the retained originals at their real capture times. Their 11.25 seconds
        // cannot authorize recovery or stand in for the missing beginning of the source run.
        for capture in sequence.frames.dropFirst() {
            let frame = try fixture(capture)
            let sample = try stallSample(classification: classify(frame),
                                         at: capture.capturedAtElapsedSeconds,
                                         difference: difference(previous, frame))
            let accepted = startup.observe(sample, battleSessionID: sequence.battleSessionID,
                                           genuineProgressObserved: false)
            #expect(accepted)
            let prematureConfirmation = startup.beginVisualConfirmation(
                from: sample, battleSessionID: sequence.battleSessionID
            )
            #expect(prematureConfirmation == nil)
            #expect(startup.isEligible)
            previous = frame
        }

        // Everything below is a simulated future extension, never a claim about unretained
        // startup frames or live recovery. Reuse the final frozen pixels at new model times.
        var simulatedTime = lastCapture.capturedAtElapsedSeconds
        let earliestConfirmationTime = firstCapture.capturedAtElapsedSeconds + 30
        var latest = stallSample(classification: lastClassification, at: simulatedTime, difference: 0)
        while simulatedTime < earliestConfirmationTime {
            simulatedTime = min(simulatedTime + 1.5, earliestConfirmationTime)
            latest = stallSample(classification: lastClassification, at: simulatedTime,
                                 difference: try difference(lastFrame, lastFrame))
            let accepted = startup.observe(latest, battleSessionID: sequence.battleSessionID,
                                           genuineProgressObserved: false)
            #expect(accepted)
        }
        let issuedConfirmation = startup.beginVisualConfirmation(
            from: latest, battleSessionID: sequence.battleSessionID
        )
        var confirmation = try #require(issuedConfirmation)
        #expect(!startup.isEligible)
        #expect(confirmation.stableDuration == 0)
        #expect(confirmation.stableSampleCount == 1)
        #expect(!confirmation.isComplete)
        for second in 1...5 {
            let accepted = confirmation.observe(
                monotonicTime: simulatedTime + Double(second), context: context, inputGeneration: 0,
                differenceFromPrevious: try difference(lastFrame, lastFrame),
                differenceFromAnchor: try difference(lastFrame, lastFrame)
            )
            #expect(accepted)
        }
        #expect(confirmation.isComplete)
        let preflightTime = simulatedTime + 5.25
        let preflightClassification = try classify(lastFrame)
        let validated = confirmation.validate(
            stallSample(classification: preflightClassification, at: preflightTime, difference: 0),
            differenceFromAnchor: try difference(lastFrame, lastFrame)
        )
        let confirmed = try #require(validated)
        #expect(confirmed.isConfirmedEvidence)
        #expect(confirmed.stableDuration >= 5 && confirmed.stableSampleCount >= 5)

        let identity = AutoLevelWindowIdentity(processID: context.processID, windowID: context.windowID)
        var controller = AutoLevelController(
            session: .init(sessionID: "simulated-startup-recovery", startedAt: 0, windowIdentity: identity),
            policy: .init(actionCooldown: 0)
        )
        let retreat = try action(controller.consume(AutoLevelSnapshot(
            classification: preflightClassification,
            runtime: .init(observedAt: preflightTime, windowIdentity: identity,
                           frameFingerprint: lastCapture.frameFingerprint,
                           battleSessionID: sequence.battleSessionID,
                           allAutoStatus: .active, battleStatus: .stalledAfterDefeat)
        )))
        #expect(retreat.intent == .requestRetreat)
        #expect(retreat.target.rect == VisualBattleEvidence.measuredRetreatRect)
        let retreatPosted = controller.markActionPosted(retreat, at: preflightTime + 0.1)
        #expect(retreatPosted)

        // These result PNGs come from other recorded runs and model possible next screens;
        // the incident stopped before any input and therefore has no original result capture.
        let failed = try classifyAll(fixture(
            name: "retreat-direct-failure-final",
            sha256: "d4da130eb5367737d1d6a77b85188e1d9d937cead2f2319fa34102f61d5546c7"
        ))
        #expect(failed.state == .missionFailed)
        let failureSnapshot = AutoLevelSnapshot(
            classification: failed,
            runtime: .init(observedAt: preflightTime + 1, windowIdentity: identity,
                           frameFingerprint: "simulated-other-run-failure")
        )
        let failureDecision = controller.consume(failureSnapshot, allowNewActions: false)
        #expect(failureDecision == .completedCycle(.init(count: 1, outcome: .failure)))
        #expect(controller.pendingActionAcknowledgementDeadline == nil)
        let retreatReposted = controller.markActionPosted(retreat, at: preflightTime + 1.1)
        #expect(!retreatReposted)
        let repeatRequest = try action(controller.consume(failureSnapshot))
        #expect(repeatRequest.intent == .selectMissionRepeat)
        #expect(repeatRequest.target == AutoLevelActionTarget(try #require(failed.allowedActions.first).target))
        let repeatPosted = controller.markActionPosted(repeatRequest, at: preflightTime + 1.1)
        #expect(repeatPosted)

        let selected = try classifyAll(fixture(
            name: "visual-result-failure-selected",
            sha256: "ce886bbe93319de612a0399d6783a506286136188aca234ceec7da31e33e6ec2"
        ))
        #expect(selected.state == .missionFailedRepeatSelected)
        let advance = try action(controller.consume(AutoLevelSnapshot(
            classification: selected,
            runtime: .init(observedAt: preflightTime + 2, windowIdentity: identity,
                           frameFingerprint: "simulated-other-run-repeat-selected")
        )))
        #expect(advance.intent == .advanceMissionFailure)
        let advancePosted = controller.markActionPosted(advance, at: preflightTime + 2.1)
        #expect(advancePosted)
        let nextBattleDecision = controller.consume(AutoLevelSnapshot(
            classification: lastClassification,
            runtime: .init(observedAt: preflightTime + 3, windowIdentity: identity,
                           frameFingerprint: lastCapture.frameFingerprint,
                           battleSessionID: "simulated-next-battle", allAutoStatus: .active)
        ))
        #expect(nextBattleDecision == .wait(.battleInProgress))
        #expect(controller.completedCycles == 1)
        #expect(controller.actionsIssued == 3)
        #expect(controller.pendingActionAcknowledgementDeadline == nil)
    }

    @Test("Clock and skill-tray changes in the incident frame cannot manufacture battle progress")
    func incidentalRegionsRemainExcluded() throws {
        let sequence = try sequence()
        let capture = try #require(sequence.frames.first)
        let before = try fixture(capture)
        let firstActivity = try evidence(before, classification: classify(before))
        let firstVisual = try #require(firstActivity.visualActivity)
        // These variants are deliberately synthetic and are not extra recorded captures.
        let excludedRegions: [NormalizedRect] = [
            .init(x: 0.08, y: 0.05, width: 0.18, height: 0.03),
            .init(x: 0.04, y: 0.90, width: 0.90, height: 0.045),
        ]
        for region in excludedRegions {
            var changed = before
            invert(&changed, region: region)
            let classification = try classify(changed)
            #expect(classification.state == .battle)
            #expect(VisualBattleEvidence.hasTrustedRetreat(in: classification))
            let changedActivity = try evidence(changed, classification: classification)
            let changedVisual = try #require(changedActivity.visualActivity)
            #expect(try difference(before, changed, region: fullFrame) > 0)
            #expect(try difference(before, changed) == 0)
            #expect(changedVisual == firstVisual)
            #expect(!changedVisual.hasSignificantChange(from: firstVisual))
        }
    }

    private var context: BattleWindowContext {
        .init(processID: 91507, windowID: 65194, originX: 0, originY: 30, width: 406, height: 890)
    }

    private var fullFrame: NormalizedRect { .init(x: 0, y: 0, width: 1, height: 1) }

    private func sequence() throws -> CaptureSequence {
        let url = try #require(Bundle.module.url(forResource: "startup-frozen-battle-sequence", withExtension: "json"))
        return try JSONDecoder().decode(CaptureSequence.self, from: Data(contentsOf: url))
    }

    private func classify(_ frame: Frame) throws -> GameStateClassification {
        try VisualBattleDetector.classifyRGBA(frame.bytes, width: frame.width,
                                              height: frame.height, bytesPerRow: frame.bytesPerRow)
    }

    private func classifyAll(_ frame: Frame) throws -> GameStateClassification {
        try AutoLevelVisualClassifier.classifyRGBA(frame.bytes, width: frame.width,
                                                   height: frame.height, bytesPerRow: frame.bytesPerRow)
    }

    private func stallSample(classification: GameStateClassification, at time: Double,
                             difference: Double?) -> BattleStallSample {
        .init(monotonicTime: time, context: context, battleScreenConfirmed: classification.state == .battle,
              modalPresent: false, paused: false, inputGeneration: 0,
              frameEvidence: .extractVisual(from: classification), battleROIDifferenceFromPrevious: difference)
    }

    private func action(_ decision: AutoLevelDecision) throws -> AutoLevelActionRequest {
        guard case let .requestAction(request) = decision else {
            Issue.record("Expected action, got \(decision)")
            throw FixtureError.expectedAction
        }
        return request
    }

    private func evidence(_ frame: Frame, classification: GameStateClassification) throws -> BattleActivityFrameEvidence {
        try .extractVisual(frame.bytes, width: frame.width, height: frame.height,
                           bytesPerRow: frame.bytesPerRow, classification: classification)
    }

    private func difference(_ before: Frame, _ after: Frame, region: NormalizedRect? = nil) throws -> Double {
        try FrameAnalyzer.meanAbsoluteDifferenceRGBA(
            before.bytes, after.bytes, width: before.width, height: before.height,
            bytesPerRow: before.bytesPerRow, region: region ?? BattleStallDetector.battleROI
        )
    }

    private func fixture(_ capture: Capture) throws -> Frame {
        try fixture(name: capture.fixture, sha256: capture.pngSHA256)
    }

    private func fixture(name: String, sha256: String) throws -> Frame {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "png"))
        let actual = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        #expect(actual == sha256)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var frame = Frame(bytes: [UInt8](repeating: 0, count: image.width * image.height * 4),
                          width: image.width, height: image.height)
        let width = frame.width, height = frame.height, bytesPerRow = frame.bytesPerRow
        let rendered = frame.bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                                              | CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        #expect(rendered)
        return frame
    }

    private func invert(_ frame: inout Frame, region: NormalizedRect) {
        let minX = Int(floor(region.x * Double(frame.width)))
        let maxX = Int(ceil((region.x + region.width) * Double(frame.width)))
        let minY = Int(floor(region.y * Double(frame.height)))
        let maxY = Int(ceil((region.y + region.height) * Double(frame.height)))
        for y in minY..<maxY {
            for x in minX..<maxX {
                let offset = y * frame.bytesPerRow + x * 4
                for channel in 0..<3 { frame.bytes[offset + channel] = 255 - frame.bytes[offset + channel] }
            }
        }
    }

    private struct CaptureSequence: Decodable {
        let battleSessionID: String
        let originalSessionStartedAtElapsedSeconds: Double
        let originalActionsPosted: Int
        let originalCompletedCycles: Int
        let frames: [Capture]
    }

    private struct Capture: Decodable {
        let captureSequence: Int
        let capturedAtElapsedSeconds: Double
        let fixture: String
        let pngSHA256: String
        let frameFingerprint: String
    }

    private enum FixtureError: Error { case expectedAction }

    private struct Frame {
        var bytes: [UInt8]
        let width: Int
        let height: Int
        var bytesPerRow: Int { width * 4 }
    }
}
