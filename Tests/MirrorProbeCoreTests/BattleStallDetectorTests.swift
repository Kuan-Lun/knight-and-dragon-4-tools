import Testing
@testable import MirrorProbeCore

@Suite("Natural defeat stall detector")
struct BattleStallDetectorTests {
    @Test("HP parser accepts complete measured values and rejects guesses")
    func hpParsingIsFailClosed() {
        #expect(BattleHitPoints.parse("0/9046") == hp(0, 9_046))
        #expect(BattleHitPoints.parse("7128/14K") == hp(7_128, 14_000))
        #expect(BattleHitPoints.parse("423,789/701K") == hp(423_789, 701_000))
        #expect(BattleHitPoints.parse("1/1.5M") == hp(1, 1_500_000))

        for malformed in ["/9046", "0/", "0/90O6", "0/9046x", "-1/9046", "9047/9046"] {
            #expect(BattleHitPoints.parse(malformed) == nil)
        }
    }

    @Test("The measured natural-defeat OCR yields strict, complete evidence")
    func measuredNaturalDefeatEvidenceExtraction() throws {
        let evidence = BattleStallFrameEvidence.extract(from: measuredFrame03Observations())

        #expect(evidence.background.isStrict)
        #expect(evidence.enemyHP == hp(423_789, 701_000))
        #expect(evidence.partyHP == [
            hp(7_128, 14_000), hp(0, 9_046), hp(0, 3_727),
            hp(0, 3_103), hp(0, 2_043), hp(0, 2_871),
        ])
        #expect(evidence.zeroPartyMembers == 5)
        #expect(!evidence.combatLogSignature.isEmpty)
        #expect(evidence.hasCompleteDefeatCandidateEvidence)
    }

    @Test("The measured low-confidence loot anchor remains strict and fails below its floor")
    func measuredLootConfidenceUsesDedicatedFloor() {
        let observations = measuredFrame03Observations()
        let measured = observations.map { observation in
            observation.text == "戰利品"
                ? OCRTextObservation(
                    text: observation.text,
                    rect: observation.rect,
                    confidence: 0.30000001192092896
                )
                : observation
        }
        let belowFloor = observations.map { observation in
            observation.text == "戰利品"
                ? OCRTextObservation(
                    text: observation.text,
                    rect: observation.rect,
                    confidence: 0.299
                )
                : observation
        }

        #expect(BattleStallFrameEvidence.extract(from: measured).background.isStrict)
        #expect(!BattleStallFrameEvidence.extract(from: belowFloor).background.isStrict)
    }

    @Test("The measured truncated loot header supports freeze detection with or without talismans")
    func measuredTruncatedLootHeaderSupportsVisualFreeze() {
        let measured = measuredTruncatedLootObservations()
        for observations in [measured, measured.filter { !$0.text.contains("護符") }] {
            let classification = GameStateClassifier.classify(observations: observations)
            let evidence = BattleStallFrameEvidence.extract(from: observations)
            #expect(classification.state == .battle)
            #expect(evidence.background.isStrict)

            var detector = fiveSecondVisualDetector()
            _ = detector.markVerifiedNormalBattleProgress(
                at: 0,
                context: context,
                inputGeneration: 7
            )
            for time in [1.0, 2.5, 4.0, 5.5] {
                #expect(!detector.observe(sample(
                    at: time,
                    evidence: evidence,
                    difference: time == 1 ? nil : 0,
                    battleScreenConfirmed: classification.state == .battle
                )).isConfirmedEvidence)
            }
            let confirmed = detector.observe(sample(at: 6, evidence: evidence, difference: 0))
            #expect(confirmed.isConfirmedEvidence)
            #expect(confirmed.stableDuration == 5)
            #expect(confirmed.stableSampleCount == 5)
        }
    }

    @Test("Truncated loot requires its own confidence floor and exact header region")
    func truncatedLootConfidenceAndLocationFailClosed() {
        let measured = measuredTruncatedLootObservations()
        let rejectedLoot = [
            observation("利品", 0.874, 0.117, 0.062, 0.013, 0.499),
            observation("利品", 0.60, 0.117, 0.062, 0.013, 1),
            observation("利品", 0.874, 0.30, 0.062, 0.013, 1),
            observation("利品", 0.874, 0.06, 0.062, 0.013, 1),
            observation("品", 0.874, 0.117, 0.062, 0.013, 1),
            observation("戰品", 0.874, 0.117, 0.062, 0.013, 1),
            observation("獲得利品", 0.874, 0.117, 0.062, 0.013, 1),
        ]
        for replacement in rejectedLoot {
            let observations = measured.map { $0.text == "利品" ? replacement : $0 }
            #expect(!BattleStallFrameEvidence.extract(from: observations).background.isStrict)
        }
    }

    @Test("Full and truncated loot readings share one global uniqueness requirement")
    func duplicateTruncatedLootFailsClosed() {
        let measured = measuredTruncatedLootObservations()
        for duplicate in [
            observation("利品", 0.874, 0.117, 0.062, 0.013, 1),
            observation("戰利品6", 0.833, 0.108, 0.103, 0.016, 0.30),
            observation("利品", 0.10, 0.40, 0.062, 0.013, 0.10),
        ] {
            let evidence = BattleStallFrameEvidence.extract(from: measured + [duplicate])
            #expect(evidence.background.lootCandidates == 2)
            #expect(!evidence.background.isStrict)
        }
    }

    @Test("Truncated loot cannot replace any other trusted unique battle control")
    func truncatedLootPreservesOtherAnchorRequirements() throws {
        let measured = measuredTruncatedLootObservations()
        for (name, confidence) in [("暫停", 0.499), ("撤退", 0.499), ("全部自動", 0.599)] {
            let original = try #require(measured.first { $0.text == name })
            let lowConfidence = measured.map {
                $0.text == name
                    ? OCRTextObservation(text: $0.text, rect: $0.rect, confidence: confidence)
                    : $0
            }
            let misplaced = measured.map {
                $0.text == name ? observation(name, 0.45, 0.35, 0.10, 0.02, 1) : $0
            }
            for observations in [
                measured.filter { $0.text != name },
                measured + [original],
                lowConfidence,
                misplaced,
            ] {
                #expect(!BattleStallFrameEvidence.extract(from: observations).background.isStrict)
            }
        }
    }

    @Test("The measured 0.50 pause remains strict and fails below its local floor")
    func measuredPauseConfidenceUsesDedicatedFloor() {
        let observations = measuredFrame03Observations()
        let measured = observations.map { observation in
            observation.text == "暫停"
                ? OCRTextObservation(
                    text: observation.text,
                    rect: observation.rect,
                    confidence: 0.50
                )
                : observation
        }
        let belowFloor = observations.map { observation in
            observation.text == "暫停"
                ? OCRTextObservation(
                    text: observation.text,
                    rect: observation.rect,
                    confidence: 0.499
                )
                : observation
        }

        #expect(BattleStallFrameEvidence.extract(from: measured).background.isStrict)
        #expect(!BattleStallFrameEvidence.extract(from: belowFloor).background.isStrict)
    }

    @Test("Missing, truncated, or duplicate party HP is incomplete")
    func ambiguousPartyHPFailsClosed() {
        let complete = measuredFrame03Observations()
        let missing = complete.filter { $0.text != "0/9046" }
        let truncated = complete.map {
            $0.text == "0/9046"
                ? observation("/9046", $0.rect.x, $0.rect.y, $0.rect.width, $0.rect.height, $0.confidence)
                : $0
        }
        let duplicate = complete + [
            observation("0/9046", 0.55, 0.746, 0.10, 0.014, 1),
        ]

        #expect(BattleStallFrameEvidence.extract(from: missing).partyHP.isEmpty)
        #expect(BattleStallFrameEvidence.extract(from: truncated).partyHP.isEmpty)
        #expect(BattleStallFrameEvidence.extract(from: duplicate).partyHP.isEmpty)
    }

    @Test("A stalled-looking battle never arms before automatic mode and real progress")
    func unarmedStallDoesNotTrigger() {
        var detector = BattleStallDetector()
        let candidate = defeatEvidence(log: "same")

        #expect(detector.observe(sample(at: 1, evidence: candidate, difference: nil)).phase == .inactive)
        #expect(detector.automaticBattleEnabled(at: 2, context: context, inputGeneration: 7).phase == .awaitingProgress)
        #expect(detector.observe(sample(at: 3, evidence: candidate, difference: nil)).phase == .awaitingProgress)
        #expect(detector.observe(sample(at: 35, evidence: candidate, difference: 0)).phase == .awaitingProgress)
        #expect(detector.observe(sample(at: 65, evidence: candidate, difference: 0)).phase == .awaitingProgress)
    }

    @Test("Invalid configuration fails closed instead of trapping")
    func invalidConfigurationFailsClosed() {
        var detector = BattleStallDetector(configuration: BattleStallConfiguration(
            suspectedAfter: 60,
            confirmedAfter: 30
        ))
        let result = detector.automaticBattleEnabled(
            at: 0,
            context: context,
            inputGeneration: 7
        )

        #expect(result.phase == .inactive)
        #expect(result.resetReason == .invalidSample)
    }

    @Test("An uncorroborated OCR log change is not accepted as genuine progress")
    func logOCRNoiseDoesNotArm() {
        var detector = BattleStallDetector()
        _ = detector.automaticBattleEnabled(at: 0, context: context, inputGeneration: 7)
        let first = healthyEvidence(enemyCurrent: 600_000, log: "attack l")
        let ocrVariant = healthyEvidence(enemyCurrent: 600_000, log: "attack 1")

        _ = detector.observe(sample(at: 1, evidence: first, difference: nil))
        let result = detector.observe(sample(at: 3, evidence: ocrVariant, difference: 0))

        #expect(result.phase == .awaitingProgress)
        #expect(!result.isArmed)
        #expect(result.resetReason == nil)
    }

    @Test("An uncorroborated OCR HP change is not accepted as genuine progress")
    func hpOCRNoiseDoesNotArm() {
        var detector = BattleStallDetector()
        _ = detector.automaticBattleEnabled(at: 0, context: context, inputGeneration: 7)

        _ = detector.observe(sample(
            at: 1,
            evidence: healthyEvidence(enemyCurrent: 600_000, log: "attack 1"),
            difference: nil
        ))
        let noise = detector.observe(sample(
            at: 2,
            evidence: healthyEvidence(enemyCurrent: 550_000, log: "attack 1"),
            difference: 0
        ))

        #expect(noise.phase == .awaitingProgress)
        #expect(!noise.isArmed)
        #expect(noise.resetReason == nil)
        #expect(detector.progressResumeState == nil)

        let corroborated = detector.observe(sample(
            at: 3,
            evidence: healthyEvidence(enemyCurrent: 500_000, log: "attack 1"),
            difference: 0.03
        ))
        #expect(corroborated.phase == .monitoring)
        #expect(corroborated.isArmed)
        #expect(corroborated.resetReason == .battleProgress)
        #expect(detector.progressResumeState != nil)
    }

    @Test("An armed detector tolerates incomplete HP OCR and can resume without counting the gap")
    func armedProgressResumesAfterIncompleteOCR() throws {
        var detector = armedDetectorBeforeDefeat()
        let resumeState = try #require(detector.progressResumeState)
        let incomplete = BattleStallFrameEvidence(
            background: strictBackground,
            enemyHP: nil,
            partyHP: [],
            combatLogSignature: ""
        )

        let continued = detector.observe(sample(at: 3, evidence: incomplete, difference: 0))
        #expect(continued.phase == .monitoring)
        #expect(continued.resetReason == nil)
        #expect(continued.isArmed)
        #expect(detector.progressResumeState != nil)

        _ = detector.reset(reason: .incompleteBattleEvidence)
        let resumed = detector.resumeMonitoring(
            from: resumeState,
            at: 3,
            context: context,
            inputGeneration: 7
        )
        #expect(resumed.phase == .monitoring)
        #expect(resumed.isArmed)
        #expect(resumed.stableDuration == 0)
        #expect(resumed.stableSampleCount == 0)

        let terminal = defeatEvidence(log: "final log")
        let baseline = detector.observe(sample(at: 10, evidence: terminal, difference: 0.04))
        let suspected = detector.observe(sample(at: 40, evidence: terminal, difference: 0))
        let confirmed = detector.observe(sample(at: 70, evidence: terminal, difference: 0))

        #expect(baseline.phase == .monitoring)
        #expect(baseline.stableDuration == 0)
        #expect(suspected.phase == .suspected)
        #expect(suspected.stableDuration == 30)
        #expect(confirmed.phase == .confirmed)
        #expect(confirmed.stableDuration == 60)
    }

    @Test("Resume state rejects a changed context or input generation")
    func resumeStateIsBoundToContextAndGeneration() throws {
        var detector = armedDetectorBeforeDefeat()
        let resumeState = try #require(detector.progressResumeState)
        _ = detector.reset(reason: .incompleteBattleEvidence)
        let changedContext = BattleWindowContext(
            processID: context.processID,
            windowID: context.windowID,
            originX: context.originX,
            originY: context.originY,
            width: context.width + 1,
            height: context.height,
            scaleFactor: context.scaleFactor
        )

        let contextMismatch = detector.resumeMonitoring(
            from: resumeState,
            at: 3,
            context: changedContext,
            inputGeneration: 7
        )
        #expect(contextMismatch.phase == .inactive)
        #expect(contextMismatch.resetReason == .windowOrGeometryChanged)
        #expect(!contextMismatch.isArmed)

        let generationMismatch = detector.resumeMonitoring(
            from: resumeState,
            at: 3,
            context: context,
            inputGeneration: 8
        )
        #expect(generationMismatch.phase == .inactive)
        #expect(generationMismatch.resetReason == .inputGenerationChanged)
        #expect(!generationMismatch.isArmed)
    }

    @Test("Measured frames 03 and 04 are suspected after 32 seconds, not confirmed")
    func measuredFramesAreSuspectedNotConfirmed() {
        var detector = BattleStallDetector()
        _ = detector.automaticBattleEnabled(at: 0, context: context, inputGeneration: 7)
        _ = detector.observe(sample(at: 1, evidence: healthyEvidence(enemyCurrent: 600_000, log: "attack 1"), difference: nil))
        _ = detector.observe(sample(at: 2, evidence: healthyEvidence(enemyCurrent: 550_000, log: "attack 2"), difference: 0.03))

        // This transition models captures/natural-defeat-observe-03.png and -04.png.
        let frame03 = BattleStallFrameEvidence.extract(from: measuredFrame03Observations())
        let frame04 = BattleStallFrameEvidence.extract(from: measuredFrame04Observations())
        _ = detector.observe(sample(at: 10, evidence: frame03, difference: 0.04))
        let result = detector.observe(sample(at: 42, evidence: frame04, difference: 0))

        #expect(result.phase == .suspected)
        #expect(result.isArmed)
        #expect(result.stableDuration == 32)
        #expect(result.stableSampleCount == 2)
        #expect(!result.isConfirmedEvidence)
        #expect(result.zeroPartyMembers == 5)
    }

    @Test("A third stable observation can confirm only after 60 seconds")
    func confirmsAtSixtySeconds() {
        var detector = armedDetectorBeforeDefeat()
        let candidate = defeatEvidence(log: "final log")
        _ = detector.observe(sample(at: 10, evidence: candidate, difference: 0.04))
        let before = detector.observe(sample(at: 42, evidence: candidate, difference: 0))
        let confirmed = detector.observe(sample(at: 70, evidence: candidate, difference: 0))

        #expect(before.phase == .suspected)
        #expect(confirmed.phase == .confirmed)
        #expect(confirmed.stableDuration == 60)
        #expect(confirmed.stableSampleCount == 3)
        #expect(confirmed.isConfirmedEvidence)
    }

    @Test("Verified normal combat can confirm a dense five-second visual freeze without HP OCR")
    func verifiedCombatUsesDenseVisualFreeze() {
        var detector = fiveSecondVisualDetector()
        _ = detector.automaticBattleEnabled(at: 0, context: context, inputGeneration: 7)
        let armed = detector.markVerifiedNormalBattleProgress(
            at: 0.5,
            context: context,
            inputGeneration: 7
        )
        let visualOnly = visualOnlyBattleEvidence()

        #expect(armed.phase == .monitoring)
        #expect(armed.isArmed)
        #expect(detector.observe(sample(at: 1, evidence: visualOnly, difference: nil)).phase == .monitoring)
        #expect(detector.observe(sample(at: 2.5, evidence: visualOnly, difference: 0)).phase == .monitoring)
        #expect(detector.observe(sample(at: 4, evidence: visualOnly, difference: 0)).phase == .monitoring)
        #expect(detector.observe(sample(at: 5.5, evidence: visualOnly, difference: 0)).phase == .monitoring)

        let confirmed = detector.observe(sample(at: 6, evidence: visualOnly, difference: 0))
        #expect(confirmed.phase == .confirmed)
        #expect(confirmed.isArmed)
        #expect(confirmed.stableDuration == 5)
        #expect(confirmed.stableSampleCount == 5)
        #expect(confirmed.zeroPartyMembers == 0)
        #expect(confirmed.enemyHP == nil)
    }

    @Test("Visual movement resets the five-second freeze candidate")
    func visualMovementResetsFiveSecondCandidate() {
        var detector = fiveSecondVisualDetector()
        _ = detector.markVerifiedNormalBattleProgress(
            at: 0,
            context: context,
            inputGeneration: 7
        )
        let visualOnly = visualOnlyBattleEvidence()

        _ = detector.observe(sample(at: 1, evidence: visualOnly, difference: nil))
        _ = detector.observe(sample(at: 2.5, evidence: visualOnly, difference: 0))
        _ = detector.observe(sample(at: 4, evidence: visualOnly, difference: 0))
        let moving = detector.observe(sample(at: 5, evidence: visualOnly, difference: 0.01))
        let newBaseline = detector.observe(sample(at: 6, evidence: visualOnly, difference: 0))

        #expect(moving.phase == .monitoring)
        #expect(moving.resetReason == .battleProgress)
        #expect(moving.stableSampleCount == 0)
        #expect(newBaseline.phase == .monitoring)
        #expect(newBaseline.stableDuration == 1)
        #expect(!newBaseline.isConfirmedEvidence)
    }

    @Test("A frozen battle cannot confirm before normal combat was independently verified")
    func unverifiedVisualFreezeNeverConfirms() {
        var detector = fiveSecondVisualDetector()
        _ = detector.automaticBattleEnabled(at: 0, context: context, inputGeneration: 7)
        let visualOnly = visualOnlyBattleEvidence()

        for time in [1.0, 2.5, 4.0, 5.5, 7.0] {
            let result = detector.observe(sample(
                at: time,
                evidence: visualOnly,
                difference: time == 1 ? nil : 0
            ))
            #expect(!result.isConfirmedEvidence)
            #expect(!result.isArmed)
        }
    }

    @Test("A non-battle frame breaks an armed visual-freeze sequence")
    func nonBattleFrameBreaksVisualFreeze() {
        var detector = fiveSecondVisualDetector()
        _ = detector.markVerifiedNormalBattleProgress(
            at: 0,
            context: context,
            inputGeneration: 7
        )
        let visualOnly = visualOnlyBattleEvidence()
        _ = detector.observe(sample(at: 1, evidence: visualOnly, difference: nil))
        _ = detector.observe(sample(at: 2.5, evidence: visualOnly, difference: 0))

        let result = detector.observe(sample(
            at: 4,
            evidence: visualOnly,
            difference: 0,
            battleScreenConfirmed: false
        ))

        #expect(result.phase == .inactive)
        #expect(!result.isArmed)
        #expect(result.resetReason == .incompleteBattleEvidence)
    }

    @Test("Sparse samples cannot be counted as a continuous five-second freeze")
    func sparseVisualSamplesReset() {
        var detector = fiveSecondVisualDetector()
        _ = detector.markVerifiedNormalBattleProgress(
            at: 0,
            context: context,
            inputGeneration: 7
        )
        let visualOnly = visualOnlyBattleEvidence()
        _ = detector.observe(sample(at: 1, evidence: visualOnly, difference: nil))

        let result = detector.observe(sample(at: 4.1, evidence: visualOnly, difference: 0))

        #expect(result.phase == .inactive)
        #expect(!result.isArmed)
        #expect(result.resetReason == .sampleGap)
    }

    @Test("Confirmed defeat evidence cannot cross an input-generation boundary")
    func confirmedEvidenceIsGenerationBound() {
        var detector = armedDetectorBeforeDefeat()
        let candidate = defeatEvidence(log: "final log")
        _ = detector.observe(sample(at: 10, evidence: candidate, difference: 0.04))
        _ = detector.observe(sample(at: 42, evidence: candidate, difference: 0))
        #expect(detector.observe(
            sample(at: 70, evidence: candidate, difference: 0)
        ).isConfirmedEvidence)

        let changedGeneration = detector.observe(sample(
            at: 71,
            evidence: candidate,
            difference: 0,
            generation: 8
        ))
        #expect(changedGeneration.phase == .inactive)
        #expect(changedGeneration.resetReason == .inputGenerationChanged)
        #expect(!changedGeneration.isArmed)
        #expect(!changedGeneration.isConfirmedEvidence)
    }

    @Test("Paused frames reset and require automatic mode to be enabled again")
    func pauseResets() {
        var detector = armedDetectorBeforeDefeat()
        let paused = detector.observe(sample(
            at: 10,
            evidence: defeatEvidence(),
            difference: 0,
            paused: true
        ))
        let later = detector.observe(sample(at: 80, evidence: defeatEvidence(), difference: 0))

        #expect(paused.phase == .inactive)
        #expect(paused.resetReason == .paused)
        #expect(!paused.isArmed)
        #expect(later.phase == .inactive)
    }

    @Test("Modal, generated input, context change, gaps, and out-of-order time reset")
    func discontinuitiesReset() {
        let cases: [(BattleStallSample, BattleStallResetReason)] = [
            (sample(at: 10, evidence: defeatEvidence(), difference: 0, modal: true), .modalObserved),
            (sample(at: 10, evidence: defeatEvidence(), difference: 0, generation: 8), .inputGenerationChanged),
            (sample(
                at: 10,
                evidence: defeatEvidence(),
                difference: 0,
                context: BattleWindowContext(
                    processID: 123,
                    windowID: 17, originX: 0, originY: 30, width: 407, height: 890
                )
            ), .windowOrGeometryChanged),
            (sample(
                at: 10,
                evidence: defeatEvidence(),
                difference: 0,
                context: BattleWindowContext(
                    processID: 124,
                    windowID: 17, originX: 0, originY: 30, width: 406, height: 890
                )
            ), .windowOrGeometryChanged),
            (sample(at: 60, evidence: defeatEvidence(), difference: 0), .sampleGap),
            (sample(at: 2, evidence: defeatEvidence(), difference: 0), .outOfOrderTime),
        ]

        for (event, expectedReason) in cases {
            var detector = armedDetectorBeforeDefeat()
            let result = detector.observe(event)
            #expect(result.phase == .inactive)
            #expect(result.resetReason == expectedReason)
            #expect(!result.isArmed)
        }
    }

    @Test("HP or log progress clears an existing stall timer but stays armed")
    func progressClearsTimer() {
        var detector = armedDetectorBeforeDefeat()
        let stalled = defeatEvidence(log: "final log")
        _ = detector.observe(sample(at: 10, evidence: stalled, difference: 0.04))
        #expect(detector.observe(sample(at: 42, evidence: stalled, difference: 0)).phase == .suspected)

        let progressed = defeatEvidence(enemyCurrent: 400_000, log: "new log")
        let result = detector.observe(sample(at: 44, evidence: progressed, difference: 0.03))

        #expect(result.phase == .monitoring)
        #expect(result.isArmed)
        #expect(result.stableDuration == 0)
        #expect(result.stableSampleCount == 0)
        #expect(result.resetReason == .battleProgress)
    }

    @Test("Pixel movement prevents a stable HP and log snapshot from accumulating")
    func pixelMovementClearsTimer() {
        var detector = armedDetectorBeforeDefeat()
        let stalled = defeatEvidence(log: "final log")
        _ = detector.observe(sample(at: 10, evidence: stalled, difference: 0.04))
        let moving = detector.observe(sample(at: 42, evidence: stalled, difference: 0.01))
        let firstStable = detector.observe(sample(at: 44, evidence: stalled, difference: 0))

        #expect(moving.phase == .monitoring)
        #expect(moving.resetReason == .battleProgress)
        #expect(firstStable.phase == .monitoring)
        #expect(firstStable.stableDuration == 2)
    }

    @Test("Incomplete battle background can never accumulate stall evidence")
    func incompleteBackgroundResets() {
        var detector = armedDetectorBeforeDefeat()
        let incomplete = BattleStallFrameEvidence(
            background: BattleStallBackgroundEvidence(
                lootCandidates: 1,
                trustedLootAnchors: 1,
                pauseCandidates: 1,
                trustedPauseAnchors: 1,
                retreatCandidates: 1,
                trustedRetreatAnchors: 1,
                automaticCandidates: 0,
                trustedAutomaticAnchors: 0
            ),
            enemyHP: hp(400_000, 700_000),
            partyHP: defeatParty,
            combatLogSignature: "same"
        )
        let result = detector.observe(sample(at: 10, evidence: incomplete, difference: 0))

        #expect(result.phase == .inactive)
        #expect(result.resetReason == .incompleteBattleEvidence)
    }

    private var context: BattleWindowContext {
        BattleWindowContext(
            processID: 123,
            windowID: 17,
            originX: 0,
            originY: 30,
            width: 406,
            height: 890
        )
    }

    private var strictBackground: BattleStallBackgroundEvidence {
        BattleStallBackgroundEvidence(
            lootCandidates: 1,
            trustedLootAnchors: 1,
            pauseCandidates: 1,
            trustedPauseAnchors: 1,
            retreatCandidates: 1,
            trustedRetreatAnchors: 1,
            automaticCandidates: 1,
            trustedAutomaticAnchors: 1
        )
    }

    private var defeatParty: [BattleHitPoints] {
        [hp(7_128, 14_000), hp(0, 9_046), hp(0, 3_727), hp(0, 3_103), hp(0, 2_043), hp(0, 2_871)]
    }

    private func hp(_ current: Int, _ maximum: Int) -> BattleHitPoints {
        BattleHitPoints(current: current, maximum: maximum)!
    }

    private func healthyEvidence(enemyCurrent: Int, log: String) -> BattleStallFrameEvidence {
        BattleStallFrameEvidence(
            background: strictBackground,
            enemyHP: hp(enemyCurrent, 701_000),
            partyHP: [
                hp(12_000, 14_000), hp(8_000, 9_046), hp(3_000, 3_727),
                hp(2_000, 3_103), hp(1_500, 2_043), hp(2_000, 2_871),
            ],
            combatLogSignature: log
        )
    }

    private func defeatEvidence(
        enemyCurrent: Int = 423_789,
        log: String = "unchanged combat log"
    ) -> BattleStallFrameEvidence {
        BattleStallFrameEvidence(
            background: strictBackground,
            enemyHP: hp(enemyCurrent, 701_000),
            partyHP: defeatParty,
            combatLogSignature: log
        )
    }

    private func armedDetectorBeforeDefeat() -> BattleStallDetector {
        var detector = BattleStallDetector()
        _ = detector.automaticBattleEnabled(at: 0, context: context, inputGeneration: 7)
        _ = detector.observe(sample(at: 1, evidence: healthyEvidence(enemyCurrent: 600_000, log: "attack 1"), difference: nil))
        _ = detector.observe(sample(at: 2, evidence: healthyEvidence(enemyCurrent: 550_000, log: "attack 2"), difference: 0.03))
        return detector
    }

    private func fiveSecondVisualDetector() -> BattleStallDetector {
        BattleStallDetector(configuration: BattleStallConfiguration(
            suspectedAfter: 3,
            confirmedAfter: 5,
            maximumSampleGap: 3,
            maximumStableROIDifference: 0.002,
            minimumStableSampleCount: 5
        ))
    }

    private func visualOnlyBattleEvidence() -> BattleStallFrameEvidence {
        BattleStallFrameEvidence(
            background: strictBackground,
            enemyHP: nil,
            partyHP: [],
            combatLogSignature: ""
        )
    }

    private func sample(
        at time: Double,
        evidence: BattleStallFrameEvidence,
        difference: Double?,
        modal: Bool = false,
        paused: Bool = false,
        battleScreenConfirmed: Bool = true,
        generation: UInt64 = 7,
        context: BattleWindowContext? = nil
    ) -> BattleStallSample {
        BattleStallSample(
            monotonicTime: time,
            context: context ?? self.context,
            battleScreenConfirmed: battleScreenConfirmed,
            modalPresent: modal,
            paused: paused,
            inputGeneration: generation,
            frameEvidence: evidence,
            battleROIDifferenceFromPrevious: difference
        )
    }

    private func measuredFrame03Observations() -> [OCRTextObservation] {
        measuredNaturalDefeatObservations(clock: "7:18")
    }

    private func measuredTruncatedLootObservations() -> [OCRTextObservation] {
        // Relevant anchors from auto-level-20260905-200757.b9x4bU/live-observe.json.
        // The classifier already accepts its four-control grid despite the missing leading 戰.
        [
            observation("【護符 戰神「風神", 0.7142857119211824, 0.09887640458426972,
                        0.23645320197044328, 0.017977528089887618, 0.30000001192092896),
            observation("利品", 0.8743842369207623, 0.11685393250936327,
                        0.061576355854278786, 0.013483146067415741, 0.5),
            observation("暫停", 0.847290640851513, 0.6292134830497592,
                        0.0640394088669951, 0.017977528089887618, 1),
            observation("撤退", 0.8423645311576354, 0.6584269664044945,
                        0.06896551724137934, 0.017977528089887618, 0.5),
            observation("全部自動", 0.23131222197696935, 0.8693390502288849,
                        0.12850856311215555, 0.018625271186400005, 1),
            observation("跳過", 0.0738916247536946, 0.8696629214606743,
                        0.06896551724137931, 0.017977528089887618, 1),
        ]
    }

    private func measuredFrame04Observations() -> [OCRTextObservation] {
        measuredNaturalDefeatObservations(clock: "7:19")
    }

    private func measuredNaturalDefeatObservations(clock: String) -> [OCRTextObservation] {
        [
            observation(clock, 0.099, 0.063, 0.148, 0.022, 0.30),
            observation("戰利品", 0.833, 0.108, 0.103, 0.016, 1),
            observation("423789/701K", 0.473, 0.571, 0.251, 0.020, 0.30),
            observation("暫停", 0.847, 0.629, 0.064, 0.018, 1),
            observation("1613 dmg", 0.034, 0.636, 0.108, 0.011, 0.30),
            observation("黑曜騎士 西奧多 Lv262", 0.143, 0.645, 0.310, 0.013, 0.30),
            observation("撤退", 0.842, 0.658, 0.069, 0.018, 0.50),
            observation("黑連閃", 0.458, 0.667, 0.103, 0.013, 0.30),
            observation("7128/14K", 0.207, 0.748, 0.128, 0.011, 0.50),
            observation("0/9046", 0.552, 0.746, 0.103, 0.013, 1),
            observation("0/3727", 0.872, 0.746, 0.099, 0.013, 1),
            observation("0/3103", 0.236, 0.827, 0.099, 0.013, 1),
            observation("0/2043", 0.557, 0.827, 0.099, 0.013, 1),
            observation("0/2871", 0.877, 0.827, 0.094, 0.014, 1),
            observation("全部自動", 0.236, 0.869, 0.124, 0.016, 1),
        ]
    }

    private func observation(
        _ text: String,
        _ x: Double,
        _ y: Double,
        _ width: Double,
        _ height: Double,
        _ confidence: Double
    ) -> OCRTextObservation {
        OCRTextObservation(
            text: text,
            rect: NormalizedRect(x: x, y: y, width: width, height: height),
            confidence: confidence
        )
    }
}
