import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
@testable import MirrorProbeCore

@Suite("Graphical battle progress without OCR")
struct VisualBattleActivityProgressTests {
    @Test("The original consecutive battle captures establish real HP/log progress without parsed numbers")
    func nativeProgressPairArmsMonitoring() throws {
        // auto-level-20260911-051142.zV14EU: capture-0013 -> capture-0014, elapsed
        // 15.535 -> 17.336 seconds. Same battle; combat log and upper-middle party HP change.
        let before = try fixture("visual-battle-progress-before",
                                 sha256: "febbe8f6b0b028c8aa83b79f51b51e3f3d7eb834753a652448e6a36dadd2ce74")
        let after = try fixture("visual-battle-progress-after",
                                sha256: "29c94d7410b0ad6560f28fc06b48316bfe7206ee0967b98a8e60a4f511918333")
        #expect(before.width == 406 && before.height == 890)
        let beforeClassification = try classify(before), afterClassification = try classify(after)
        #expect(beforeClassification.state == .battle && afterClassification.state == .battle)
        let first = try evidence(before, classification: beforeClassification)
        let second = try evidence(after, classification: afterClassification)
        #expect(first.hpReadings.isEmpty && second.hpReadings.isEmpty)
        #expect(first.combatLogSignature.isEmpty && second.combatLogSignature.isEmpty)
        let firstVisual = try #require(first.visualActivity)
        let secondVisual = try #require(second.visualActivity)
        #expect(secondVisual.hasSignificantChange(from: firstVisual))
        let difference = try difference(before, after)
        #expect(difference > 0.002)
        var detector = activated()
        #expect(detector.observe(sample(first, at: 1, difference: nil)) == .awaitingEvidence)
        #expect(detector.observe(sample(second, at: 2.801, difference: difference)) == .progressObserved)

        let stallEvidence = BattleStallFrameEvidence.extractVisual(from: afterClassification)
        #expect(stallEvidence.background.isStrict)
        #expect(stallEvidence.background.visualControlsConfirmed == true)
        #expect(stallEvidence.background.lootCandidates == 0 && stallEvidence.background.trustedLootAnchors == 0)
        #expect(stallEvidence.enemyHP == nil && stallEvidence.partyHP.isEmpty)
        #expect(stallEvidence.combatLogSignature.isEmpty)
        #expect(!stallEvidence.hasCompleteDefeatCandidateEvidence)
        var stall = BattleStallDetector(configuration: .init(
            suspectedAfter: 3, confirmedAfter: 5, maximumSampleGap: 2, minimumStableSampleCount: 5
        ))
        _ = stall.markVerifiedNormalBattleProgress(at: 3, context: context, inputGeneration: 7)
        let baseline = stallSample(stallEvidence, at: 4)
        #expect(stall.observe(baseline).phase == .monitoring)
        var confirmation = try #require(stall.beginVisualConfirmation(from: baseline))
        for time in 5...9 {
            let accepted = confirmation.observe(
                monotonicTime: Double(time), context: context, inputGeneration: 7,
                differenceFromPrevious: 0, differenceFromAnchor: 0
            )
            #expect(accepted)
        }
        #expect(confirmation.isComplete)
        #expect(confirmation.validate(stallSample(stallEvidence, at: 10), differenceFromAnchor: 0)?.phase == .confirmed)
        let changedInput = BattleStallSample(
            monotonicTime: 11, context: context, battleScreenConfirmed: true,
            modalPresent: false, paused: false, inputGeneration: 8,
            frameEvidence: stallEvidence, battleROIDifferenceFromPrevious: 0
        )
        #expect(confirmation.validate(changedInput, differenceFromAnchor: 0) == nil)
        #expect(confirmation.validate(stallSample(stallEvidence, at: 12), differenceFromAnchor: 0) == nil)
    }

    @Test("Unchanged pixels and small pixel noise do not produce acknowledgement-quality activity")
    func frozenAndNoisyFramesDoNotArmProgress() throws {
        let baseline = try fixture("visual-battle-progress-before")
        let classification = try classify(baseline)
        let first = try evidence(baseline, classification: classification)
        var noisy = baseline
        for offset in stride(from: 0, to: noisy.bytes.count, by: 4) {
            for channel in 0..<3 {
                let delta = ((offset / 4 + channel) % 2 == 0) ? 2 : -2
                noisy.bytes[offset + channel] = UInt8(clamping: Int(noisy.bytes[offset + channel]) + delta)
            }
        }
        for candidate in [baseline, noisy] {
            var detector = activated()
            _ = detector.observe(sample(first, at: 1, difference: nil))
            // Even unrelated large scene movement cannot upgrade unchanged/noisy HP/log data.
            let current = try evidence(candidate, classification: classification)
            #expect(detector.observe(sample(current, at: 2, difference: 0.2)) == .awaitingEvidence)
        }
    }

    @Test("Uniform brightness shifts are not structural changes in HP or combat-log content")
    func brightnessShiftIsRejected() throws {
        let width = 406, height = 890
        func flat(_ luminance: UInt8) -> [UInt8] {
            var bytes = [UInt8](repeating: luminance, count: width * height * 4)
            for offset in stride(from: 3, to: bytes.count, by: 4) { bytes[offset] = 255 }
            return bytes
        }
        let before = try VisualBattleActivityEvidence.extractRGBA(flat(100), width: width,
                                                                  height: height, bytesPerRow: width * 4)
        let after = try VisualBattleActivityEvidence.extractRGBA(flat(120), width: width,
                                                                 height: height, bytesPerRow: width * 4)
        #expect(!after.hasSignificantChange(from: before))
    }

    @Test("Clock, enemy sprite, and right-control changes cannot replace HP/log progress")
    func unrelatedRegionsAreExcluded() throws {
        let baseline = try fixture("visual-battle-progress-before")
        let classification = try classify(baseline)
        let first = try evidence(baseline, classification: classification)
        let excludedRegions: [NormalizedRect] = [
            .init(x: 0.08, y: 0.045, width: 0.80, height: 0.040),
            .init(x: 0.05, y: 0.15, width: 0.90, height: 0.45),
            .init(x: 0.80, y: 0.62, width: 0.17, height: 0.075),
        ]
        for region in excludedRegions {
            var changed = baseline
            fill(&changed, region: region, luminance: 20)
            let current = try evidence(changed, classification: classification)
            var detector = activated()
            _ = detector.observe(sample(first, at: 1, difference: nil))
            #expect(detector.observe(sample(current, at: 2, difference: 0.2)) == .awaitingEvidence)
        }
    }

    @Test("Footer skill brightness is excluded from both gameplay stability and local progress")
    func blinkingFooterCannotChangeGameplayEvidence() throws {
        let baseline = try fixture("visual-battle-progress-before")
        let classification = try classify(baseline)
        var changed = baseline
        // Pixel rows begin after the gameplay crop's ceil-rounded exclusive boundary.
        let firstFooterRow = Int(ceil(0.86 * Double(changed.height)))
        for y in firstFooterRow..<changed.height {
            for x in 0..<changed.width {
                let offset = y * changed.bytesPerRow + x * 4
                for channel in 0..<3 {
                    changed.bytes[offset + channel] = 255 - changed.bytes[offset + channel]
                }
            }
        }
        #expect(try difference(baseline, changed) == 0)
        let beforeActivity = try evidence(baseline, classification: classification)
        let afterActivity = try evidence(changed, classification: classification)
        #expect(beforeActivity.visualActivity == afterActivity.visualActivity)
        var detector = activated()
        _ = detector.observe(sample(beforeActivity, at: 1, difference: nil))
        #expect(detector.observe(sample(afterActivity, at: 2, difference: 0)) == .awaitingEvidence)
    }

    @Test("A real local activity change still requires whole-battle pixel corroboration")
    func wholeBattleCorroborationRemainsMandatory() throws {
        let before = try fixture("visual-battle-progress-before")
        let after = try fixture("visual-battle-progress-after")
        let first = try evidence(before, classification: classify(before))
        let second = try evidence(after, classification: classify(after))
        for difference: Double? in [nil, 0, 0.002] {
            var detector = activated()
            _ = detector.observe(sample(first, at: 1, difference: nil))
            #expect(detector.observe(sample(second, at: 2, difference: difference)) == .awaitingEvidence)
        }
    }

    @Test("A missing footer or retreat anchor and modal never provide a temporal baseline")
    func incompleteOrModalClassificationFailsClosed() throws {
        let frame = try fixture("visual-battle-progress-before")
        let baseline = try classify(frame)
        let requiredIndices = baseline.evidence.indices.filter {
            baseline.evidence[$0].battleVisualMatch?.marker != .pauseControl
        }
        var variants = requiredIndices.map { removed in
            GameStateClassification(state: .battle,
                                    evidence: baseline.evidence.enumerated().filter { $0.offset != removed }.map(\.element),
                                    allowedActions: baseline.allowedActions,
                                    policyGatedActions: baseline.policyGatedActions)
        }
        variants += [
            .init(state: .wideModalOneButton, evidence: [], allowedActions: []),
            .init(state: .unknown, evidence: [], allowedActions: []),
        ]
        for classification in variants {
            let activity = try evidence(frame, classification: classification)
            #expect(!activity.hasStrictBattleBackground && activity.visualActivity == nil)
            #expect(activity.hpReadings.isEmpty && activity.combatLogSignature.isEmpty)
            let stall = BattleStallFrameEvidence.extractVisual(from: classification)
            #expect(!stall.background.isStrict)
            #expect(stall.enemyHP == nil && stall.partyHP.isEmpty && stall.combatLogSignature.isEmpty)
            var detector = activated()
            #expect(detector.observe(sample(activity, at: 1, difference: 0.2)) == .awaitingEvidence)
        }
    }

    @Test("An unmatched pause control does not erase battle progress or gated retreat evidence")
    func pauseProofIsSeparateFromActivity() throws {
        let frame = try fixture("visual-battle-progress-before")
        let baseline = try classify(frame)
        let withoutPause = GameStateClassification(
            state: .battle,
            evidence: baseline.evidence.filter { $0.battleVisualMatch?.marker != .pauseControl },
            allowedActions: [], policyGatedActions: baseline.policyGatedActions
        )
        #expect(VisualBattleEvidence.hasRunningBattleEvidence(in: withoutPause))
        #expect(VisualBattleEvidence.hasTrustedRetreat(in: withoutPause))
        let activity = try evidence(frame, classification: withoutPause)
        #expect(activity.hasStrictBattleBackground && activity.visualActivity != nil)
        let stall = BattleStallFrameEvidence.extractVisual(from: withoutPause)
        #expect(stall.background.isStrict && stall.background.visualControlsConfirmed == true)
        #expect(stall.background.lootCandidates == 0 && stall.background.trustedLootAnchors == 0)
        #expect(stall.background.pauseCandidates == 0 && stall.background.trustedPauseAnchors == 0)
        #expect(stall.background.retreatCandidates == 1 && stall.background.trustedRetreatAnchors == 1)
        #expect(stall.enemyHP == nil && stall.partyHP.isEmpty && stall.combatLogSignature.isEmpty)
    }

    @Test("Visual progress cannot cross session, window, input, or capture-time boundaries")
    func continuityGuardsRemainMandatory() throws {
        let before = try fixture("visual-battle-progress-before")
        let after = try fixture("visual-battle-progress-after")
        let first = try evidence(before, classification: classify(before))
        let second = try evidence(after, classification: classify(after))
        let changedContext = BattleWindowContext(processID: 124, windowID: 17, originX: 0, originY: 30,
                                                 width: 406, height: 890)
        let invalidSamples = [
            sample(second, at: 2, difference: 0.2, battleID: "another-battle"),
            sample(second, at: 2, difference: 0.2, sampleContext: changedContext),
            sample(second, at: 2, difference: 0.2, generation: 8),
            sample(second, at: 1, difference: 0.2),
            sample(second, at: .nan, difference: 0.2),
        ]
        for invalid in invalidSamples {
            var detector = activated()
            _ = detector.observe(sample(first, at: 1, difference: nil))
            #expect(detector.observe(invalid) == .inactive)
            #expect(detector.observe(sample(second, at: 3, difference: 0.2)) == .inactive)
        }
        var gap = activated()
        _ = gap.observe(sample(first, at: 1, difference: nil))
        #expect(gap.observe(sample(second, at: 12, difference: 0.2)) == .awaitingEvidence)
    }

    @Test("Visual and legacy OCR signatures cannot combine to manufacture progress")
    func differentEvidenceProvenanceDoesNotCombine() throws {
        let frame = try fixture("visual-battle-progress-before")
        let visual = try evidence(frame, classification: classify(frame))
        let legacy = BattleActivityFrameEvidence(hasStrictBattleBackground: true, hpReadings: [],
                                                 combatLogSignature: "old OCR text")
        for (first, second) in [(legacy, visual), (visual, legacy)] {
            var detector = activated()
            _ = detector.observe(sample(first, at: 1, difference: nil))
            #expect(detector.observe(sample(second, at: 2, difference: 0.2)) == .awaitingEvidence)
        }
    }

    @Test("Invalid, truncated, and transparent activity buffers fail closed")
    func malformedPixelBuffersAreRejected() throws {
        for (width, height, stride) in [(0, 890, 0), (199, 436, 796), (406, 399, 1624),
                                        (600, 600, 2400), (10_001, 890, 40_004),
                                        (406, 10_001, 1624), (406, 890, Int.max), (406, 890, 1623)] {
            #expect(throws: VisualBattleActivityError.invalidDimensions) {
                try VisualBattleActivityEvidence.extractRGBA([], width: width, height: height, bytesPerRow: stride)
            }
        }
        #expect(throws: VisualBattleActivityError.insufficientBytes) {
            try VisualBattleActivityEvidence.extractRGBA([0], width: 406, height: 890, bytesPerRow: 1624)
        }
        var frame = try fixture("visual-battle-progress-before")
        let classification = try classify(frame)
        for offset in stride(from: 3, to: frame.bytes.count, by: 4) { frame.bytes[offset] = 0 }
        #expect(throws: VisualBattleActivityError.transparentActivityRegion) {
            try evidence(frame, classification: classification)
        }
    }

    private var context: BattleWindowContext {
        .init(processID: 123, windowID: 17, originX: 0, originY: 30, width: 406, height: 890)
    }

    private func activated() -> BattleActivityProgressDetector {
        var detector = BattleActivityProgressDetector()
        _ = detector.automaticBattleExpected(at: 0, battleSessionID: "battle-1", context: context, inputGeneration: 7)
        return detector
    }

    private func sample(_ evidence: BattleActivityFrameEvidence, at time: Double, difference: Double?,
                        battleID: String = "battle-1", sampleContext: BattleWindowContext? = nil,
                        generation: UInt64 = 7) -> BattleActivityProgressSample {
        .init(monotonicTime: time, battleSessionID: battleID, context: sampleContext ?? context,
              inputGeneration: generation, evidence: evidence, battleROIDifferenceFromPrevious: difference)
    }

    private func stallSample(_ evidence: BattleStallFrameEvidence, at time: Double) -> BattleStallSample {
        .init(monotonicTime: time, context: context, battleScreenConfirmed: true, modalPresent: false,
              paused: false, inputGeneration: 7, frameEvidence: evidence, battleROIDifferenceFromPrevious: 0)
    }

    private func evidence(_ frame: Frame, classification: GameStateClassification) throws -> BattleActivityFrameEvidence {
        try .extractVisual(frame.bytes, width: frame.width, height: frame.height,
                           bytesPerRow: frame.bytesPerRow, classification: classification)
    }

    private func classify(_ frame: Frame) throws -> GameStateClassification {
        try VisualBattleDetector.classifyRGBA(frame.bytes, width: frame.width,
                                              height: frame.height, bytesPerRow: frame.bytesPerRow)
    }

    private func difference(_ before: Frame, _ after: Frame) throws -> Double {
        try FrameAnalyzer.meanAbsoluteDifferenceRGBA(before.bytes, after.bytes, width: before.width,
                                                     height: before.height, bytesPerRow: before.bytesPerRow,
                                                     region: BattleStallDetector.battleROI)
    }

    private func fixture(_ name: String, sha256: String? = nil) throws -> Frame {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "png"))
        if let sha256 {
            let actual = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
            #expect(actual == sha256)
        }
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

    private func fill(_ frame: inout Frame, region: NormalizedRect, luminance: UInt8) {
        let minX = Int(floor(region.x * Double(frame.width)))
        let maxX = Int(ceil((region.x + region.width) * Double(frame.width)))
        let minY = Int(floor(region.y * Double(frame.height)))
        let maxY = Int(ceil((region.y + region.height) * Double(frame.height)))
        for y in minY..<maxY {
            for x in minX..<maxX {
                let offset = y * frame.bytesPerRow + x * 4
                for channel in 0..<3 { frame.bytes[offset + channel] = luminance }
            }
        }
    }

    private struct Frame {
        var bytes: [UInt8]
        let width: Int
        let height: Int
        var bytesPerRow: Int { width * 4 }
    }
}
