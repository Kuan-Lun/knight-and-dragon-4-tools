import Testing
@testable import MirrorProbeCore

@Suite("Focused successful-result title refinement")
struct MissionResultTitleRefinementTests {
    @Test("An actual stronger title read recovers EXP and loot with the same fixed upper target")
    func trustedFocusedTitleRecoversBothPages() throws {
        for page in ["獲得經驗值", "獲得拾得物"] {
            let observations = scaffold(page: page)
            let original = classify(observations)
            #expect(original.state == .unknown)
            #expect(original.evidence.map(\.kind) == [.lowConfidenceMarker])
            #expect(needs(observations))

            let result = try #require(refine(observations))
            #expect(result.state == .missionCompleteRepeatSelected)
            #expect(MissionSuccessPageIdentity.resolve(in: result)
                    == (page == "獲得經驗值" ? .experience : .loot))
            #expect(result.allowedActions.map(\.name) == [.advanceMissionComplete])
            #expect(result.allowedActions.first?.target.rect
                    == MissionResultTopActionResolver.measuredTopAdvanceRect)
            #expect(result.policyGatedActions.isEmpty)
            let evidence = try #require(result.evidence.first { $0.kind == .missionCompleteTitle })
            #expect(evidence.observation == focusedTitle())
            #expect(evidence.detail.contains("source=focusedResultTitle"))
            #expect(evidence.detail.contains("originalConfidence=0.5"))
            #expect(evidence.detail.contains("regionOfInterest=(x=0.25, y=0.07"))
            // Refinement leaves the caller's raw OCR intact for reports and replay.
            #expect(observations.first?.confidence == 0.5)
            #expect(classify(observations) == original)
        }
    }

    @Test("The legitimate loot-page sell-all header remains ordinary page content")
    func legitimateLootSellAllHeaderIsRetained() throws {
        let observations = scaffold(page: "獲得拾得物") + [
            observation("全部出售", rect: .init(x: 0.80, y: 0.18, width: 0.16, height: 0.02)),
        ]
        let result = try #require(refine(observations))
        #expect(MissionSuccessPageIdentity.resolve(in: result) == .loot)
        #expect(result.allowedActions.map(\.name) == [.advanceMissionComplete])
        #expect(result.allowedActions.first?.target.sourceText
                == MissionResultTopActionResolver.measuredTopAdvanceSentinel)
    }

    @Test("The measured original and focused confidence floors are independent and bounded")
    func confidenceFloors() {
        for originalConfidence in [0.50, 0.599_999] {
            let observations = replacing(0, in: scaffold(), with: title(confidence: originalConfidence))
            for focusedConfidence in [0.60, 1.0] {
                #expect(refine(observations, focused: [focusedTitle(confidence: focusedConfidence)]) != nil)
            }
        }
        for confidence in [0.49, 0.60, 1.0, -0.1, 1.01, .nan, .infinity] {
            let observations = replacing(0, in: scaffold(), with: title(confidence: confidence))
            #expect(!needs(observations))
            #expect(refine(observations) == nil)
        }
        for confidence in [0.59, -0.1, 1.01, .nan, .infinity] {
            #expect(refine(scaffold(), focused: [focusedTitle(confidence: confidence)]) == nil)
        }
    }

    @Test("Only one intact measured title qualifies; fragments and failure variants stay blocked")
    func titleCandidatesMustBeExactAndUnique() {
        for text in ["任", "任務完成", "任務完成度", "任務失敗！", ""] {
            let observations = replacing(0, in: scaffold(), with: title(text: text))
            #expect(!needs(observations))
            #expect(refine(observations) == nil)
        }
        for duplicate in [title(), title(text: "任務完成", confidence: 1)] {
            let observations = scaffold() + [duplicate]
            #expect(!needs(observations))
            #expect(refine(observations) == nil)
        }
        // Unicode width and whitespace normalization preserve the same exact title.
        let compatible = replacing(0, in: scaffold(), with: title(text: " 任務完成! "))
        #expect(refine(compatible) != nil)
    }

    @Test("Title placement must remain wholly inside the measured region and match its center")
    func measuredTitleGeometry() {
        let invalidRects: [NormalizedRect] = [
            .init(x: 0.24, y: 0.10, width: 0.50, height: 0.03), // center fits, left edge does not
            .init(x: 0.30, y: 0.065, width: 0.40, height: 0.06), // top edge does not
            .init(x: 0.30, y: 0.13, width: 0.40, height: 0.03), // bottom edge does not
            .init(x: 0.25, y: 0.10, width: 0.20, height: 0.03), // center is too far left
            .init(x: 0.39, y: 0.07, width: 0.21, height: 0.02), // center is too high
            .init(x: 0.39, y: 0.10, width: 0, height: 0.02),
            .init(x: .nan, y: 0.10, width: 0.21, height: 0.02),
        ]
        for rect in invalidRects {
            let observations = replacing(0, in: scaffold(), with: title(rect: rect))
            #expect(!needs(observations))
            #expect(refine(observations) == nil)
            #expect(refine(scaffold(), focused: [focusedTitle(rect: rect)]) == nil)
        }
    }

    @Test("Missing, duplicate, weak, or misplaced repeat and page anchors do not trigger OCR refinement")
    func completeTrustedScaffoldRequired() {
        for index in [1, 2] {
            var missing = scaffold()
            missing.remove(at: index)
            #expect(!needs(missing))
            #expect(refine(missing) == nil)
            #expect(!needs(scaffold() + [scaffold()[index]]))

            let original = scaffold()[index]
            let weak = replacing(index, in: scaffold(), with: observation(
                original.text, rect: original.rect, confidence: 0.59
            ))
            #expect(!needs(weak))
            #expect(refine(weak) == nil)
            let misplaced = replacing(index, in: scaffold(), with: observation(
                original.text, rect: .init(x: 0.40, y: 0.50, width: 0.25, height: 0.02)
            ))
            #expect(!needs(misplaced))
            #expect(refine(misplaced) == nil)
        }
        let twoPages = scaffold() + [
            observation("獲得拾得物", rect: .init(x: 0.78, y: 0.15, width: 0.19, height: 0.02)),
        ]
        #expect(!needs(twoPages))
        #expect(refine(twoPages) == nil)
    }

    @Test("Absent, ambiguous, or invalid rendered stamps cannot be replaced by SELECTED OCR")
    func renderedSelectionProofRequired() {
        let stamps: [RepeatSelectedStampDetection?] = [
            nil,
            stamp(red: 0),
            stamp(red: 20),
            stamp(red: -1),
            stamp(red: 1_001),
            .init(region: RepeatSelectedStampDetector.measuredRegion, redPixelCount: 0, sampledPixelCount: 0),
            .init(region: .init(x: 0.3, y: 0.2, width: 0.4, height: 0.1), redPixelCount: 100, sampledPixelCount: 1_000),
        ]
        for candidate in stamps {
            let observations = scaffold()
            let classification = GameStateClassifier.classify(
                observations: observations, repeatSelectedStampDetection: candidate
            )
            #expect(!MissionResultTitleRefinement.needsRefinement(
                observations: observations, classification: classification,
                repeatSelectedStampDetection: candidate
            ))
            #expect(MissionResultTitleRefinement.refinedClassification(
                observations: observations, classification: classification,
                repeatSelectedStampDetection: candidate, focusedObservations: [focusedTitle()]
            ) == nil)
        }
    }

    @Test("Focused OCR must contain one matching title with agreeing geometry")
    func focusedReadCannotIntroduceDifferentOrAdditionalText() {
        let cases: [[OCRTextObservation]] = [
            [],
            [focusedTitle(), focusedTitle()],
            [focusedTitle(), observation("否", rect: .init(x: 0.5, y: 0.1, width: 0.03, height: 0.02))],
            [focusedTitle(text: "任務失敗！")],
            [focusedTitle(text: "任務完成")],
            [focusedTitle(text: "任")],
            // All three boxes fit the title ROI but differ from the original read too much.
            [focusedTitle(rect: .init(x: 0.42, y: 0.105, width: 0.21, height: 0.023))],
            [focusedTitle(rect: .init(x: 0.40, y: 0.13, width: 0.21, height: 0.019))],
            [focusedTitle(rect: .init(x: 0.35, y: 0.105, width: 0.29, height: 0.023))],
        ]
        for focused in cases {
            #expect(refine(scaffold(), focused: focused) == nil)
        }
    }

    @Test("Unrelated invalid full-frame OCR and suspicious decision controls remain blockers")
    func allOriginalEvidenceRemainsRelevant() {
        for extra in [
            observation("other", rect: .init(x: 0.1, y: 0.5, width: 0.1, height: 0.02), confidence: .nan),
            observation("other", rect: .init(x: -0.1, y: 0.5, width: 0.1, height: 0.02)),
            observation(" ", rect: .init(x: 0.1, y: 0.5, width: 0.1, height: 0.02)),
        ] {
            #expect(!needs(scaffold() + [extra]))
            #expect(refine(scaffold() + [extra]) == nil)
        }
        for text in ["是", "否", "購買", "出售"] {
            let extra = observation(text, rect: .init(x: 0.1, y: 0.5, width: 0.1, height: 0.02))
            #expect(!needs(scaffold() + [extra]))
            #expect(refine(scaffold() + [extra]) == nil)
        }
    }

    @Test("Reclassifying the intact full frame exposes conflicts hidden by the first weak-title gate")
    func fullReclassificationPreservesConflicts() {
        for extra in [
            observation("全部自動", rect: .init(x: 0.84, y: 0.68, width: 0.12, height: 0.03)),
            observation("任務失敗！", rect: .init(x: 0.39, y: 0.105, width: 0.21, height: 0.023)),
            observation("背包已滿", rect: .init(x: 0.3, y: 0.4, width: 0.3, height: 0.03)),
        ] {
            let observations = scaffold() + [extra]
            // The first pass reports only the weak title; do not delete the conflicting row.
            #expect(needs(observations))
            #expect(refine(observations) == nil)
        }
    }

    @Test("Refinement requires the sole matching low-confidence classification evidence")
    func initialClassificationMustMatchWeakTitle() {
        let observations = scaffold()
        let initial = classify(observations)
        let target = NamedGameTarget(
            name: .missionCompleteAdvance, sourceText: "test",
            rect: MissionResultTopActionResolver.measuredTopAdvanceRect,
            point: MissionResultTopActionResolver.measuredTopAdvanceRect.center
        )
        let action = AllowedGameAction(name: .advanceMissionComplete, target: target)
        let variants = [
            GameStateClassification(state: .missionComplete, evidence: initial.evidence, allowedActions: []),
            GameStateClassification(state: .unknown, evidence: initial.evidence, allowedActions: [action]),
            GameStateClassification(state: .unknown, evidence: initial.evidence, allowedActions: [], policyGatedActions: [
                .init(name: .openBattleRetreatConfirmation, target: target, requirement: .temporalDefeatRecovery),
            ]),
            GameStateClassification(state: .unknown, evidence: [], allowedActions: []),
            GameStateClassification(state: .unknown, evidence: initial.evidence + initial.evidence, allowedActions: []),
            GameStateClassification(state: .unknown, evidence: [
                .init(kind: .invalidObservation, observation: title(), detail: "invalid"),
            ], allowedActions: []),
            GameStateClassification(state: .unknown, evidence: [
                .init(kind: .lowConfidenceMarker, observation: title(confidence: 0.51), detail: "different"),
            ], allowedActions: []),
        ]
        for classification in variants {
            #expect(!MissionResultTitleRefinement.needsRefinement(
                observations: observations, classification: classification,
                repeatSelectedStampDetection: stamp()
            ))
            #expect(MissionResultTitleRefinement.refinedClassification(
                observations: observations, classification: classification,
                repeatSelectedStampDetection: stamp(), focusedObservations: [focusedTitle()]
            ) == nil)
        }
    }

    private func needs(_ observations: [OCRTextObservation]) -> Bool {
        MissionResultTitleRefinement.needsRefinement(
            observations: observations, classification: classify(observations),
            repeatSelectedStampDetection: stamp()
        )
    }

    private func refine(
        _ observations: [OCRTextObservation], focused: [OCRTextObservation]? = nil
    ) -> GameStateClassification? {
        MissionResultTitleRefinement.refinedClassification(
            observations: observations, classification: classify(observations),
            repeatSelectedStampDetection: stamp(), focusedObservations: focused ?? [focusedTitle()]
        )
    }

    private func classify(_ observations: [OCRTextObservation]) -> GameStateClassification {
        GameStateClassifier.classify(
            observations: observations,
            repeatSelectedStampDetection: stamp()
        )
    }

    private func scaffold(page: String = "獲得經驗值") -> [OCRTextObservation] {
        [
            title(),
            observation("重複進行此任務", rect: .init(x: 0.0255, y: 0.2354, width: 0.2834, height: 0.0191)),
            observation(page, rect: .init(x: 0.7803, y: 0.1466, width: 0.1911, height: 0.0191)),
            observation("SELECTED", rect: .init(x: 0.3781, y: 0.2229, width: 0.2456, height: 0.0327)),
        ]
    }

    private func title(
        text: String = "任務完成！", confidence: Double = 0.5,
        rect: NormalizedRect = .init(x: 0.3884, y: 0.1029, width: 0.2105, height: 0.0267)
    ) -> OCRTextObservation {
        observation(text, rect: rect, confidence: confidence)
    }

    private func focusedTitle(
        text: String = "任務完成！", confidence: Double = 1,
        rect: NormalizedRect = .init(x: 0.3903, y: 0.1043, width: 0.2095, height: 0.0237)
    ) -> OCRTextObservation {
        observation(text, rect: rect, confidence: confidence)
    }

    private func observation(
        _ text: String, rect: NormalizedRect, confidence: Double = 1
    ) -> OCRTextObservation {
        .init(text: text, rect: rect, confidence: confidence)
    }

    private func stamp(red: Int = 100) -> RepeatSelectedStampDetection {
        .init(region: RepeatSelectedStampDetector.measuredRegion, redPixelCount: red, sampledPixelCount: 1_000)
    }

    private func replacing(
        _ index: Int, in observations: [OCRTextObservation], with replacement: OCRTextObservation
    ) -> [OCRTextObservation] {
        var result = observations
        result[index] = replacement
        return result
    }
}
