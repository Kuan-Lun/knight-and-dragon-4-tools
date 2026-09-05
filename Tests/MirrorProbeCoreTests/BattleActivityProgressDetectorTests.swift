import Testing
@testable import MirrorProbeCore

@Suite("Battle activity progress detector")
struct BattleActivityProgressDetectorTests {
    @Test("A live-quality partial HP frame still exposes bounded activity evidence")
    func partialLiveOCRProducesActivityEvidence() {
        let evidence = BattleActivityFrameEvidence.extract(from: liveLikeObservations(
            enemyHP: "203006/203K",
            log: "45 Sup speed support"
        ))

        #expect(evidence.hasStrictBattleBackground)
        #expect(evidence.hpReadings.isEmpty)
        #expect(!evidence.combatLogSignature.isEmpty)
    }

    @Test("Stable-position HP movement requires a corroborating ROI pixel change")
    func hpChangeRequiresPixels() {
        var detector = BattleActivityProgressDetector()
        _ = detector.automaticBattlePosted(
            at: 0,
            battleSessionID: "battle-1",
            context: context,
            inputGeneration: 7
        )
        _ = detector.observe(sample(
            at: 1,
            enemyHP: "200000/203K",
            log: "same",
            difference: nil
        ))

        #expect(detector.observe(sample(
            at: 2,
            enemyHP: "190000/203K",
            log: "same",
            difference: 0
        )) == .awaitingEvidence)
        #expect(detector.observe(sample(
            at: 3,
            enemyHP: "180000/203K",
            log: "same",
            difference: 0.03
        )) == .progressObserved)
    }

    @Test("Arbitrary battle animation without an HP or log change is insufficient")
    func arbitraryAnimationIsInsufficient() {
        var detector = activatedDetector()
        _ = detector.observe(sample(
            at: 1,
            enemyHP: "200000/203K",
            log: "same",
            difference: nil
        ))

        #expect(detector.observe(sample(
            at: 2,
            enemyHP: "200000/203K",
            log: "same",
            difference: 0.20
        )) == .awaitingEvidence)
    }

    @Test("A bounded log change also requires corroborating pixels")
    func logChangeRequiresPixels() {
        var detector = activatedDetector()
        _ = detector.observe(sample(
            at: 1,
            enemyHP: "200000/203K",
            log: "attack one",
            difference: nil
        ))
        #expect(detector.observe(sample(
            at: 2,
            enemyHP: "200000/203K",
            log: "attack two",
            difference: 0
        )) == .awaitingEvidence)
        #expect(detector.observe(sample(
            at: 3,
            enemyHP: "200000/203K",
            log: "attack three",
            difference: 0.03
        )) == .progressObserved)
    }

    @Test("Activity evidence cannot cross battle, context, or input-generation boundaries")
    func identityBoundariesFailClosed() {
        var detector = activatedDetector()
        _ = detector.observe(sample(
            at: 1,
            enemyHP: "200000/203K",
            log: "same",
            difference: nil
        ))
        let otherBattle = BattleActivityProgressSample(
            monotonicTime: 2,
            battleSessionID: "battle-2",
            context: context,
            inputGeneration: 7,
            evidence: .extract(from: liveLikeObservations(
                enemyHP: "190000/203K",
                log: "changed"
            )),
            battleROIDifferenceFromPrevious: 0.03
        )

        #expect(detector.observe(otherBattle) == .inactive)
        #expect(detector.observe(sample(
            at: 3,
            enemyHP: "180000/203K",
            log: "changed again",
            difference: 0.03
        )) == .inactive)
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

    private func activatedDetector() -> BattleActivityProgressDetector {
        var detector = BattleActivityProgressDetector()
        _ = detector.automaticBattleExpected(
            at: 0,
            battleSessionID: "battle-1",
            context: context,
            inputGeneration: 7
        )
        return detector
    }

    private func sample(
        at time: Double,
        enemyHP: String,
        log: String,
        difference: Double?
    ) -> BattleActivityProgressSample {
        BattleActivityProgressSample(
            monotonicTime: time,
            battleSessionID: "battle-1",
            context: context,
            inputGeneration: 7,
            evidence: .extract(from: liveLikeObservations(enemyHP: enemyHP, log: log)),
            battleROIDifferenceFromPrevious: difference
        )
    }

    private func liveLikeObservations(enemyHP: String, log: String) -> [OCRTextObservation] {
        [
            observation("戰利品", 0.83, 0.10, 0.11, 0.02, 1),
            observation("暫停", 0.84, 0.62, 0.08, 0.02, 1),
            observation("撤退", 0.84, 0.65, 0.08, 0.02, 0.5),
            observation("全部自動", 0.23, 0.86, 0.14, 0.02, 1),
            observation(enemyHP, 0.47, 0.39, 0.26, 0.03, 1),
            observation(log, 0.04, 0.64, 0.40, 0.02, 0.3),
            // Representative incomplete party OCR must not be repaired or required here.
            observation("046/9046", 0.52, 0.74, 0.14, 0.02, 0.5),
            observation("27/3721", 0.86, 0.74, 0.11, 0.02, 0.5),
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
