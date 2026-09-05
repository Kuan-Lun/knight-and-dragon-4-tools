import Testing
@testable import MirrorProbeCore

@Suite("Dense battle visual stability confirmation")
struct BattleVisualStabilityConfirmationTests {
    @Test("Dense samples need five seconds and fresh OCR before confirming recovery")
    func confirmsDenseStableCaptures() throws {
        var confirmation = try makeConfirmation()
        #expect(confirmation.stableDuration == 0)
        #expect(confirmation.stableSampleCount == 1)
        for time in [2.0, 3, 4, 5] {
            #expect(observe(&confirmation, at: time))
            #expect(!confirmation.isComplete)
        }
        #expect(confirmation.stableSampleCount == 5)
        #expect(observe(&confirmation, at: 6))
        #expect(confirmation.isComplete)
        #expect(confirmation.stableDuration == 5)

        let validation = confirmation.validate(sample(at: 6.5), differenceFromAnchor: 0)
        let result = try #require(validation)
        #expect(result.phase == .confirmed)
        #expect(result.isArmed)
        #expect(result.strictBattleBackground)
        #expect(result.stableDuration == 5.5)
        #expect(result.stableSampleCount == 7)
        // Verified visual stability deliberately does not depend on complete HP OCR.
        #expect(result.enemyHP == nil)
        #expect(result.zeroPartyMembers == 0)
    }

    @Test("Elapsed time alone cannot replace the minimum number of captured samples")
    func rejectsTooFewSamples() throws {
        var confirmation = try makeConfirmation()
        #expect(observe(&confirmation, at: 3.5))
        #expect(observe(&confirmation, at: 6))
        #expect(confirmation.stableDuration == 5)
        #expect(!confirmation.isComplete)
        let tooFew = confirmation.validate(sample(at: 6.5), differenceFromAnchor: 0)
        #expect(tooFew == nil)
        #expect(confirmation.stableSampleCount == 4)
        let sufficient = confirmation.validate(sample(at: 7), differenceFromAnchor: 0)
        #expect(sufficient?.isConfirmedEvidence == true)
    }

    @Test("A stricter configured duration and sample count remain binding")
    func respectsStricterConfiguration() throws {
        var configuration = denseConfiguration
        configuration.confirmedAfter = 8
        configuration.minimumStableSampleCount = 10
        var confirmation = try makeConfirmation(configuration: configuration)
        for time in 2...9 {
            #expect(observe(&confirmation, at: Double(time)))
            #expect(!confirmation.isComplete)
        }
        #expect(observe(&confirmation, at: 10))
        #expect(confirmation.isComplete)
    }

    @Test("A weaker configuration cannot lower the five-second and five-sample floor")
    func preservesMinimumConfirmationFloor() throws {
        let configuration = BattleStallConfiguration(
            suspectedAfter: 1, confirmedAfter: 2, maximumSampleGap: 3,
            maximumStableROIDifference: 0.002, minimumStableSampleCount: 2
        )
        var confirmation = try makeConfirmation(configuration: configuration)
        for time in [2.0, 3, 4, 5] {
            #expect(observe(&confirmation, at: time))
            #expect(!confirmation.isComplete)
        }
        #expect(observe(&confirmation, at: 6))
        #expect(confirmation.isComplete)
    }

    @Test("Fixed-anchor comparison rejects gradual movement hidden by adjacent comparisons")
    func rejectsCumulativeDrift() throws {
        var confirmation = try makeConfirmation()
        #expect(observe(&confirmation, at: 2, previous: 0.0007, anchor: 0.0007))
        #expect(observe(&confirmation, at: 3, previous: 0.0007, anchor: 0.0014))
        #expect(!observe(&confirmation, at: 4, previous: 0.0007, anchor: 0.0021))
        #expect(!confirmation.isComplete)
        #expect(!observe(&confirmation, at: 5))
    }

    @Test("Sudden motion in either comparison permanently revokes even completed evidence")
    func rejectsMotionAfterCompletion() throws {
        for differences in [(0.003, 0.0), (0.0, 0.003)] {
            var confirmation = try completedConfirmation()
            #expect(!observe(
                &confirmation, at: 7, previous: differences.0, anchor: differences.1
            ))
            #expect(!confirmation.isComplete)
            #expect(confirmation.stableDuration == 0)
            #expect(confirmation.stableSampleCount == 0)
            let revalidation = confirmation.validate(sample(at: 8), differenceFromAnchor: 0)
            #expect(revalidation == nil)
        }
    }

    @Test("Missing, negative and non-finite differences never count as stability")
    func rejectsInvalidDifferences() throws {
        let invalidValues: [Double?] = [nil, -0.001, .nan, .infinity, -.infinity]
        for invalid in invalidValues {
            var previousInvalid = try makeConfirmation()
            #expect(!observe(&previousInvalid, at: 2, previous: invalid))
            #expect(!observe(&previousInvalid, at: 3))
            var anchorInvalid = try makeConfirmation()
            #expect(!observe(&anchorInvalid, at: 2, anchor: invalid))
            #expect(!observe(&anchorInvalid, at: 3))
        }
    }

    @Test("Sparse, repeated, reversed and non-finite capture times permanently invalidate")
    func rejectsInvalidCaptureTimes() throws {
        for invalidTime in [4.001, 1.0, 0.5, -1.0, Double.nan, .infinity, -.infinity] {
            var confirmation = try makeConfirmation()
            #expect(!observe(&confirmation, at: invalidTime))
            #expect(!observe(&confirmation, at: 2))
        }
        var exactBoundary = try makeConfirmation()
        #expect(observe(&exactBoundary, at: 4))
        #expect(!exactBoundary.isComplete)
    }

    @Test("An unarmed or merely assumed-automatic battle cannot issue a confirmation")
    func requiresVerifiedBattleProgress() {
        var detector = BattleStallDetector(configuration: denseConfiguration)
        #expect(detector.beginVisualConfirmation(from: sample(at: 1)) == nil)
        _ = detector.automaticBattleEnabled(at: 0, context: context, inputGeneration: 7)
        #expect(detector.beginVisualConfirmation(from: sample(at: 1)) == nil)
        _ = detector.markVerifiedNormalBattleProgress(at: 1, context: context, inputGeneration: 7)
        #expect(detector.beginVisualConfirmation(from: sample(at: 1)) != nil)
        #expect(detector.beginVisualConfirmation(from: sample(at: 0.5)) == nil)
        _ = detector.observe(sample(at: 2))
        #expect(detector.beginVisualConfirmation(from: sample(at: 1.5)) == nil)
        _ = detector.reset()
        #expect(detector.beginVisualConfirmation(from: sample(at: 3)) == nil)
    }

    @Test("Both issuing and validating evidence reject modal, paused, unknown or incomplete screens")
    func requiresFreshTrustedBattleClassification() throws {
        let detector = armedDetector()
        let invalidSamples = [
            sample(at: 7, modal: true),
            sample(at: 7, paused: true),
            sample(at: 7, battle: false),
            sample(at: 7, strict: false),
        ]
        for invalidSample in invalidSamples {
            #expect(detector.beginVisualConfirmation(from: invalidSample) == nil)
            var confirmation = try completedConfirmation()
            let invalid = confirmation.validate(invalidSample, differenceFromAnchor: 0)
            #expect(invalid == nil)
            #expect(!confirmation.isComplete)
            let revalidation = confirmation.validate(sample(at: 8), differenceFromAnchor: 0)
            #expect(revalidation == nil)
        }
    }

    @Test("Window context and input generation remain bound through issuing, pixels and preflight")
    func bindsContextAndGeneration() throws {
        let changedContext = BattleWindowContext(
            processID: 123, windowID: 17, originX: 1, originY: 30, width: 406, height: 890
        )
        let detector = armedDetector()
        #expect(detector.beginVisualConfirmation(from: sample(at: 1, context: changedContext)) == nil)
        #expect(detector.beginVisualConfirmation(from: sample(at: 1, generation: 8)) == nil)

        var changedPixels = try makeConfirmation()
        let changedPixelsAccepted = changedPixels.observe(
            monotonicTime: 2, context: changedContext, inputGeneration: 7,
            differenceFromPrevious: 0, differenceFromAnchor: 0
        )
        #expect(!changedPixelsAccepted)
        #expect(!observe(&changedPixels, at: 3))
        var changedGeneration = try makeConfirmation()
        let changedGenerationAccepted = changedGeneration.observe(
            monotonicTime: 2, context: context, inputGeneration: 8,
            differenceFromPrevious: 0, differenceFromAnchor: 0
        )
        #expect(!changedGenerationAccepted)
        #expect(!observe(&changedGeneration, at: 3))

        for changedSample in [
            sample(at: 7, context: changedContext), sample(at: 7, generation: 8),
        ] {
            var confirmation = try completedConfirmation()
            let invalid = confirmation.validate(changedSample, differenceFromAnchor: 0)
            #expect(invalid == nil)
            let revalidation = confirmation.validate(sample(at: 8), differenceFromAnchor: 0)
            #expect(revalidation == nil)
        }
    }

    @Test("Final OCR confirmation remains valid only while the later retreat preflight is stable")
    func revokesAtChangedPreflight() throws {
        var confirmation = try completedConfirmation()
        let finalOCR = confirmation.validate(sample(at: 6.5), differenceFromAnchor: 0)
        #expect(finalOCR?.isConfirmedEvidence == true)
        let stablePreflight = confirmation.validate(sample(at: 7), differenceFromAnchor: 0)
        #expect(stablePreflight?.isConfirmedEvidence == true)
        let changedPreflight = confirmation.validate(sample(at: 8, difference: 0.02), differenceFromAnchor: 0.02)
        #expect(changedPreflight == nil)
        let revalidation = confirmation.validate(sample(at: 9), differenceFromAnchor: 0)
        #expect(revalidation == nil)
    }

    @Test("Reprocessing an old image and waiting through a preflight gap cannot refresh proof")
    func requiresNewTimelyPreflightCapture() throws {
        for captureTime in [6.0, 9.001] {
            var confirmation = try completedConfirmation()
            let invalid = confirmation.validate(sample(at: captureTime), differenceFromAnchor: 0)
            #expect(invalid == nil)
            let revalidation = confirmation.validate(sample(at: 10), differenceFromAnchor: 0)
            #expect(revalidation == nil)
        }
    }

    private let context = BattleWindowContext(
        processID: 123, windowID: 17, originX: 0, originY: 30, width: 406, height: 890
    )

    private var denseConfiguration: BattleStallConfiguration {
        BattleStallConfiguration(
            suspectedAfter: 3, confirmedAfter: 5, maximumSampleGap: 3,
            maximumStableROIDifference: 0.002, minimumStableSampleCount: 5
        )
    }

    private func armedDetector(
        configuration: BattleStallConfiguration? = nil
    ) -> BattleStallDetector {
        var detector = BattleStallDetector(configuration: configuration ?? denseConfiguration)
        _ = detector.markVerifiedNormalBattleProgress(at: 0, context: context, inputGeneration: 7)
        return detector
    }

    private func makeConfirmation(
        configuration: BattleStallConfiguration? = nil
    ) throws -> BattleVisualStabilityConfirmation {
        try #require(armedDetector(configuration: configuration).beginVisualConfirmation(from: sample(at: 1)))
    }

    private func completedConfirmation() throws -> BattleVisualStabilityConfirmation {
        var confirmation = try makeConfirmation()
        for time in [2.0, 3, 4, 5, 6] {
            #expect(observe(&confirmation, at: time))
        }
        #expect(confirmation.isComplete)
        return confirmation
    }

    private func observe(
        _ confirmation: inout BattleVisualStabilityConfirmation,
        at time: Double,
        previous: Double? = 0,
        anchor: Double? = 0
    ) -> Bool {
        confirmation.observe(
            monotonicTime: time, context: context, inputGeneration: 7,
            differenceFromPrevious: previous, differenceFromAnchor: anchor
        )
    }

    private func sample(
        at time: Double,
        difference: Double? = 0,
        modal: Bool = false,
        paused: Bool = false,
        battle: Bool = true,
        strict: Bool = true,
        generation: UInt64 = 7,
        context: BattleWindowContext? = nil
    ) -> BattleStallSample {
        BattleStallSample(
            monotonicTime: time, context: context ?? self.context,
            battleScreenConfirmed: battle, modalPresent: modal, paused: paused,
            inputGeneration: generation,
            frameEvidence: BattleStallFrameEvidence(
                background: BattleStallBackgroundEvidence(
                    lootCandidates: 1, trustedLootAnchors: 1,
                    pauseCandidates: 1, trustedPauseAnchors: 1,
                    retreatCandidates: 1, trustedRetreatAnchors: strict ? 1 : 0,
                    automaticCandidates: 1, trustedAutomaticAnchors: 1
                ),
                enemyHP: nil, partyHP: [], combatLogSignature: ""
            ),
            battleROIDifferenceFromPrevious: difference
        )
    }
}
