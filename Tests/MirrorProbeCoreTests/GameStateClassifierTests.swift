import Testing
@testable import MirrorProbeCore

@Suite("GameStateClassifier")
struct GameStateClassifierTests {
    @Test("Mission complete exposes only the observed repeat option")
    func missionCompleteAllowsSelectingRepeat() {
        let repeatRect = rect(0.03, 0.18, 0.31, 0.04)
        let result = GameStateClassifier.classify(observations: [
            observation("任務完成！", rect(0.31, 0.06, 0.38, 0.04)),
            observation("重複進行此任務", repeatRect),
            observation("全部出售", rect(0.80, 0.06, 0.17, 0.04)),
        ])

        #expect(result.state == .missionComplete)
        #expect(result.allowedActions.count == 1)
        #expect(result.allowedActions.first?.name == .selectMissionRepeat)
        #expect(result.allowedActions.first?.target.name == .missionRepeatOption)
        #expect(result.allowedActions.first?.target.rect == repeatRect)
        #expect(result.allowedActions.first?.target.point == repeatRect.center)
        #expect(!result.evidence.contains { $0.observation?.text == "全部出售" })
    }

    @Test("Selected mission-complete EXP page uses only the fixed top advance marker")
    func selectedRepeatAllowsTopAdvance() {
        let topAdvance = rect(0.02, 0.13, 0.06, 0.03)
        let lowerAdvance = rect(0.02, 0.83, 0.06, 0.03)
        let result = GameStateClassifier.classify(observations: [
            observation("任務完成!", rect(0.31, 0.06, 0.38, 0.04)),
            observation("獲得經驗值", rect(0.77, 0.13, 0.20, 0.03)),
            observation(">>", topAdvance),
            observation("重複進行此任務", rect(0.03, 0.18, 0.31, 0.04)),
            observation("S E L E C T E D", rect(0.38, 0.17, 0.25, 0.05)),
            observation(">>", lowerAdvance),
        ])

        #expect(result.state == .missionCompleteRepeatSelected)
        #expect(result.allowedActions.count == 1)
        #expect(result.allowedActions.first?.name == .advanceMissionComplete)
        #expect(result.allowedActions.first?.target.name == .missionCompleteAdvance)
        #expect(result.allowedActions.first?.target.rect == topAdvance)
        #expect(result.evidence.map(\.kind).contains(.missionExperiencePage))
    }

    @Test("Selected mission-complete state remains stopped without a top advance marker")
    func selectedRepeatWithoutAdvanceStops() {
        let result = GameStateClassifier.classify(observations: [
            observation("任務完成！", rect(0.31, 0.06, 0.38, 0.04)),
            observation("獲得經驗值", rect(0.77, 0.13, 0.20, 0.03)),
            observation("重複進行此任務", rect(0.03, 0.18, 0.31, 0.04)),
            observation("SELECTED", rect(0.38, 0.17, 0.25, 0.05)),
        ])

        #expect(result.state == .missionCompleteRepeatSelected)
        #expect(result.allowedActions.isEmpty)
    }

    @Test("The measured SALECTED OCR substitution is a selected repeat marker")
    func salectedAliasAllowsTopAdvance() {
        let topAdvance = rect(0.02463, 0.19775, 0.04433, 0.01124)
        let result = GameStateClassifier.classify(observations: [
            observation("任務完成！", rect(0.38911, 0.10551, 0.21193, 0.02269)),
            observation("獲得經驗值", rect(0.77833, 0.14607, 0.19212, 0.02022)),
            OCRTextObservation(
                text: "SALECTED",
                rect: rect(0.36500, 0.22104, 0.26557, 0.03901),
                confidence: 0.30000001192092896
            ),
            observation("重複進行此任務", rect(0.02463, 0.23596, 0.28571, 0.02022)),
            OCRTextObservation(text: ">>", rect: topAdvance, confidence: 0.30),
        ])

        #expect(result.state == .missionCompleteRepeatSelected)
        #expect(result.evidence.contains {
            $0.kind == .repeatSelectedMarker && $0.observation?.text == "SALECTED"
        })
        #expect(result.allowedActions.map(\.name) == [.advanceMissionComplete])
        #expect(result.allowedActions.first?.target.rect == topAdvance)
    }

    @Test("The SALECTED alias remains unique and spatially constrained")
    func salectedAliasCannotBypassMarkerGeometry() {
        let common = [
            observation("任務完成！", rect(0.38911, 0.10551, 0.21193, 0.02269)),
            observation("獲得經驗值", rect(0.77833, 0.14607, 0.19212, 0.02022)),
            observation("重複進行此任務", rect(0.02463, 0.23596, 0.28571, 0.02022)),
        ]
        let misplaced = OCRTextObservation(
            text: "SALECTED",
            rect: rect(0.72, 0.50, 0.20, 0.04),
            confidence: 1
        )
        let valid = OCRTextObservation(
            text: "SALECTED",
            rect: rect(0.36500, 0.22104, 0.26557, 0.03901),
            confidence: 0.30
        )

        for observations in [common + [misplaced], common + [valid, valid]] {
            let result = GameStateClassifier.classify(observations: observations)
            #expect(result.state == .unknown)
            #expect(result.allowedActions.isEmpty)
            #expect(result.evidence.contains { $0.kind == .conflictingStateMarkers })
        }
    }

    @Test("The exact zero-OCR live loot layout requires opt-in and uses tagged measured evidence")
    func exactLiveLootLayoutUsesOptInMeasuredFallback() {
        let observations = zeroOCRLiveLootObservations()
        let initial = GameStateClassifier.classify(observations: observations)
        #expect(initial.state == .missionCompleteRepeatSelected)
        #expect(initial.allowedActions.isEmpty)

        let retried = GameStateClassifier.classify(
            observations: observations,
            permitMeasuredLootTopAdvanceFallback: true
        )
        #expect(retried.state == .missionCompleteRepeatSelected)
        #expect(retried.allowedActions.map(\.name) == [.advanceMissionComplete])
        #expect(
            retried.allowedActions.first?.target.sourceText
                == GameStateClassifier.measuredLootTopAdvanceSentinel
        )
        #expect(
            retried.allowedActions.first?.target.rect
                == GameStateClassifier.measuredLootTopAdvanceRect
        )
        #expect(
            retried.allowedActions.first?.target.point
                == GameStateClassifier.measuredLootTopAdvanceRect.center
        )
        let fallbackEvidence = retried.evidence.filter {
            $0.kind == .missionCompleteAdvanceMeasuredFallback
        }
        #expect(fallbackEvidence.count == 1)
        #expect(fallbackEvidence.first?.observation == nil)
        #expect(
            fallbackEvidence.first?.detail
                == GameStateClassifier.measuredLootTopAdvanceSentinel
        )
    }

    @Test("Any top-ROI text or whole-page arrow-like candidate blocks the zero-OCR fallback")
    func measuredLootFallbackRequiresTrulyEmptyGlyphOCR() {
        let observations = zeroOCRLiveLootObservations()
        let blockers = [
            OCRTextObservation(
                text: "unreadable",
                rect: rect(0.030, 0.198, 0.040, 0.010),
                confidence: 0.01
            ),
            observation(">>", rect(0.025, 0.691, 0.048, 0.011)),
            observation("»", rect(0.025, 0.691, 0.048, 0.011)),
            observation(">2", rect(0.025, 0.691, 0.048, 0.011)),
            observation("22", rect(0.025, 0.691, 0.048, 0.011)),
            observation("2", rect(0.025, 0.691, 0.048, 0.011)),
        ]

        for blocker in blockers {
            let result = GameStateClassifier.classify(
                observations: observations + [blocker],
                permitMeasuredLootTopAdvanceFallback: true
            )
            #expect(result.allowedActions.isEmpty)
        }
    }

    @Test("Every measured loot fallback anchor must remain trusted, unique, and tightly placed")
    func measuredLootFallbackRequiresExactAnchorLayout() {
        let variants: [[OCRTextObservation]] = [
            [
                observation("任務完成！", rect(0.410, 0.10551, 0.21193, 0.02269)),
                observation("獲得拾得物", rect(0.77833, 0.14607, 0.19212, 0.02022)),
                observation("重複進行此任務", rect(0.02463, 0.23596, 0.28571, 0.02022)),
                OCRTextObservation(
                    text: "SELECTED",
                    rect: rect(0.36982, 0.22325, 0.26002, 0.03505),
                    confidence: 0.50
                ),
            ],
            [
                observation("任務完成！", rect(0.38911, 0.10551, 0.21193, 0.02269)),
                observation("獲得拾得物", rect(0.750, 0.14607, 0.19212, 0.02022)),
                observation("重複進行此任務", rect(0.02463, 0.23596, 0.28571, 0.02022)),
                OCRTextObservation(
                    text: "SELECTED",
                    rect: rect(0.36982, 0.22325, 0.26002, 0.03505),
                    confidence: 0.50
                ),
            ],
            [
                observation("任務完成！", rect(0.38911, 0.10551, 0.21193, 0.02269)),
                observation("獲得拾得物", rect(0.77833, 0.14607, 0.19212, 0.02022)),
                observation("重複進行此任務", rect(0.02463, 0.220, 0.28571, 0.02022)),
                OCRTextObservation(
                    text: "SELECTED",
                    rect: rect(0.36982, 0.210, 0.26002, 0.03505),
                    confidence: 0.50
                ),
            ],
            [
                OCRTextObservation(
                    text: "任務完成！",
                    rect: rect(0.38911, 0.10551, 0.21193, 0.02269),
                    confidence: 0.94
                ),
                observation("獲得拾得物", rect(0.77833, 0.14607, 0.19212, 0.02022)),
                observation("重複進行此任務", rect(0.02463, 0.23596, 0.28571, 0.02022)),
                OCRTextObservation(
                    text: "SELECTED",
                    rect: rect(0.36982, 0.22325, 0.26002, 0.03505),
                    confidence: 0.50
                ),
            ],
            [
                observation("任務完成！", rect(0.38911, 0.10551, 0.21193, 0.02269)),
                observation("獲得拾得物", rect(0.77833, 0.14607, 0.19212, 0.02022)),
                observation("重複進行此任務", rect(0.02463, 0.23596, 0.28571, 0.02022)),
                OCRTextObservation(
                    text: "SELECTED",
                    rect: rect(0.36982, 0.22325, 0.26002, 0.03505),
                    confidence: 0.49
                ),
            ],
        ]

        for observations in variants {
            let result = GameStateClassifier.classify(
                observations: observations,
                permitMeasuredLootTopAdvanceFallback: true
            )
            #expect(result.allowedActions.isEmpty)
        }

        let duplicated = GameStateClassifier.classify(
            observations: zeroOCRLiveLootObservations() + [
                observation("任務完成！", rect(0.389, 0.106, 0.212, 0.023)),
            ],
            permitMeasuredLootTopAdvanceFallback: true
        )
        #expect(duplicated.state == .unknown)
        #expect(duplicated.allowedActions.isEmpty)
    }

    @Test("Zero-OCR measured continuation is never available on EXP or failure pages")
    func measuredLootFallbackIsNotSharedWithOtherResultPages() {
        var experience = zeroOCRLiveLootObservations()
        experience[1] = observation(
            "獲得經驗值",
            rect(0.77833, 0.14607, 0.19212, 0.02022)
        )
        let expResult = GameStateClassifier.classify(
            observations: experience,
            permitMeasuredLootTopAdvanceFallback: true
        )

        var failure = zeroOCRLiveLootObservations()
        failure.remove(at: 1)
        failure[0] = observation("任務失敗", rect(0.4089, 0.1056, 0.1773, 0.0225))
        let failureResult = GameStateClassifier.classify(
            observations: failure,
            permitMeasuredLootTopAdvanceFallback: true
        )

        #expect(expResult.state == .missionCompleteRepeatSelected)
        #expect(expResult.allowedActions.isEmpty)
        #expect(failureResult.state == .missionFailedRepeatSelected)
        #expect(failureResult.allowedActions.isEmpty)
    }

    @Test("The live EXP-page OCR authorizes only its top arrow")
    func liveSelectedOCRVariant() {
        let topAdvance = rect(0.0246, 0.1978, 0.0443, 0.0112)
        let result = GameStateClassifier.classify(observations: [
            observation("任務完成！", rect(0.389, 0.105, 0.212, 0.023)),
            observation("獲得經驗值", rect(0.7783, 0.1461, 0.1921, 0.0202)),
            observation("重複進行此任務", rect(0.025, 0.236, 0.286, 0.020)),
            OCRTextObservation(
                text: "ISELECTED",
                rect: rect(0.366, 0.223, 0.263, 0.037),
                confidence: 0.30
            ),
            OCRTextObservation(
                text: ">>",
                rect: topAdvance,
                confidence: 0.30
            ),
            OCRTextObservation(
                text: ">>",
                rect: rect(0.025, 0.856, 0.044, 0.011),
                confidence: 0.30
            ),
        ])

        #expect(result.state == .missionCompleteRepeatSelected)
        #expect(result.allowedActions.map(\.name) == [.advanceMissionComplete])
        #expect(result.allowedActions.first?.target.rect == topAdvance)
    }

    @Test("A lower mission-complete arrow is never the advance action")
    func lowerMissionCompleteAdvanceIsIgnored() {
        let lowerAdvance = rect(0.0246, 0.5281, 0.0443, 0.0135)
        let result = GameStateClassifier.classify(observations: [
            observation("任務完成！", rect(0.389, 0.105, 0.212, 0.023)),
            observation("獲得經驗值", rect(0.7783, 0.1461, 0.1921, 0.0202)),
            observation("重複進行此任務", rect(0.025, 0.236, 0.286, 0.020)),
            observation("SELECTED", rect(0.366, 0.223, 0.263, 0.037)),
            observation(">>", lowerAdvance),
        ])

        #expect(result.state == .missionCompleteRepeatSelected)
        #expect(result.allowedActions.isEmpty)
    }

    @Test("Vision's measured >2 lower glyph is never a success advance")
    func measuredGreaterThanTwoVariantIsNotAnAdvance() {
        let lowerAdvance = rect(0.0246, 0.5281, 0.0443, 0.0135)
        let result = GameStateClassifier.classify(observations: [
            observation("任務完成！", rect(0.389, 0.105, 0.212, 0.023)),
            observation("獲得經驗值", rect(0.7783, 0.1461, 0.1921, 0.0202)),
            observation("重複進行此任務", rect(0.025, 0.236, 0.286, 0.020)),
            observation("ISELECTED", rect(0.366, 0.223, 0.263, 0.037)),
            OCRTextObservation(text: ">2", rect: lowerAdvance, confidence: 0.30),
        ])

        #expect(result.state == .missionCompleteRepeatSelected)
        #expect(result.allowedActions.isEmpty)
    }

    @Test("The >2 OCR variant cannot turn the success page's top glyph into an action")
    func greaterThanTwoTopGlyphDoesNotAuthorizeSuccessAdvance() {
        let result = GameStateClassifier.classify(observations: [
            observation("任務完成！", rect(0.389, 0.105, 0.212, 0.023)),
            observation("獲得經驗值", rect(0.7783, 0.1461, 0.1921, 0.0202)),
            observation("重複進行此任務", rect(0.025, 0.236, 0.286, 0.020)),
            observation("ISELECTED", rect(0.366, 0.223, 0.263, 0.037)),
            OCRTextObservation(
                text: ">2",
                rect: rect(0.0246, 0.1978, 0.0443, 0.0112),
                confidence: 0.30
            ),
        ])

        #expect(result.state == .missionCompleteRepeatSelected)
        #expect(result.allowedActions.isEmpty)
    }

    @Test("The measured lower-only >2 variant cannot authorize a failure-page top advance")
    func greaterThanTwoTopGlyphDoesNotAuthorizeFailureAdvance() {
        let result = GameStateClassifier.classify(observations: [
            observation("任務失敗", rect(0.409, 0.105, 0.178, 0.023)),
            OCRTextObservation(
                text: ">2",
                rect: rect(0.0246, 0.1978, 0.0443, 0.0112),
                confidence: 0.30
            ),
            observation("重複進行此任務", rect(0.025, 0.236, 0.286, 0.020)),
            observation("ISELECTED", rect(0.366, 0.223, 0.263, 0.037)),
        ])

        #expect(result.state == .missionFailedRepeatSelected)
        #expect(result.allowedActions.isEmpty)
    }

    @Test("A mission-complete top arrow is not actionable without a result-page identity")
    func missionCompleteTopArrowWithoutPageIdentityStops() {
        let result = GameStateClassifier.classify(observations: [
            observation("任務完成！", rect(0.389, 0.105, 0.212, 0.023)),
            observation("重複進行此任務", rect(0.025, 0.236, 0.286, 0.020)),
            observation("SELECTED", rect(0.366, 0.223, 0.263, 0.037)),
            observation(">>", rect(0.0246, 0.1978, 0.0443, 0.0112)),
        ])

        #expect(result.state == .missionCompleteRepeatSelected)
        #expect(result.allowedActions.isEmpty)
    }

    @Test("The live loot page has its own identity and uses the same top arrow")
    func liveLootPageUsesSameTopArrow() {
        let topAdvance = rect(0.0246, 0.1978, 0.0443, 0.0112)
        let result = GameStateClassifier.classify(observations: [
            observation("任務完成！", rect(0.389, 0.105, 0.212, 0.023)),
            observation("獲得拾得物", rect(0.7782, 0.1459, 0.1923, 0.0206)),
            observation(">>", topAdvance),
            observation("重複進行此任務", rect(0.025, 0.236, 0.286, 0.020)),
            observation("SELECTED", rect(0.370, 0.223, 0.259, 0.035)),
            observation(">>", rect(0.024, 0.691, 0.048, 0.011)),
        ])

        #expect(result.state == .missionCompleteRepeatSelected)
        #expect(result.evidence.map(\.kind).contains(.missionLootPage))
        #expect(result.allowedActions.first?.target.rect == topAdvance)
    }

    @Test("The exact live loot page accepts its measured top 22 OCR substitution")
    func liveLootPageAcceptsMeasuredTopDoubleTwo() {
        let measuredTopAdvance = rect(
            0.02463054162561577,
            0.19999999995006246,
            0.04433497536945812,
            0.008988764044943753
        )
        let result = GameStateClassifier.classify(observations: [
            observation("任務完成！", rect(0.38911, 0.10551, 0.21193, 0.02269)),
            observation("獲得拾得物", rect(0.77827, 0.14595, 0.19224, 0.02046)),
            observation("重複進行此任務", rect(0.02463, 0.23596, 0.28571, 0.02022)),
            OCRTextObservation(
                text: "SELECTED",
                rect: rect(0.36982, 0.22327, 0.25956, 0.03503),
                confidence: 0.50
            ),
            OCRTextObservation(
                text: "22",
                rect: measuredTopAdvance,
                confidence: 0.30000001192092896
            ),
        ])

        #expect(result.state == .missionCompleteRepeatSelected)
        #expect(result.evidence.map(\.kind).contains(.missionLootPage))
        #expect(result.allowedActions.map(\.name) == [.advanceMissionComplete])
        #expect(result.allowedActions.first?.target.sourceText == "22")
        #expect(result.allowedActions.first?.target.rect == measuredTopAdvance)
        #expect(result.allowedActions.first?.target.point == measuredTopAdvance.center)
    }

    @Test("Only the measured loot-page top 22 substitution is accepted")
    func invalidDoubleTwoSubstitutionsStop() {
        let observations = [
            observation("任務完成！", rect(0.38911, 0.10551, 0.21193, 0.02269)),
            observation("獲得拾得物", rect(0.77827, 0.14595, 0.19224, 0.02046)),
            observation("重複進行此任務", rect(0.02463, 0.23596, 0.28571, 0.02022)),
            OCRTextObservation(
                text: "SELECTED",
                rect: rect(0.36982, 0.22327, 0.25956, 0.03503),
                confidence: 0.50
            ),
        ]
        let candidates = [
            OCRTextObservation(
                text: "22",
                rect: rect(0.0246, 0.691, 0.048, 0.011),
                confidence: 1
            ),
            OCRTextObservation(
                text: "22",
                rect: rect(0.0246, 0.2000, 0.0443, 0.0090),
                confidence: 0.29
            ),
            OCRTextObservation(
                text: ">2",
                rect: rect(0.0246, 0.2000, 0.0443, 0.0090),
                confidence: 0.30
            ),
            OCRTextObservation(
                text: "22",
                rect: rect(0.10, 0.2000, 0.0443, 0.0090),
                confidence: 0.30
            ),
            OCRTextObservation(
                text: "22",
                rect: rect(0.0246, 0.2000, 0.10, 0.0090),
                confidence: 0.30
            ),
        ]

        for candidate in candidates {
            let result = GameStateClassifier.classify(observations: observations + [candidate])
            #expect(result.state == .missionCompleteRepeatSelected)
            #expect(result.allowedActions.isEmpty)
        }
    }

    @Test("The measured top 22 substitution is rejected on EXP and failure pages")
    func measuredTopDoubleTwoIsLootSuccessOnly() {
        let topDoubleTwo = OCRTextObservation(
            text: "22",
            rect: rect(0.02463, 0.2000, 0.04433, 0.00899),
            confidence: 0.30
        )
        let common = [
            observation("重複進行此任務", rect(0.02463, 0.23596, 0.28571, 0.02022)),
            OCRTextObservation(
                text: "SELECTED",
                rect: rect(0.36982, 0.22327, 0.25956, 0.03503),
                confidence: 0.50
            ),
            topDoubleTwo,
        ]
        let experience = GameStateClassifier.classify(observations: [
            observation("任務完成！", rect(0.38911, 0.10551, 0.21193, 0.02269)),
            observation("獲得經驗值", rect(0.77827, 0.14595, 0.19224, 0.02046)),
        ] + common)
        let failure = GameStateClassifier.classify(observations: [
            observation("任務失敗", rect(0.4089, 0.1056, 0.1773, 0.0225)),
        ] + common)

        #expect(experience.state == .missionCompleteRepeatSelected)
        #expect(experience.allowedActions.isEmpty)
        #expect(failure.state == .missionFailedRepeatSelected)
        #expect(failure.allowedActions.isEmpty)
    }

    @Test("Two measured top 22 substitutions are ambiguous and fail closed")
    func duplicateMeasuredTopDoubleTwoStops() {
        let result = GameStateClassifier.classify(observations: [
            observation("任務完成！", rect(0.38911, 0.10551, 0.21193, 0.02269)),
            observation("獲得拾得物", rect(0.77827, 0.14595, 0.19224, 0.02046)),
            observation("重複進行此任務", rect(0.02463, 0.23596, 0.28571, 0.02022)),
            observation("SELECTED", rect(0.36982, 0.22327, 0.25956, 0.03503)),
            observation("22", rect(0.02463, 0.2000, 0.04433, 0.00899)),
            observation("22", rect(0.02550, 0.1995, 0.04400, 0.00900)),
        ])

        #expect(result.state == .unknown)
        #expect(result.allowedActions.isEmpty)
        #expect(result.evidence.contains { $0.kind == .conflictingStateMarkers })
    }

    @Test("Conflicting successful result-page identities fail closed")
    func conflictingMissionSuccessPageIdentitiesStop() {
        let result = GameStateClassifier.classify(observations: [
            observation("任務完成！", rect(0.389, 0.105, 0.212, 0.023)),
            observation("獲得經驗值", rect(0.7783, 0.1461, 0.1921, 0.0202)),
            observation("獲得拾得物", rect(0.7782, 0.175, 0.1923, 0.0206)),
            observation(">>", rect(0.0246, 0.1978, 0.0443, 0.0112)),
            observation("重複進行此任務", rect(0.025, 0.236, 0.286, 0.020)),
            observation("SELECTED", rect(0.370, 0.223, 0.259, 0.035)),
        ])

        #expect(result.state == .unknown)
        #expect(result.allowedActions.isEmpty)
        #expect(result.evidence.contains { $0.kind == .conflictingStateMarkers })
    }

    @Test("Duplicate identical successful result-page headers fail closed")
    func duplicateMissionSuccessPageHeadersStop() {
        let result = GameStateClassifier.classify(observations: [
            observation("任務完成！", rect(0.389, 0.105, 0.212, 0.023)),
            observation("獲得經驗值", rect(0.778, 0.146, 0.192, 0.020)),
            observation("獲得經驗值", rect(0.750, 0.175, 0.192, 0.020)),
            observation(">>", rect(0.0246, 0.1978, 0.0443, 0.0112)),
            observation("重複進行此任務", rect(0.025, 0.236, 0.286, 0.020)),
            observation("SELECTED", rect(0.370, 0.223, 0.259, 0.035)),
        ])

        #expect(result.state == .unknown)
        #expect(result.allowedActions.isEmpty)
        #expect(result.evidence.contains { $0.kind == .conflictingStateMarkers })
    }

    @Test("A misplaced successful result-page header fails closed")
    func misplacedMissionSuccessPageHeaderStops() {
        let result = GameStateClassifier.classify(observations: [
            observation("任務完成！", rect(0.389, 0.105, 0.212, 0.023)),
            observation("獲得經驗值", rect(0.20, 0.50, 0.20, 0.03)),
            observation(">>", rect(0.0246, 0.1978, 0.0443, 0.0112)),
            observation("重複進行此任務", rect(0.025, 0.236, 0.286, 0.020)),
            observation("SELECTED", rect(0.370, 0.223, 0.259, 0.035)),
        ])

        #expect(result.state == .unknown)
        #expect(result.allowedActions.isEmpty)
        #expect(result.evidence.contains { $0.kind == .conflictingStateMarkers })
    }

    @Test("A low-confidence successful result-page header fails closed")
    func lowConfidenceMissionSuccessPageHeaderStops() {
        let result = GameStateClassifier.classify(observations: [
            observation("任務完成！", rect(0.389, 0.105, 0.212, 0.023)),
            OCRTextObservation(
                text: "獲得經驗值",
                rect: rect(0.778, 0.146, 0.192, 0.020),
                confidence: GameStateClassifier.minimumMarkerConfidence - 0.01
            ),
            observation(">>", rect(0.0246, 0.1978, 0.0443, 0.0112)),
            observation("重複進行此任務", rect(0.025, 0.236, 0.286, 0.020)),
            observation("SELECTED", rect(0.370, 0.223, 0.259, 0.035)),
        ])

        #expect(result.state == .unknown)
        #expect(result.allowedActions.isEmpty)
        #expect(result.evidence.allSatisfy { $0.kind == .lowConfidenceMarker })
    }

    @Test("Two plausible mission-failed top arrows fail closed")
    func ambiguousTopAdvanceArrowsStop() {
        let result = GameStateClassifier.classify(observations: [
            observation("任務失敗", rect(0.4089, 0.1056, 0.1773, 0.0225)),
            observation("重複進行此任務", rect(0.025, 0.236, 0.286, 0.020)),
            observation("SELECTED", rect(0.366, 0.223, 0.263, 0.037)),
            observation(">>", rect(0.025, 0.198, 0.044, 0.011)),
            observation(">>", rect(0.075, 0.198, 0.044, 0.011)),
        ])

        #expect(result.state == .unknown)
        #expect(result.allowedActions.isEmpty)
        #expect(result.evidence.contains { $0.kind == .conflictingStateMarkers })
    }

    @Test("A mission-failed top arrow outside the left-side gate is not actionable")
    func misplacedTopAdvanceArrowStops() {
        let result = GameStateClassifier.classify(observations: [
            observation("任務失敗", rect(0.4089, 0.1056, 0.1773, 0.0225)),
            observation("重複進行此任務", rect(0.025, 0.236, 0.286, 0.020)),
            observation("SELECTED", rect(0.366, 0.223, 0.263, 0.037)),
            observation(">>", rect(0.20, 0.198, 0.044, 0.011)),
        ])

        #expect(result.state == .missionFailedRepeatSelected)
        #expect(result.allowedActions.isEmpty)
    }

    @Test("A low-confidence advance glyph does not hide a clear repeat option")
    func lowConfidenceAdvanceIsIgnoredBeforeSelection() {
        let result = GameStateClassifier.classify(observations: [
            observation("任務完成！", rect(0.389, 0.105, 0.212, 0.023)),
            observation("重複進行此任務", rect(0.025, 0.236, 0.286, 0.020)),
            OCRTextObservation(
                text: ">>",
                rect: rect(0.025, 0.856, 0.044, 0.011),
                confidence: 0.20
            ),
        ])

        #expect(result.state == .missionComplete)
        #expect(result.allowedActions.map(\.name) == [.selectMissionRepeat])
    }

    @Test("A selected-like marker below its fixed threshold stops")
    func lowConfidenceSelectedVariantStops() {
        let result = GameStateClassifier.classify(observations: [
            observation("任務完成！", rect(0.389, 0.105, 0.212, 0.023)),
            observation("重複進行此任務", rect(0.025, 0.236, 0.286, 0.020)),
            OCRTextObservation(
                text: "ISELECTED",
                rect: rect(0.366, 0.223, 0.263, 0.037),
                confidence: GameStateClassifier.minimumActionGlyphConfidence - 0.01
            ),
        ])

        #expect(result.state == .unknown)
        #expect(result.allowedActions.isEmpty)
        #expect(result.evidence.map(\.kind) == [.lowConfidenceMarker])
    }

    @Test("A spatially unrelated SELECTED marker makes the result unknown")
    func unrelatedSelectedMarkerStops() {
        let result = GameStateClassifier.classify(observations: [
            observation("任務完成！", rect(0.31, 0.06, 0.38, 0.04)),
            observation("重複進行此任務", rect(0.03, 0.18, 0.31, 0.04)),
            observation("SELECTED", rect(0.40, 0.60, 0.25, 0.05)),
        ])

        #expect(result.state == .unknown)
        #expect(result.allowedActions.isEmpty)
        #expect(result.evidence.contains { $0.kind == .conflictingStateMarkers })
    }

    @Test("Mission failed exposes only the observed repeat option")
    func missionFailedAllowsSelectingRepeat() {
        let repeatRect = rect(0.0246, 0.2360, 0.2857, 0.0202)
        let result = GameStateClassifier.classify(observations: [
            observation("任務失敗", rect(0.4089, 0.1056, 0.1773, 0.0225)),
            OCRTextObservation(
                text: ">>",
                rect: rect(0.0246, 0.1978, 0.0443, 0.0112),
                confidence: 0.30
            ),
            observation("重複進行此任務", repeatRect),
        ])

        #expect(result.state == .missionFailed)
        #expect(result.allowedActions.count == 1)
        #expect(result.allowedActions.first?.name == .selectMissionRepeat)
        #expect(result.allowedActions.first?.target.name == .missionRepeatOption)
        #expect(result.allowedActions.first?.target.rect == repeatRect)
    }

    @Test("Mission failed without a repeat target remains stop-only")
    func missionFailedWithoutRepeatStops() {
        let result = GameStateClassifier.classify(observations: [
            observation("任務失敗！", rect(0.41, 0.10, 0.18, 0.03)),
        ])

        #expect(result.state == .missionFailed)
        #expect(result.allowedActions.isEmpty)
    }

    @Test("Duplicate mission-failed repeat targets fail closed")
    func duplicateMissionFailedRepeatTargetsStop() {
        let result = GameStateClassifier.classify(observations: [
            observation("任務失敗", rect(0.41, 0.10, 0.18, 0.03)),
            observation("重複進行此任務", rect(0.03, 0.20, 0.29, 0.03)),
            observation("重複進行此任務", rect(0.50, 0.20, 0.29, 0.03)),
        ])

        #expect(result.state == .unknown)
        #expect(result.allowedActions.isEmpty)
        #expect(result.evidence.contains { $0.kind == .conflictingStateMarkers })
    }

    @Test("Selected mission-failed repeat uses only the measured top advance marker")
    func selectedMissionFailedRepeatAllowsTopAdvance() {
        let topAdvance = rect(0.0246, 0.1978, 0.0443, 0.0112)
        let lowerAdvance = rect(0.0246, 0.5281, 0.0443, 0.0135)
        let result = GameStateClassifier.classify(observations: [
            observation("任務失敗", rect(0.41, 0.10, 0.18, 0.03)),
            observation("重複進行此任務", rect(0.0246, 0.2360, 0.2857, 0.0202)),
            OCRTextObservation(
                text: "SELECTED",
                rect: rect(0.3654, 0.2233, 0.2638, 0.0366),
                confidence: 0.50
            ),
            OCRTextObservation(
                text: ">>",
                rect: topAdvance,
                confidence: 0.30
            ),
            OCRTextObservation(
                text: ">>",
                rect: lowerAdvance,
                confidence: 0.30
            ),
        ])

        #expect(result.state == .missionFailedRepeatSelected)
        #expect(result.allowedActions.map(\.name) == [.advanceMissionComplete])
        #expect(result.allowedActions.first?.target.rect == topAdvance)
    }

    @Test("A mission-failed lower arrow is never accepted as its top advance action")
    func missionFailedLowerArrowStops() {
        let result = GameStateClassifier.classify(observations: [
            observation("任務失敗", rect(0.4089, 0.1056, 0.1773, 0.0225)),
            observation("重複進行此任務", rect(0.0246, 0.2360, 0.2857, 0.0202)),
            observation("SELECTED", rect(0.3654, 0.2233, 0.2638, 0.0366)),
            observation(">>", rect(0.0246, 0.5281, 0.0443, 0.0135)),
        ])

        #expect(result.state == .missionFailedRepeatSelected)
        #expect(result.allowedActions.isEmpty)
    }

    @Test("Mission-complete and mission-failed titles conflict")
    func conflictingMissionResultTitlesStop() {
        let result = GameStateClassifier.classify(observations: [
            observation("任務完成！", rect(0.31, 0.06, 0.38, 0.04)),
            observation("任務失敗", rect(0.41, 0.10, 0.18, 0.03)),
            observation("重複進行此任務", rect(0.03, 0.20, 0.29, 0.03)),
        ])

        #expect(result.state == .unknown)
        #expect(result.allowedActions.isEmpty)
        #expect(result.evidence.contains { $0.kind == .conflictingStateMarkers })
    }

    @Test("Generic defeat overrides an otherwise recoverable mission failure")
    func genericDefeatOverridesMissionFailed() {
        let result = GameStateClassifier.classify(observations: [
            observation("任務失敗", rect(0.41, 0.10, 0.18, 0.03)),
            observation("重複進行此任務", rect(0.03, 0.20, 0.29, 0.03)),
            observation("全滅", rect(0.42, 0.44, 0.16, 0.06)),
        ])

        #expect(result.state == .defeat)
        #expect(result.allowedActions.isEmpty)
    }

    @Test("A recognized battle exposes only its unique auto-battle control")
    func battleAllowsOnlyAutoBattle() {
        let autoRect = rect(0.23, 0.86, 0.14, 0.03)
        let result = GameStateClassifier.classify(observations: [
            observation("西部森林 跨河橋 -第1場戰鬥-", rect(0.20, 0.05, 0.60, 0.04)),
            observation("戰利品 0", rect(0.70, 0.10, 0.20, 0.04)),
            observation("全部自動", autoRect),
        ])

        #expect(result.state == .battle)
        #expect(result.allowedActions.map(\.name) == [.enableAutoBattle])
        #expect(result.allowedActions.first?.target.name == .battleAuto)
        #expect(result.allowedActions.first?.target.rect == autoRect)
        #expect(result.policyGatedActions.isEmpty)
        #expect(result.evidence.allSatisfy { $0.kind == .battleMarker })
    }

    @Test("The measured live OCR layout exposes auto and gates retreat")
    func liveBattleLayoutFallbackActions() {
        let retreatRect = rect(0.8424, 0.6584, 0.0690, 0.0180)
        let autoRect = rect(0.2313, 0.8693, 0.1285, 0.0187)
        let result = GameStateClassifier.classify(observations: [
            OCRTextObservation(
                text: "地下道出入口 近郊-第1場戰門-",
                rect: rect(0.0443, 0.1079, 0.4631, 0.0180),
                confidence: 0.30
            ),
            observation("戰利品", rect(0.8325, 0.1079, 0.1034, 0.0157)),
            OCRTextObservation(
                text: "Round 1",
                rect: rect(0.0345, 0.6292, 0.0936, 0.0112),
                confidence: 0.50
            ),
            observation("暫停", rect(0.8473, 0.6292, 0.0640, 0.0180)),
            OCRTextObservation(
                text: "撤退",
                rect: retreatRect,
                confidence: 0.50
            ),
            observation("全部自動", autoRect),
            OCRTextObservation(
                text: "技能>",
                rect: rect(0.4286, 0.8697, 0.0837, 0.0157),
                confidence: 0.30
            ),
            observation("跳過", rect(0.0739, 0.8697, 0.0690, 0.0180)),
        ])

        #expect(result.state == .battle)
        #expect(result.allowedActions.map(\.name) == [.enableAutoBattle])
        #expect(result.allowedActions.first?.target.name == .battleAuto)
        #expect(result.allowedActions.first?.target.rect == autoRect)
        #expect(result.policyGatedActions.map(\.name) == [.openBattleRetreatConfirmation])
        #expect(result.policyGatedActions.first?.target.name == .battleRetreat)
        #expect(result.policyGatedActions.first?.target.rect == retreatRect)
        #expect(result.policyGatedActions.first?.requirement == .temporalDefeatRecovery)
        #expect(result.evidence.allSatisfy { $0.kind == .battleMarker })
        #expect(result.evidence.contains { $0.observation?.text == "Round 1" })
        #expect(!result.evidence.contains { $0.observation?.text == "撤退" })
        #expect(!result.evidence.contains { $0.observation?.text == "技能>" })
    }

    @Test("Natural-defeat frames 03 and 04 remain recognized without Round OCR")
    func naturalDefeatNoRoundLiveFixturesRemainBattle() {
        for skillConfidence in [0.3000000119, 0.50] {
            let retreatRect = rect(0.8423645312, 0.6584269664, 0.0689655172, 0.0179775281)
            let autoRect = rect(0.2362655314, 0.8693514587, 0.1235280530, 0.0163532632)
            let result = GameStateClassifier.classify(observations: [
                OCRTextObservation(
                    text: "王國的病 -第3場戰門-",
                    rect: rect(0.0492610877, 0.1078651685, 0.3201970443, 0.0157303371),
                    confidence: 0.3000000119
                ),
                OCRTextObservation(
                    text: "第3場戰鬥",
                    rect: rect(0.20, 0.12, 0.20, 0.02),
                    confidence: 0.30
                ),
                observation("戰利品", rect(0.8325123166, 0.1078651685, 0.1034482759, 0.0157303371)),
                OCRTextObservation(
                    text: "Round 3",
                    rect: rect(0.0345, 0.6292, 0.0887, 0.0112),
                    confidence: 0.30
                ),
                observation("暫停", rect(0.8472906409, 0.6292134830, 0.0640394089, 0.0179775281)),
                OCRTextObservation(text: "撤退", rect: retreatRect, confidence: 0.50),
                observation("全部自動", autoRect),
                OCRTextObservation(
                    text: "技能>",
                    rect: rect(0.4285714272, 0.8696629215, 0.0837438424, 0.0157303371),
                    confidence: skillConfidence
                ),
            ])

            #expect(result.state == .battle)
            #expect(result.allowedActions.map(\.name) == [.enableAutoBattle])
            #expect(result.allowedActions.first?.target.rect == autoRect)
            #expect(result.policyGatedActions.map(\.name) == [.openBattleRetreatConfirmation])
            #expect(result.policyGatedActions.first?.target.rect == retreatRect)
        }
    }

    @Test("The exact low-confidence loot counter from the latest live battle remains recognized")
    func latestLiveLowConfidenceLootControlStackRemainsBattle() {
        let anchors = latestLiveLowConfidenceLootControlStackAnchors()
        let autoRect = anchors[3].rect
        let retreatRect = anchors[2].rect
        let result = GameStateClassifier.classify(observations: [
            OCRTextObservation(
                text: "地下道出入口 近郊 -第2場戰門-",
                rect: rect(
                    0.04926109146141195,
                    0.10786516850187267,
                    0.46305418719211827,
                    0.01573033707865168
                ),
                confidence: 0.5
            ),
        ] + anchors + [
            OCRTextObservation(
                text: "跳過",
                rect: rect(
                    0.0738916247536946,
                    0.8696629214606743,
                    0.06896551724137931,
                    0.017977528089887618
                ),
                confidence: 1
            ),
        ])

        #expect(result.state == .battle)
        #expect(result.allowedActions.map(\.name) == [.enableAutoBattle])
        #expect(result.allowedActions.first?.target.rect == autoRect)
        #expect(result.policyGatedActions.map(\.name) == [.openBattleRetreatConfirmation])
        #expect(result.policyGatedActions.first?.target.rect == retreatRect)
    }

    @Test("The low-confidence loot control-stack fallback remains fail-closed")
    func latestLiveLowConfidenceLootControlStackFailsClosed() {
        let anchors = latestLiveLowConfidenceLootControlStackAnchors()

        var belowLootFloor = anchors
        belowLootFloor[0] = OCRTextObservation(
            text: belowLootFloor[0].text,
            rect: belowLootFloor[0].rect,
            confidence: 0.299
        )
        assertUnknownWithoutActions(belowLootFloor)

        for missingIndex in anchors.indices {
            var incomplete = anchors
            incomplete.remove(at: missingIndex)
            assertUnknownWithoutActions(incomplete)
        }

        for duplicateIndex in anchors.indices {
            var duplicated = anchors
            duplicated.append(anchors[duplicateIndex])
            assertUnknownWithoutActions(duplicated)
        }

        for misplacedIndex in anchors.indices {
            var misplaced = anchors
            misplaced[misplacedIndex] = OCRTextObservation(
                text: misplaced[misplacedIndex].text,
                rect: rect(0.50, 0.35, 0.10, 0.02),
                confidence: misplaced[misplacedIndex].confidence
            )
            assertUnknownWithoutActions(misplaced)
        }
    }

    @Test("The live title-free battle control stack accepts its measured 0.50 pause")
    func liveControlStackAcceptsMeasuredPauseConfidence() {
        var anchors = latestLiveLowConfidenceLootControlStackAnchors()
        anchors[1] = OCRTextObservation(
            text: anchors[1].text,
            rect: anchors[1].rect,
            confidence: 0.50
        )

        let result = GameStateClassifier.classify(observations: anchors)

        #expect(result.state == .battle)
        #expect(result.allowedActions.map(\.name) == [.enableAutoBattle])
        #expect(result.policyGatedActions.map(\.name) == [.openBattleRetreatConfirmation])

        anchors[1] = OCRTextObservation(
            text: anchors[1].text,
            rect: anchors[1].rect,
            confidence: 0.499
        )
        assertUnknownWithoutActions(anchors)
    }

    @Test("Every no-Round control-stack anchor is unique, trusted, and layout-bound")
    func noRoundControlStackFallbackFailsClosed() {
        let anchors = noRoundBattleControlStackAnchors()

        for missingIndex in anchors.indices {
            var incomplete = anchors
            incomplete.remove(at: missingIndex)
            let result = GameStateClassifier.classify(observations: incomplete)

            #expect(result.state == .unknown)
            #expect(result.allowedActions.isEmpty)
            #expect(result.policyGatedActions.isEmpty)
        }

        for duplicateIndex in anchors.indices {
            var duplicated = anchors
            duplicated.append(anchors[duplicateIndex])
            let result = GameStateClassifier.classify(observations: duplicated)

            #expect(result.state == .unknown)
            #expect(result.allowedActions.isEmpty)
            #expect(result.policyGatedActions.isEmpty)
        }

        let belowThresholds = [0.299, 0.499, 0.49, 0.59]
        for index in anchors.indices {
            var below = anchors
            below[index] = OCRTextObservation(
                text: below[index].text,
                rect: below[index].rect,
                confidence: belowThresholds[index]
            )
            let result = GameStateClassifier.classify(observations: below)

            #expect(result.state == .unknown)
            #expect(result.allowedActions.isEmpty)
            #expect(result.policyGatedActions.isEmpty)
        }
    }

    @Test("Duplicate, misplaced, or low-confidence auto controls are never actionable")
    func ambiguousBattleAutoTargetsStop() {
        let base = [
            observation("西部森林 跨河橋 -第1場戰鬥-", rect(0.20, 0.05, 0.60, 0.04)),
            observation("戰利品 0", rect(0.70, 0.10, 0.20, 0.04)),
            observation("暫停", rect(0.84, 0.62, 0.08, 0.02)),
        ]
        let invalidSets: [[OCRTextObservation]] = [
            [
                observation("全部自動", rect(0.23, 0.86, 0.14, 0.03)),
                observation("全部自動", rect(0.25, 0.88, 0.14, 0.03)),
            ],
            [observation("全部自動", rect(0.70, 0.86, 0.14, 0.03))],
            [
                OCRTextObservation(
                    text: "全部自動",
                    rect: rect(0.23, 0.86, 0.14, 0.03),
                    confidence: GameStateClassifier.minimumMarkerConfidence - 0.01
                ),
            ],
        ]

        for invalid in invalidSets {
            let result = GameStateClassifier.classify(observations: base + invalid)

            #expect(result.state == .battle)
            #expect(result.allowedActions.isEmpty)
        }
    }

    @Test("A battle retreat target is policy-gated and never a default action")
    func battleRetreatTargetRequiresTemporalRecovery() {
        let retreatRect = rect(0.8424, 0.6584, 0.0690, 0.0180)
        let result = GameStateClassifier.classify(observations: [
            observation("西部森林 跨河橋 -第1場戰鬥-", rect(0.20, 0.05, 0.60, 0.04)),
            observation("戰利品 0", rect(0.70, 0.10, 0.20, 0.04)),
            observation("暫停", rect(0.84, 0.62, 0.08, 0.02)),
            OCRTextObservation(text: "撤退", rect: retreatRect, confidence: 0.50),
        ])

        #expect(result.state == .battle)
        #expect(result.allowedActions.isEmpty)
        #expect(result.policyGatedActions.map(\.name) == [.openBattleRetreatConfirmation])
        #expect(result.policyGatedActions.first?.target.name == .battleRetreat)
        #expect(result.policyGatedActions.first?.target.rect == retreatRect)
        #expect(result.policyGatedActions.first?.requirement == .temporalDefeatRecovery)
    }

    @Test("Ambiguous battle retreat targets are not exposed to recovery")
    func ambiguousBattleRetreatTargetsStop() {
        let base = [
            observation("西部森林 跨河橋 -第1場戰鬥-", rect(0.20, 0.05, 0.60, 0.04)),
            observation("戰利品 0", rect(0.70, 0.10, 0.20, 0.04)),
            observation("暫停", rect(0.84, 0.62, 0.08, 0.02)),
        ]
        let invalidSets: [[OCRTextObservation]] = [
            [
                observation("撤退", rect(0.842, 0.658, 0.069, 0.018)),
                observation("撤退", rect(0.840, 0.690, 0.069, 0.018)),
            ],
            [observation("撤退", rect(0.40, 0.65, 0.08, 0.02))],
            [
                OCRTextObservation(
                    text: "撤退",
                    rect: rect(0.842, 0.658, 0.069, 0.018),
                    confidence: 0.49
                ),
            ],
        ]

        for invalid in invalidSets {
            let result = GameStateClassifier.classify(observations: base + invalid)

            #expect(result.state == .battle)
            #expect(result.allowedActions.isEmpty)
            #expect(result.policyGatedActions.isEmpty)
        }
    }

    @Test("Every fallback battle anchor is required")
    func incompleteBattleLayoutFallbackStops() {
        let anchors = activeBattleFallbackAnchors()

        for missingIndex in anchors.indices {
            var incomplete = anchors
            incomplete.remove(at: missingIndex)
            let result = GameStateClassifier.classify(observations: incomplete)

            #expect(result.state == .unknown)
            #expect(result.allowedActions.isEmpty)
        }
    }

    @Test("Fallback battle anchors outside their expected regions do not confirm battle")
    func misplacedBattleLayoutFallbackStops() {
        let misplaced: [(index: Int, observation: OCRTextObservation)] = [
            (0, observation("戰利品", rect(0.10, 0.30, 0.10, 0.02))),
            (1, observation("Round 1", rect(0.60, 0.62, 0.10, 0.02))),
            (2, observation("暫停", rect(0.30, 0.62, 0.08, 0.02))),
            (3, observation("全部自動", rect(0.25, 0.50, 0.14, 0.02))),
        ]

        for replacement in misplaced {
            var anchors = activeBattleFallbackAnchors()
            anchors[replacement.index] = replacement.observation
            let result = GameStateClassifier.classify(observations: anchors)

            #expect(result.state == .unknown)
            #expect(result.allowedActions.isEmpty)
        }
    }

    @Test("Fallback battle confidence thresholds are inclusive and fail closed below them")
    func battleLayoutFallbackConfidenceThresholds() {
        var atThreshold = activeBattleFallbackAnchors()
        for markerIndex in [0, 2, 3] {
            atThreshold[markerIndex] = OCRTextObservation(
                text: atThreshold[markerIndex].text,
                rect: atThreshold[markerIndex].rect,
                confidence: GameStateClassifier.minimumMarkerConfidence
            )
        }
        let thresholdResult = GameStateClassifier.classify(observations: atThreshold)
        #expect(thresholdResult.state == .battle)
        #expect(thresholdResult.allowedActions.map(\.name) == [.enableAutoBattle])

        var lowRound = atThreshold
        lowRound[1] = OCRTextObservation(
            text: "Round 1",
            rect: lowRound[1].rect,
            confidence: 0.49
        )
        let lowRoundResult = GameStateClassifier.classify(observations: lowRound)
        #expect(lowRoundResult.state == .unknown)
        #expect(lowRoundResult.allowedActions.isEmpty)

        for markerIndex in [0, 2, 3] {
            var belowThreshold = atThreshold
            belowThreshold[markerIndex] = OCRTextObservation(
                text: belowThreshold[markerIndex].text,
                rect: belowThreshold[markerIndex].rect,
                confidence: GameStateClassifier.minimumMarkerConfidence - 0.01
            )
            let result = GameStateClassifier.classify(observations: belowThreshold)

            #expect(result.state == .unknown)
            #expect(result.allowedActions.isEmpty)
        }
    }

    @Test("Fallback battle markers conflict with a mission-complete title")
    func battleLayoutFallbackConflictsWithMissionComplete() {
        let result = GameStateClassifier.classify(observations: [
            observation("任務完成！", rect(0.31, 0.06, 0.38, 0.04)),
            observation("重複進行此任務", rect(0.03, 0.18, 0.31, 0.04)),
        ] + activeBattleFallbackAnchors())

        #expect(result.state == .unknown)
        #expect(result.allowedActions.isEmpty)
        #expect(result.evidence.contains { $0.kind == .conflictingStateMarkers })
    }

    @Test("Defeat overrides otherwise actionable mission-complete text")
    func defeatOverridesMissionComplete() {
        let result = GameStateClassifier.classify(observations: [
            observation("任務完成！", rect(0.31, 0.06, 0.38, 0.04)),
            observation("重複進行此任務", rect(0.03, 0.18, 0.31, 0.04)),
            observation("全滅", rect(0.42, 0.44, 0.16, 0.06)),
        ])

        #expect(result.state == .defeat)
        #expect(result.allowedActions.isEmpty)
    }

    @Test("Inventory full overrides otherwise actionable mission-complete text")
    func inventoryFullOverridesMissionComplete() {
        let result = GameStateClassifier.classify(observations: [
            observation("任務完成！", rect(0.31, 0.06, 0.38, 0.04)),
            observation("重複進行此任務", rect(0.03, 0.18, 0.31, 0.04)),
            observation("背包已滿", rect(0.31, 0.42, 0.38, 0.06)),
        ])

        #expect(result.state == .inventoryFull)
        #expect(result.allowedActions.isEmpty)
    }

    @Test("The measured loot collection modal exposes only its unique Yes control")
    func lootCollectionModalAllowsConfirming() {
        let yesRect = rect(0.48, 0.52, 0.04, 0.03)
        let result = GameStateClassifier.classify(observations: [
            observation("任務完成！", rect(0.39, 0.10, 0.21, 0.03)),
            observation("重複進行此任務", rect(0.02, 0.23, 0.29, 0.03)),
            observation("SELECTED", rect(0.37, 0.22, 0.26, 0.04)),
            observation("您確定嗎？", rect(0.40, 0.44, 0.19, 0.03)),
            observation("確定要獲取所有物品嗎？", rect(0.10, 0.48, 0.34, 0.02)),
            observation("是", yesRect),
            observation("否", rect(0.48, 0.55, 0.04, 0.03)),
        ])

        #expect(result.state == .lootCollectionConfirmation)
        #expect(result.allowedActions.map(\.name) == [.confirmLootCollection])
        #expect(result.allowedActions.first?.target.name == .lootConfirmationYes)
        #expect(result.allowedActions.first?.target.rect == yesRect)
        #expect(result.policyGatedActions.isEmpty)
        #expect(result.evidence.map(\.kind) == [.confirmationTitle, .lootCollectionPrompt])
    }

    @Test("Duplicate, misplaced, low-confidence, or incomplete loot Yes controls fail closed")
    func ambiguousLootConfirmationYesStops() {
        let modal = [
            observation("您確定嗎？", rect(0.4039, 0.4404, 0.1873, 0.0204)),
            observation("確定要獲取所有物品嗎？", rect(0.0985, 0.4764, 0.3350, 0.0180)),
        ]
        let no = observation("否", rect(0.4778, 0.5640, 0.0394, 0.0202))
        let invalidDecisionSets: [[OCRTextObservation]] = [
            [
                observation("是", rect(0.4778, 0.5213, 0.0394, 0.0180)),
                observation("是", rect(0.4750, 0.5350, 0.0394, 0.0180)),
                no,
            ],
            [observation("是", rect(0.20, 0.5213, 0.0394, 0.0180)), no],
            [
                OCRTextObservation(
                    text: "是",
                    rect: rect(0.4778, 0.5213, 0.0394, 0.0180),
                    confidence: GameStateClassifier.minimumMarkerConfidence - 0.01
                ),
                no,
            ],
            [observation("是", rect(0.4778, 0.5213, 0.0394, 0.0180))],
        ]

        for decisions in invalidDecisionSets {
            let result = GameStateClassifier.classify(observations: modal + decisions)

            #expect(result.state == .unknown)
            #expect(result.allowedActions.isEmpty)
            #expect(result.policyGatedActions.isEmpty)
        }
    }

    @Test("A conflicting state blocks loot confirmation")
    func conflictingStateBlocksLootConfirmation() {
        let modal = [
            observation("您確定嗎？", rect(0.4039, 0.4404, 0.1873, 0.0204)),
            observation("確定要獲取所有物品嗎？", rect(0.0985, 0.4764, 0.3350, 0.0180)),
            observation("是", rect(0.4778, 0.5213, 0.0394, 0.0180)),
            observation("否", rect(0.4778, 0.5640, 0.0394, 0.0202)),
        ]

        for blocker in [
            observation("背包已滿", rect(0.35, 0.40, 0.30, 0.04)),
            observation("撤退", rect(0.84, 0.65, 0.07, 0.02)),
            observation("遇到了新的冒險者", rect(0.34, 0.33, 0.31, 0.02)),
        ] {
            let result = GameStateClassifier.classify(observations: modal + [blocker])

            #expect(result.state == .unknown)
            #expect(result.allowedActions.isEmpty)
        }
    }

    @Test("A different all-items confirmation cannot borrow the loot Yes action")
    func nonLootAllItemsConfirmationStops() {
        let result = GameStateClassifier.classify(observations: [
            observation("您確定嗎？", rect(0.4039, 0.4404, 0.1873, 0.0204)),
            observation("確定要出售所有物品嗎？", rect(0.0985, 0.4764, 0.3350, 0.0180)),
            observation("是", rect(0.4778, 0.5213, 0.0394, 0.0180)),
            observation("否", rect(0.4778, 0.5640, 0.0394, 0.0202)),
        ])

        #expect(result.state == .unknown)
        #expect(result.allowedActions.isEmpty)
        #expect(result.policyGatedActions.isEmpty)
    }

    @Test("A partial modal marker fails closed")
    func partialModalStops() {
        let result = GameStateClassifier.classify(observations: [
            observation("任務完成！", rect(0.39, 0.10, 0.21, 0.03)),
            observation("重複進行此任務", rect(0.02, 0.23, 0.29, 0.03)),
            observation("您確定嗎？", rect(0.40, 0.44, 0.19, 0.03)),
        ])

        #expect(result.state == .unknown)
        #expect(result.allowedActions.isEmpty)
        #expect(result.evidence.contains { $0.kind == .conflictingStateMarkers })
    }

    @Test("Adventurer recruitment modal overrides the actionable background")
    func adventurerRecruitmentModalStops() {
        let result = GameStateClassifier.classify(observations: [
            observation("任務完成！", rect(0.39, 0.10, 0.21, 0.03)),
            observation("重複進行此任務", rect(0.02, 0.23, 0.29, 0.03)),
            observation("SELECTED", rect(0.37, 0.22, 0.26, 0.04)),
            observation(">>", rect(0.02, 0.85, 0.05, 0.02)),
            observation("遇到了新的冒險者", rect(0.27, 0.40, 0.46, 0.04)),
            observation("您想將這位冒險者迎入隊伍嗎？", rect(0.16, 0.47, 0.68, 0.04)),
        ])

        #expect(result.state == .adventurerRecruitment)
        #expect(result.allowedActions.isEmpty)
        #expect(result.evidence.map(\.kind) == [
            .adventurerRecruitmentTitle,
            .adventurerRecruitmentPrompt,
        ])
    }

    @Test("The unique high-confidence recruit option in the measured top ROI is whitelisted")
    func adventurerRecruitmentAllowsRecruiting() {
        let recruitRect = rect(0.4187, 0.6315, 0.1527, 0.0180)
        let leaveRect = rect(0.4581, 0.6742, 0.0788, 0.0202)
        let result = GameStateClassifier.classify(observations: [
            observation("遇到了新的冒險者", rect(0.34, 0.33, 0.31, 0.02)),
            observation("您想將這位冒險者迎入隊伍嗎？", rect(0.10, 0.37, 0.44, 0.02)),
            observation("招募入隊", recruitRect),
            observation("離開", leaveRect),
        ])

        #expect(result.state == .adventurerRecruitment)
        #expect(result.allowedActions.count == 1)
        #expect(result.allowedActions.first?.name == .recruitAdventurer)
        #expect(result.allowedActions.first?.target.name == .adventurerRecruit)
        #expect(result.allowedActions.first?.target.rect == recruitRect)
        #expect(result.allowedActions.first?.target.point == recruitRect.center)
    }

    @Test("A misplaced recruitment option is never whitelisted")
    func misplacedAdventurerRecruitStops() {
        let result = GameStateClassifier.classify(observations: [
            observation("遇到了新的冒險者", rect(0.34, 0.33, 0.31, 0.02)),
            observation("您想將這位冒險者迎入隊伍嗎？", rect(0.10, 0.37, 0.44, 0.02)),
            observation("招募入隊", rect(0.42, 0.50, 0.15, 0.02)),
            observation("離開", rect(0.4581, 0.6742, 0.0788, 0.0202)),
        ])

        #expect(result.state == .adventurerRecruitment)
        #expect(result.allowedActions.isEmpty)
    }

    @Test("A low-confidence recruitment option is never whitelisted")
    func lowConfidenceAdventurerRecruitStops() {
        let result = GameStateClassifier.classify(observations: [
            observation("遇到了新的冒險者", rect(0.34, 0.33, 0.31, 0.02)),
            observation("您想將這位冒險者迎入隊伍嗎？", rect(0.10, 0.37, 0.44, 0.02)),
            OCRTextObservation(
                text: "招募入隊",
                rect: rect(0.4187, 0.6315, 0.1527, 0.0180),
                confidence: GameStateClassifier.minimumMarkerConfidence - 0.01
            ),
            observation("離開", rect(0.4581, 0.6742, 0.0788, 0.0202)),
        ])

        #expect(result.state == .adventurerRecruitment)
        #expect(result.allowedActions.isEmpty)
    }

    @Test("Duplicate recruitment options are never whitelisted")
    func duplicateAdventurerRecruitStops() {
        let result = GameStateClassifier.classify(observations: [
            observation("遇到了新的冒險者", rect(0.34, 0.33, 0.31, 0.02)),
            observation("您想將這位冒險者迎入隊伍嗎？", rect(0.10, 0.37, 0.44, 0.02)),
            observation("招募入隊", rect(0.419, 0.631, 0.153, 0.018)),
            observation("招募入隊", rect(0.420, 0.640, 0.152, 0.018)),
            observation("離開", rect(0.458, 0.674, 0.079, 0.020)),
        ])

        #expect(result.state == .adventurerRecruitment)
        #expect(result.allowedActions.isEmpty)
    }

    @Test("A generic defeat marker blocks the recruitment action")
    func defeatMarkerBlocksAdventurerRecruit() {
        let result = GameStateClassifier.classify(observations: [
            observation("遇到了新的冒險者", rect(0.34, 0.33, 0.31, 0.02)),
            observation("您想將這位冒險者迎入隊伍嗎？", rect(0.10, 0.37, 0.44, 0.02)),
            observation("招募入隊", rect(0.419, 0.631, 0.153, 0.018)),
            observation("離開", rect(0.458, 0.674, 0.079, 0.020)),
            observation("全滅", rect(0.42, 0.44, 0.16, 0.06)),
        ])

        #expect(result.state == .adventurerRecruitment)
        #expect(result.allowedActions.isEmpty)
    }

    @Test("The legacy leave option alone never authorizes an auto-level action")
    func adventurerLeaveAloneStops() {
        let result = GameStateClassifier.classify(observations: [
            observation("遇到了新的冒險者", rect(0.34, 0.33, 0.31, 0.02)),
            observation("您想將這位冒險者迎入隊伍嗎？", rect(0.10, 0.37, 0.44, 0.02)),
            observation("離開", rect(0.4581, 0.6742, 0.0788, 0.0202)),
        ])

        #expect(result.state == .adventurerRecruitment)
        #expect(result.allowedActions.isEmpty)
    }

    @Test("A recruitment title without its prompt fails closed")
    func partialAdventurerRecruitmentTitleStops() {
        let result = GameStateClassifier.classify(observations: [
            observation("任務完成！", rect(0.39, 0.10, 0.21, 0.03)),
            observation("重複進行此任務", rect(0.02, 0.23, 0.29, 0.03)),
            observation("遇到了新的冒險者", rect(0.27, 0.40, 0.46, 0.04)),
        ])

        #expect(result.state == .unknown)
        #expect(result.allowedActions.isEmpty)
        #expect(result.evidence.contains { $0.kind == .adventurerRecruitmentTitle })
        #expect(result.evidence.contains { $0.kind == .conflictingStateMarkers })
    }

    @Test("A recruitment prompt without its title fails closed")
    func partialAdventurerRecruitmentPromptStops() {
        let result = GameStateClassifier.classify(observations: [
            observation("任務完成！", rect(0.39, 0.10, 0.21, 0.03)),
            observation("重複進行此任務", rect(0.02, 0.23, 0.29, 0.03)),
            observation("您想將這位冒險者迎入隊伍嗎？", rect(0.16, 0.47, 0.68, 0.04)),
        ])

        #expect(result.state == .unknown)
        #expect(result.allowedActions.isEmpty)
        #expect(result.evidence.contains { $0.kind == .adventurerRecruitmentPrompt })
        #expect(result.evidence.contains { $0.kind == .conflictingStateMarkers })
    }

    @Test("Measured defeat prompt exposes only its exact close target")
    func defeatPromptAllowsClose() {
        let result = GameStateClassifier.classify(observations: [
            OCRTextObservation(
                text: "隊伍已被擊敗⋯",
                rect: rect(0.10345, 0.49888, 0.22660, 0.01573),
                confidence: 0.3000000119
            ),
            OCRTextObservation(
                text: "關閉",
                rect: rect(0.45813, 0.54382, 0.07882, 0.01798),
                confidence: 0.3000000119
            ),
            OCRTextObservation(
                text: "Round 2",
                rect: rect(0.03448, 0.62921, 0.09360, 0.01124),
                confidence: 0.3000000119
            ),
            OCRTextObservation(
                text: "撤退",
                rect: rect(0.84236, 0.65843, 0.06897, 0.01798),
                confidence: 0.50
            ),
            OCRTextObservation(
                text: "否",
                rect: rect(0.47783, 0.58202, 0.03941, 0.01798),
                confidence: 0.30
            ),
        ])

        #expect(result.state == .defeatPrompt)
        #expect(result.allowedActions.map(\.name) == [.closeBattlePrompt])
        #expect(result.allowedActions.first?.target.name == .battlePromptClose)
        #expect(result.allowedActions.first?.target.sourceText == "關閉")
        #expect(result.evidence.map(\.kind) == [.defeatPromptMessage, .defeatPromptClose])
    }

    @Test("A partial defeat prompt fails closed")
    func partialDefeatPromptStops() {
        let result = GameStateClassifier.classify(observations: [
            OCRTextObservation(
                text: "隊伍已被擊敗⋯",
                rect: rect(0.10345, 0.49888, 0.22660, 0.01573),
                confidence: 0.30
            ),
        ])

        #expect(result.state == .unknown)
        #expect(result.allowedActions.isEmpty)
        #expect(result.evidence.contains { $0.kind == .conflictingStateMarkers })
    }

    @Test("Defeat prompt markers below their dedicated threshold fail closed")
    func lowConfidenceDefeatPromptStops() {
        let result = GameStateClassifier.classify(observations: [
            OCRTextObservation(
                text: "隊伍已被擊敗⋯",
                rect: rect(0.10345, 0.49888, 0.22660, 0.01573),
                confidence: 0.29
            ),
            OCRTextObservation(
                text: "關閉",
                rect: rect(0.45813, 0.54382, 0.07882, 0.01798),
                confidence: 0.30
            ),
        ])

        #expect(result.state == .unknown)
        #expect(result.allowedActions.isEmpty)
        #expect(result.evidence.map(\.kind) == [.lowConfidenceMarker])
    }

    @Test("Misplaced defeat prompt anchors fail closed")
    func misplacedDefeatPromptStops() {
        let misplacedPairs: [[OCRTextObservation]] = [
            [
                observation("隊伍已被擊敗⋯", rect(0.60, 0.20, 0.23, 0.02)),
                observation("關閉", rect(0.46, 0.54, 0.08, 0.02)),
            ],
            [
                observation("隊伍已被擊敗⋯", rect(0.10, 0.50, 0.23, 0.02)),
                observation("關閉", rect(0.80, 0.20, 0.08, 0.02)),
            ],
        ]

        for observations in misplacedPairs {
            let result = GameStateClassifier.classify(observations: observations)
            #expect(result.state == .unknown)
            #expect(result.allowedActions.isEmpty)
            #expect(result.evidence.contains { $0.kind == .conflictingStateMarkers })
        }
    }

    @Test("Measured retreat confirmation is recognized but never actionable")
    func retreatConfirmationStops() {
        let result = GameStateClassifier.classify(observations: [
            OCRTextObservation(
                text: "確認要撤退嗎？",
                rect: rect(0.09360, 0.46067, 0.21675, 0.01798),
                confidence: 0.50
            ),
            OCRTextObservation(
                text: "》 使用的護符將會丟失。",
                rect: rect(0.09852, 0.49438, 0.33498, 0.01798),
                confidence: 0.3000000119
            ),
            OCRTextObservation(
                text: "撤退",
                rect: rect(0.45813, 0.42472, 0.07882, 0.02022),
                confidence: 0.3000000119
            ),
        ])

        #expect(result.state == .retreatConfirmation)
        #expect(result.allowedActions.isEmpty)
        #expect(result.evidence.map(\.kind) == [
            .retreatConfirmationPrompt,
            .retreatCharmLossWarning,
        ])
    }

    @Test("The measured retreat Yes is exposed only as a no-talisman policy candidate")
    func retreatConfirmationGatesYesBehindNoTalismanPolicy() {
        let yesRect = rect(0.47783, 0.53708, 0.04433, 0.02022)
        let result = GameStateClassifier.classify(observations: [
            OCRTextObservation(
                text: "撤退",
                rect: rect(0.45813, 0.42472, 0.07882, 0.02022),
                confidence: 0.3000000119
            ),
            OCRTextObservation(
                text: "確認要撤退嗎？",
                rect: rect(0.09360, 0.46067, 0.21675, 0.01798),
                confidence: 0.50
            ),
            OCRTextObservation(
                text: "》 使用的護符將會丟失。",
                rect: rect(0.09852, 0.49438, 0.33498, 0.01798),
                confidence: 0.3000000119
            ),
            observation("是", yesRect),
            observation("否", rect(0.47783, 0.58202, 0.03941, 0.01798)),
            observation("暫停", rect(0.8473, 0.6292, 0.0640, 0.0180)),
            OCRTextObservation(
                text: "撤退",
                rect: rect(0.8424, 0.6584, 0.0690, 0.0180),
                confidence: 0.50
            ),
            observation("全部自動", rect(0.2365, 0.8697, 0.1232, 0.0157)),
        ])

        #expect(result.state == .retreatConfirmation)
        #expect(result.allowedActions.isEmpty)
        #expect(result.policyGatedActions.map(\.name) == [.confirmNoTalismanRetreat])
        #expect(result.policyGatedActions.first?.target.name == .retreatConfirmationYes)
        #expect(result.policyGatedActions.first?.target.rect == yesRect)
        #expect(result.policyGatedActions.first?.requirement == .verifiedNoTalismanRun)
    }

    @Test("Ambiguous retreat Yes controls are never exposed as policy candidates")
    func ambiguousRetreatConfirmationYesStops() {
        let modal = [
            observation("確認要撤退嗎？", rect(0.0936, 0.4607, 0.2168, 0.0180)),
            OCRTextObservation(
                text: "使用的護符將會丟失",
                rect: rect(0.0985, 0.4944, 0.3350, 0.0180),
                confidence: 0.30
            ),
        ]
        let no = observation("否", rect(0.4778, 0.5820, 0.0394, 0.0180))
        let invalidDecisionSets: [[OCRTextObservation]] = [
            [
                observation("是", rect(0.4778, 0.5371, 0.0443, 0.0202)),
                observation("是", rect(0.4750, 0.5500, 0.0443, 0.0202)),
                no,
            ],
            [observation("是", rect(0.20, 0.5371, 0.0443, 0.0202)), no],
            [
                OCRTextObservation(
                    text: "是",
                    rect: rect(0.4778, 0.5371, 0.0443, 0.0202),
                    confidence: GameStateClassifier.minimumMarkerConfidence - 0.01
                ),
                no,
            ],
            [observation("是", rect(0.4778, 0.5371, 0.0443, 0.0202))],
        ]

        for decisions in invalidDecisionSets {
            let result = GameStateClassifier.classify(observations: modal + decisions)

            #expect(result.state == .unknown)
            #expect(result.allowedActions.isEmpty)
            #expect(result.policyGatedActions.isEmpty)
        }
    }

    @Test("A partial retreat confirmation fails closed")
    func partialRetreatConfirmationStops() {
        let result = GameStateClassifier.classify(observations: [
            OCRTextObservation(
                text: "確認要撤退嗎？",
                rect: rect(0.09, 0.46, 0.22, 0.02),
                confidence: 0.50
            ),
        ])

        #expect(result.state == .unknown)
        #expect(result.allowedActions.isEmpty)
        #expect(result.evidence.contains { $0.kind == .conflictingStateMarkers })
    }

    @Test("Retreat confirmation markers below their dedicated threshold fail closed")
    func lowConfidenceRetreatConfirmationStops() {
        let result = GameStateClassifier.classify(observations: [
            OCRTextObservation(
                text: "確認要撤退嗎？",
                rect: rect(0.09, 0.46, 0.22, 0.02),
                confidence: 0.50
            ),
            OCRTextObservation(
                text: "使用的護符將會丟失",
                rect: rect(0.10, 0.49, 0.34, 0.02),
                confidence: 0.29
            ),
        ])

        #expect(result.state == .unknown)
        #expect(result.allowedActions.isEmpty)
        #expect(result.evidence.map(\.kind) == [.lowConfidenceMarker])
    }

    @Test("Battle event prompt takes priority over encounter partial matching")
    func battleEventPromptStops() {
        let result = GameStateClassifier.classify(observations: [
            observation(
                "魔怪發出輕微的吼叫，當場倒下。確保安全後向前進",
                rect(0.09852, 0.49888, 0.73892, 0.02247)
            ),
            OCRTextObservation(
                text: "關閉",
                rect: rect(0.45813, 0.54157, 0.07882, 0.02022),
                confidence: 0.50
            ),
        ])

        #expect(result.state == .battleEventPrompt)
        #expect(result.allowedActions.map(\.name) == [.closeBattlePrompt])
        #expect(result.allowedActions.first?.target.name == .battlePromptClose)
        #expect(result.evidence.map(\.kind) == [.battleEventDescription, .battleEventClose])
    }

    @Test("The exact live battle-event OCR fixture authorizes only close")
    func liveBattleEventPromptAllowsClose() {
        let closeRect = rect(
            0.4581280780788177,
            0.5415730334550561,
            0.0788177339901478,
            0.020224719101123667
        )
        let result = GameStateClassifier.classify(observations: [
            OCRTextObservation(
                text: "魔怪發出輕微的吼叫，當場倒下。確保安全後向前進",
                rect: rect(
                    0.09852216133004935,
                    0.4988764045692884,
                    0.7389162561576356,
                    0.022471910112359494
                ),
                confidence: 1.0
            ),
            OCRTextObservation(
                text: "關閉",
                rect: closeRect,
                confidence: 0.30000001192092896
            ),
        ])

        #expect(result.state == .battleEventPrompt)
        #expect(result.allowedActions.map(\.name) == [.closeBattlePrompt])
        #expect(result.allowedActions.first?.target.name == .battlePromptClose)
        #expect(result.allowedActions.first?.target.rect == closeRect)
        #expect(result.evidence.map(\.kind) == [.battleEventDescription, .battleEventClose])
    }

    @Test("Battle-event description and close use independent measured confidence floors")
    func lowConfidenceBattleEventRequiredAnchorsStop() {
        let descriptionRect = rect(0.10, 0.50, 0.74, 0.02)
        let closeRect = rect(0.46, 0.54, 0.08, 0.02)
        let lowAnchorSets: [[OCRTextObservation]] = [
            [
                OCRTextObservation(
                    text: "魔怪倒下了",
                    rect: descriptionRect,
                    confidence: 0.49
                ),
                OCRTextObservation(text: "關閉", rect: closeRect, confidence: 0.30),
            ],
            [
                OCRTextObservation(
                    text: "魔怪倒下了",
                    rect: descriptionRect,
                    confidence: 0.50
                ),
                OCRTextObservation(text: "關閉", rect: closeRect, confidence: 0.29),
            ],
        ]

        for observations in lowAnchorSets {
            let result = GameStateClassifier.classify(observations: observations)
            #expect(result.state == .unknown)
            #expect(result.allowedActions.isEmpty)
            #expect(result.evidence.map(\.kind) == [.lowConfidenceMarker])
        }
    }

    @Test("A partial battle event prompt fails closed")
    func partialBattleEventPromptStops() {
        let result = GameStateClassifier.classify(observations: [
            observation("魔怪倒下了", rect(0.10, 0.50, 0.40, 0.03)),
        ])

        #expect(result.state == .unknown)
        #expect(result.allowedActions.isEmpty)
        #expect(result.evidence.contains { $0.kind == .conflictingStateMarkers })
    }

    @Test("Duplicate battle event close markers fail closed")
    func duplicateBattleEventCloseMarkersStop() {
        let result = GameStateClassifier.classify(observations: [
            observation("魔怪倒下了", rect(0.10, 0.50, 0.40, 0.03)),
            observation("關閉", rect(0.46, 0.54, 0.08, 0.02)),
            observation("關閉", rect(0.46, 0.57, 0.08, 0.02)),
        ])

        #expect(result.state == .unknown)
        #expect(result.allowedActions.isEmpty)
        #expect(result.evidence.contains { $0.kind == .conflictingStateMarkers })
    }

    @Test("Battle encounter modal is recognized at the measured OCR confidence")
    func battleEncounterModalStops() {
        let result = GameStateClassifier.classify(observations: [
            OCRTextObservation(
                text: "<<Battle 1>>",
                rect: rect(0.10, 0.48, 0.20, 0.02),
                confidence: 0.50
            ),
            OCRTextObservation(
                text: "被暗處突如其來的魔怪襲擊了⋯⋯！",
                rect: rect(0.10, 0.51, 0.52, 0.03),
                confidence: 0.50
            ),
            OCRTextObservation(
                text: "關閉",
                rect: rect(0.46, 0.56, 0.08, 0.02),
                confidence: 0.50
            ),
            OCRTextObservation(
                text: "撤退",
                rect: rect(0.84, 0.65, 0.07, 0.02),
                confidence: 0.50
            ),
        ])

        #expect(result.state == .battleEncounterPrompt)
        #expect(result.allowedActions.map(\.name) == [.closeBattlePrompt])
        #expect(result.allowedActions.first?.target.name == .battlePromptClose)
        #expect(result.evidence.map(\.kind) == [
            .battleEncounterTitle,
            .battleEncounterDescription,
            .battleEncounterClose,
        ])
    }

    @Test("The exact live Battle 3 OCR fixture tolerates split narrative text")
    func liveBattleThreeEncounterModalStops() {
        let result = GameStateClassifier.classify(observations: [
            OCRTextObservation(
                text: "王國的病-第3場戰鬥-",
                rect: rect(0.0443349786, 0.1078651684, 0.3251231527, 0.0179775281),
                confidence: 0.30
            ),
            OCRTextObservation(
                text: "戰利品",
                rect: rect(0.8325123140, 0.1078651687, 0.1034482759, 0.0179775281),
                confidence: 0.50
            ),
            OCRTextObservation(
                text: "<<Battle 3>>",
                rect: rect(0.1034482792, 0.4584269661, 0.2019704433, 0.0134831461),
                confidence: 0.50
            ),
            OCRTextObservation(
                text: "「果然憑這種東西是擋不住嗎。」",
                rect: rect(0.1079241457, 0.4874934116, 0.4541613198, 0.0229733178),
                confidence: 1.00
            ),
            OCRTextObservation(
                text: "西奧多這樣低語著，一口氣跳躍起來向這邊襲擊過",
                rect: rect(0.0985221733, 0.5235955055, 0.6945812808, 0.0202247191),
                confidence: 0.50
            ),
            OCRTextObservation(
                text: "來⋯⋯！",
                rect: rect(0.1034482756, 0.5415730337, 0.1182266010, 0.0134831461),
                confidence: 0.30
            ),
            OCRTextObservation(
                text: "關閉",
                rect: rect(0.4581280780, 0.5865168540, 0.0788177340, 0.0179775281),
                confidence: 0.30
            ),
            OCRTextObservation(
                text: "暫停",
                rect: rect(0.8472906409, 0.6292134830, 0.0640394089, 0.0179775281),
                confidence: 0.50
            ),
            OCRTextObservation(
                text: "Round 1",
                rect: rect(0.0344827597, 0.6292134831, 0.0886699507, 0.0112359551),
                confidence: 0.50
            ),
            OCRTextObservation(
                text: "撤退",
                rect: rect(0.8423645312, 0.6584269664, 0.0689655172, 0.0179775281),
                confidence: 0.50
            ),
        ])

        #expect(result.state == .battleEncounterPrompt)
        #expect(result.allowedActions.map(\.name) == [.closeBattlePrompt])
        #expect(result.allowedActions.first?.target.name == .battlePromptClose)
        #expect(result.evidence.map(\.kind) == [
            .battleEncounterTitle,
            .battleEncounterClose,
        ])
    }

    @Test("Battle encounter titles accept a positive multi-digit battle number")
    func battleEncounterTitleGeneralizesBattleNumber() {
        let result = GameStateClassifier.classify(observations: [
            observation("<<Battle 12>>", rect(0.10, 0.48, 0.20, 0.02)),
            observation("一行含有魔怪襲擊的遭遇敘述", rect(0.10, 0.51, 0.52, 0.03)),
            observation("關閉", rect(0.46, 0.56, 0.08, 0.02)),
        ])

        #expect(result.state == .battleEncounterPrompt)
        #expect(result.allowedActions.map(\.name) == [.closeBattlePrompt])
    }

    @Test("Battle encounter descriptions accept measured magic-monster variants")
    func battleEncounterDescriptionVariants() {
        for description in [
            "發現了一群魔怪。出手製服！",
            "魔怪從背後猛撲過來！",
        ] {
            let result = GameStateClassifier.classify(observations: [
                observation("<<Battle 2>>", rect(0.10, 0.48, 0.20, 0.02)),
                observation(description, rect(0.10, 0.51, 0.52, 0.03)),
                observation("關閉", rect(0.46, 0.56, 0.08, 0.02)),
            ])

            #expect(result.state == .battleEncounterPrompt)
            #expect(result.allowedActions.map(\.name) == [.closeBattlePrompt])
            #expect(result.evidence.contains { $0.kind == .battleEncounterDescription })
        }
    }

    @Test("Unrecognized narrative text cannot veto a complete encounter anchor pair")
    func unexpectedBattleEncounterDescriptionIsNonAuthoritative() {
        let result = GameStateClassifier.classify(observations: [
            observation("<<Battle 2>>", rect(0.10, 0.48, 0.20, 0.02)),
            observation("前方似乎十分平靜", rect(0.10, 0.51, 0.52, 0.03)),
            observation("關閉", rect(0.46, 0.56, 0.08, 0.02)),
        ])

        #expect(result.state == .battleEncounterPrompt)
        #expect(result.allowedActions.map(\.name) == [.closeBattlePrompt])
        #expect(result.evidence.map(\.kind) == [
            .battleEncounterTitle,
            .battleEncounterClose,
        ])
    }

    @Test("A low-confidence narrative fragment never vetoes complete encounter anchors")
    func lowConfidenceBattleEncounterNarrativeIsNonAuthoritative() {
        let result = GameStateClassifier.classify(observations: [
            OCRTextObservation(
                text: "<<Battle 3>>",
                rect: rect(0.10, 0.46, 0.20, 0.02),
                confidence: 0.50
            ),
            OCRTextObservation(
                text: "來⋯⋯！",
                rect: rect(0.10, 0.54, 0.12, 0.014),
                confidence: 0.01
            ),
            OCRTextObservation(
                text: "關閉",
                rect: rect(0.46, 0.58, 0.08, 0.02),
                confidence: 0.30
            ),
        ])

        #expect(result.state == .battleEncounterPrompt)
        #expect(result.allowedActions.map(\.name) == [.closeBattlePrompt])
    }

    @Test("Encounter title and close use independent measured confidence floors")
    func lowConfidenceBattleEncounterRequiredAnchorsStop() {
        let lowAnchorSets: [[OCRTextObservation]] = [
            [
                OCRTextObservation(
                    text: "<<Battle 3>>",
                    rect: rect(0.10, 0.46, 0.20, 0.02),
                    confidence: 0.49
                ),
                OCRTextObservation(
                    text: "關閉",
                    rect: rect(0.46, 0.58, 0.08, 0.02),
                    confidence: 0.30
                ),
            ],
            [
                OCRTextObservation(
                    text: "<<Battle 3>>",
                    rect: rect(0.10, 0.46, 0.20, 0.02),
                    confidence: 0.50
                ),
                OCRTextObservation(
                    text: "關閉",
                    rect: rect(0.46, 0.58, 0.08, 0.02),
                    confidence: 0.29
                ),
            ],
        ]

        for observations in lowAnchorSets {
            let result = GameStateClassifier.classify(observations: observations)
            #expect(result.state == .unknown)
            #expect(result.allowedActions.isEmpty)
            #expect(result.evidence.map(\.kind) == [.lowConfidenceMarker])
        }
    }

    @Test("Encounter anchors cannot hide a conflicting mission-result marker")
    func conflictingBattleEncounterStateMarkerStops() {
        let result = GameStateClassifier.classify(observations: [
            OCRTextObservation(
                text: "<<Battle 3>>",
                rect: rect(0.10, 0.46, 0.20, 0.02),
                confidence: 0.50
            ),
            OCRTextObservation(
                text: "關閉",
                rect: rect(0.46, 0.58, 0.08, 0.02),
                confidence: 0.30
            ),
            observation("任務失敗", rect(0.41, 0.10, 0.18, 0.03)),
        ])

        #expect(result.state == .unknown)
        #expect(result.allowedActions.isEmpty)
        #expect(result.evidence.contains { $0.kind == .conflictingStateMarkers })
    }

    @Test("Malformed and non-positive battle labels are not encounter titles")
    func malformedBattleEncounterTitlesStop() {
        for text in ["<<Battle>>", "<<Battle 0>>", "<<Battle 3>", "Battle 3"] {
            let result = GameStateClassifier.classify(observations: [
                observation(text, rect(0.10, 0.46, 0.20, 0.02)),
                OCRTextObservation(
                    text: "關閉",
                    rect: rect(0.46, 0.58, 0.08, 0.02),
                    confidence: 0.30
                ),
            ])

            #expect(result.state == .unknown)
            #expect(result.allowedActions.isEmpty)
        }
    }

    @Test("Battle encounter title and close are sufficient when no description is present")
    func battleEncounterWithoutDescriptionStops() {
        let result = GameStateClassifier.classify(observations: [
            observation("<<Battle 2>>", rect(0.10, 0.48, 0.20, 0.02)),
            observation("關閉", rect(0.46, 0.54, 0.08, 0.02)),
        ])

        #expect(result.state == .battleEncounterPrompt)
        #expect(result.allowedActions.map(\.name) == [.closeBattlePrompt])
        #expect(result.evidence.map(\.kind) == [
            .battleEncounterTitle,
            .battleEncounterClose,
        ])
    }

    @Test("Returned-party text alone is non-actionable until geometry resolves its button")
    func returnedPartyRewardPromptNeedsGeometry() {
        let result = GameStateClassifier.classify(observations: [
            observation("成員列表", rect(0.61078, 0.10328, 0.12820, 0.01816)),
            observation(
                "有從派遣中返回的隊伍。讓我們領取獎勵吧！",
                rect(0.09852, 0.48090, 0.62562, 0.02022)
            ),
            OCRTextObservation(
                text: "關閉",
                rect: rect(0.45813, 0.52584, 0.07882, 0.02022),
                confidence: 0.50
            ),
            OCRTextObservation(
                text: "［關閉］",
                rect: rect(0.89163, 0.83596, 0.07389, 0.01124),
                confidence: 0.30
            ),
            observation("設置", rect(0.83251, 0.91236, 0.07882, 0.01798)),
            OCRTextObservation(
                text: "公會",
                rect: rect(0.07882, 0.91236, 0.07389, 0.01798),
                confidence: 0.30
            ),
            observation("商會", rect(0.26601, 0.91236, 0.07389, 0.01798)),
            observation("休息", rect(0.65025, 0.91236, 0.07389, 0.01798)),
            observation("探險", rect(0.45320, 0.91236, 0.07882, 0.01798)),
        ])

        #expect(result.state == .unknown)
        #expect(result.allowedActions.isEmpty)
        #expect(result.policyGatedActions.isEmpty)
        #expect(result.evidence.contains { $0.kind == .conflictingStateMarkers })
    }

    @Test("A title-free central close is actionable only with the measured battle fingerprint")
    func titleFreeBattlePromptAllowsClose() {
        let closeRect = rect(0.45813, 0.54157, 0.07882, 0.02022)
        let result = GameStateClassifier.classify(observations: [
            observation("前方傳來一陣奇怪的聲響⋯⋯", rect(0.10, 0.50, 0.60, 0.02)),
            OCRTextObservation(text: "關閉", rect: closeRect, confidence: 0.30),
        ] + battlePromptBackgroundAnchors())

        #expect(result.state == .battleEncounterPrompt)
        #expect(result.allowedActions.map(\.name) == [.closeBattlePrompt])
        #expect(result.allowedActions.first?.target.name == .battlePromptClose)
        #expect(result.allowedActions.first?.target.rect == closeRect)
        #expect(result.evidence.filter { $0.kind == .battleMarker }.count == 4)
        #expect(!result.evidence.contains { $0.kind == .battleEncounterTitle })
    }

    @Test("The exact live post-boss narrative is a narrowly recognized battle event")
    func livePostBossNarrativeAllowsClose() {
        let closeRect = rect(
            0.4581280780788177,
            0.5505617975,
            0.0788177339901478,
            0.020224719101123556
        )
        let result = GameStateClassifier.classify(observations: [
            OCRTextObservation(
                text: "利品",
                rect: rect(
                    0.8571428572614849,
                    0.10786516842696625,
                    0.06403941004147085,
                    0.017977528089887618
                ),
                confidence: 0.50
            ),
            observation(
                "擊退了魔怪。是這一帶的首領嗎？剩下的魔怪也四散逃走",
                rect(
                    0.0985221632512316,
                    0.48988764065168544,
                    0.7881773399014778,
                    0.020224719101123556
                )
            ),
            OCRTextObservation(text: "關閉", rect: closeRect, confidence: 0.30),
            OCRTextObservation(
                text: "Round 4",
                rect: rect(
                    0.034482758866995075,
                    0.6292134831772784,
                    0.08866995073891626,
                    0.011235955056179803
                ),
                confidence: 0.50
            ),
            OCRTextObservation(
                text: "暫停",
                rect: rect(
                    0.847290640851513,
                    0.6292134830497592,
                    0.0640394088669951,
                    0.017977528089887618
                ),
                confidence: 0.50
            ),
            OCRTextObservation(
                text: "撤退",
                rect: rect(
                    0.8423645311576354,
                    0.6584269664044945,
                    0.06896551724137934,
                    0.017977528089887618
                ),
                confidence: 0.50
            ),
        ])

        #expect(result.state == .battleEventPrompt)
        #expect(result.allowedActions.map(\.name) == [.closeBattlePrompt])
        #expect(result.allowedActions.first?.target.name == .battlePromptClose)
        #expect(result.allowedActions.first?.target.rect == closeRect)
        #expect(result.evidence.map(\.kind) == [
            .battleEventDescription,
            .battleEventClose,
        ])
    }

    @Test("Every post-boss narrative fragment is required in the same observation")
    func partialPostBossNarrativesStop() {
        let close = OCRTextObservation(
            text: "關閉",
            rect: rect(0.45813, 0.55056, 0.07882, 0.02022),
            confidence: 0.30
        )
        let clippedLoot = OCRTextObservation(
            text: "利品",
            rect: rect(0.85714, 0.10787, 0.06404, 0.01798),
            confidence: 0.50
        )
        let partialBackground = Array(battlePromptBackgroundAnchors().dropFirst().prefix(2))
        let incompleteNarratives = [
            "是這一帶的首領嗎？剩下的魔怪也四散逃走",
            "擊退了魔怪。剩下的魔怪也四散逃走",
            "擊退了魔怪。是這一帶的首領嗎？其他敵人也四散逃走",
            "擊退了魔怪。是這一帶的首領嗎？剩下的魔怪也逃走了",
        ]

        for narrative in incompleteNarratives {
            let result = GameStateClassifier.classify(
                observations: [
                    close,
                    clippedLoot,
                    observation(narrative, rect(0.10, 0.49, 0.78, 0.02)),
                ] + partialBackground
            )

            #expect(result.state == .unknown)
            #expect(result.allowedActions.isEmpty)
        }

        let unrelated = GameStateClassifier.classify(
            observations: [close, clippedLoot] + partialBackground
        )
        #expect(unrelated.state == .unknown)
        #expect(unrelated.allowedActions.isEmpty)
    }

    @Test("A low-confidence optional Battle 2 title falls back to the measured fingerprint")
    func lowConfidenceOptionalBattleTitleAllowsGenericClose() {
        let closeRect = rect(0.45813, 0.58652, 0.07882, 0.01798)
        let result = GameStateClassifier.classify(observations: [
            OCRTextObservation(
                text: "<<Battle 2>>",
                rect: rect(0.10345, 0.45843, 0.20197, 0.01348),
                confidence: 0.30
            ),
            OCRTextObservation(text: "關閉", rect: closeRect, confidence: 0.30),
        ] + battlePromptBackgroundAnchors())

        #expect(result.state == .battleEncounterPrompt)
        #expect(result.allowedActions.map(\.name) == [.closeBattlePrompt])
        #expect(result.allowedActions.first?.target.rect == closeRect)
        #expect(!result.evidence.contains { $0.kind == .lowConfidenceMarker })
        #expect(!result.evidence.contains { $0.kind == .battleEncounterTitle })
        #expect(result.evidence.filter { $0.kind == .battleMarker }.count == 4)
    }

    @Test("Duplicate low-confidence optional battle titles still fail closed")
    func duplicateLowConfidenceOptionalBattleTitlesStop() {
        let result = GameStateClassifier.classify(observations: [
            OCRTextObservation(
                text: "<<Battle 2>>",
                rect: rect(0.10345, 0.45843, 0.20197, 0.01348),
                confidence: 0.30
            ),
            OCRTextObservation(
                text: "<<Battle 2>>",
                rect: rect(0.11345, 0.47843, 0.20197, 0.01348),
                confidence: 0.30
            ),
            OCRTextObservation(
                text: "關閉",
                rect: rect(0.45813, 0.58652, 0.07882, 0.01798),
                confidence: 0.30
            ),
        ] + battlePromptBackgroundAnchors())

        #expect(result.state == .unknown)
        #expect(result.allowedActions.isEmpty)
        #expect(result.evidence.contains { $0.kind == .conflictingStateMarkers })
    }

    @Test("Every title-free battle-background anchor is required")
    func incompleteTitleFreeBattlePromptStops() {
        let close = OCRTextObservation(
            text: "關閉",
            rect: rect(0.46, 0.54, 0.08, 0.02),
            confidence: 0.30
        )
        let anchors = battlePromptBackgroundAnchors()

        for missingIndex in anchors.indices {
            var incomplete = anchors
            incomplete.remove(at: missingIndex)
            let result = GameStateClassifier.classify(observations: [close] + incomplete)

            #expect(result.state == .unknown)
            #expect(result.allowedActions.isEmpty)
        }
    }

    @Test("Title-free battle-background anchors use their dedicated measured floors")
    func titleFreeBattlePromptConfidenceFloors() {
        let close = OCRTextObservation(
            text: "關閉",
            rect: rect(0.46, 0.54, 0.08, 0.02),
            confidence: 0.30
        )
        let anchors = battlePromptBackgroundAnchors()
        let thresholdResult = GameStateClassifier.classify(observations: [close] + anchors)
        #expect(thresholdResult.state == .battleEncounterPrompt)
        #expect(thresholdResult.allowedActions.map(\.name) == [.closeBattlePrompt])

        let belowThresholds = [0.29, 0.49, 0.49, 0.49]
        for index in anchors.indices {
            var below = anchors
            below[index] = OCRTextObservation(
                text: below[index].text,
                rect: below[index].rect,
                confidence: belowThresholds[index]
            )
            let result = GameStateClassifier.classify(observations: [close] + below)

            #expect(result.state == .unknown)
            #expect(result.allowedActions.isEmpty)
        }
    }

    @Test("A title-free prompt rejects misplaced or duplicate close markers")
    func ambiguousTitleFreeBattlePromptCloseStops() {
        let background = battlePromptBackgroundAnchors()
        let closeSets: [[OCRTextObservation]] = [
            [observation("關閉", rect(0.80, 0.70, 0.08, 0.02))],
            [
                observation("關閉", rect(0.46, 0.54, 0.08, 0.02)),
                observation("關閉", rect(0.46, 0.57, 0.08, 0.02)),
            ],
        ]

        for closes in closeSets {
            let result = GameStateClassifier.classify(observations: closes + background)

            #expect(result.state == .unknown)
            #expect(result.allowedActions.isEmpty)
        }
    }

    @Test("A lone central close remains unknown")
    func loneCentralCloseStops() {
        let result = GameStateClassifier.classify(observations: [
            observation("關閉", rect(0.46, 0.54, 0.08, 0.02)),
        ])

        #expect(result.state == .unknown)
        #expect(result.allowedActions.isEmpty)
    }

    @Test("Sensitive or unrelated states cannot borrow the generic battle-close action")
    func conflictingTitleFreeBattlePromptStatesStop() {
        let closeAndBackground = [
            observation("關閉", rect(0.46, 0.54, 0.08, 0.02)),
        ] + battlePromptBackgroundAnchors()
        let conflictSets: [[OCRTextObservation]] = [
            [observation("任務完成！", rect(0.39, 0.10, 0.21, 0.03))],
            [observation("任務失敗", rect(0.41, 0.10, 0.18, 0.03))],
            [observation("背包已滿", rect(0.35, 0.40, 0.30, 0.04))],
            [observation("全滅", rect(0.42, 0.44, 0.16, 0.06))],
            [
                observation("遇到了新的冒險者", rect(0.34, 0.33, 0.31, 0.02)),
                observation("您想將這位冒險者迎入隊伍嗎？", rect(0.10, 0.37, 0.44, 0.02)),
                observation("離開", rect(0.458, 0.674, 0.079, 0.020)),
            ],
            [
                observation("您確定嗎？", rect(0.37, 0.39, 0.26, 0.03)),
                observation("確定要獲取所有物品嗎？", rect(0.20, 0.44, 0.60, 0.03)),
            ],
            [observation("全部出售", rect(0.80, 0.06, 0.17, 0.04))],
            [observation("購買", rect(0.40, 0.45, 0.20, 0.04))],
        ]

        for conflicts in conflictSets {
            let result = GameStateClassifier.classify(
                observations: closeAndBackground + conflicts
            )

            #expect(result.state != .battleEncounterPrompt)
            #expect(result.allowedActions.isEmpty)
        }
    }

    @Test("Retreat confirmation never borrows the generic battle-close action")
    func retreatConfirmationWithBattleBackgroundStops() {
        let result = GameStateClassifier.classify(observations: [
            observation("確認要撤退嗎？", rect(0.09, 0.46, 0.22, 0.02)),
            observation("使用的護符將會丟失", rect(0.10, 0.49, 0.34, 0.02)),
            observation("關閉", rect(0.46, 0.54, 0.08, 0.02)),
        ] + battlePromptBackgroundAnchors())

        #expect(result.state == .retreatConfirmation)
        #expect(result.allowedActions.isEmpty)
    }

    @Test("Battle event text keeps its specific state when battle context is also visible")
    func battleEventWithBackgroundAllowsOnlyClose() {
        let result = GameStateClassifier.classify(observations: [
            observation("魔怪發出輕微的吼叫，當場倒下。", rect(0.10, 0.50, 0.70, 0.02)),
            observation("關閉", rect(0.46, 0.54, 0.08, 0.02)),
        ] + battlePromptBackgroundAnchors())

        #expect(result.state == .battleEventPrompt)
        #expect(result.allowedActions.map(\.name) == [.closeBattlePrompt])
        #expect(result.allowedActions.first?.target.name == .battlePromptClose)
    }

    @Test("Defeat prompt keeps priority over the generic battle fingerprint")
    func defeatPromptWithBattleBackgroundAllowsOnlyClose() {
        let result = GameStateClassifier.classify(observations: [
            observation("隊伍已被擊敗⋯", rect(0.10, 0.50, 0.23, 0.02)),
            observation("關閉", rect(0.46, 0.54, 0.08, 0.02)),
        ] + battlePromptBackgroundAnchors())

        #expect(result.state == .defeatPrompt)
        #expect(result.allowedActions.map(\.name) == [.closeBattlePrompt])
        #expect(result.allowedActions.first?.target.name == .battlePromptClose)
    }

    @Test("A defeat prompt with a sensitive conflicting control fails closed")
    func conflictingDefeatPromptStops() {
        let prompt = [
            observation("隊伍已被擊敗⋯", rect(0.10, 0.50, 0.23, 0.02)),
            observation("關閉", rect(0.46, 0.54, 0.08, 0.02)),
        ] + battlePromptBackgroundAnchors()
        let sensitiveMarkers = [
            observation("購買", rect(0.40, 0.45, 0.20, 0.04)),
            observation("全部出售", rect(0.80, 0.06, 0.17, 0.04)),
            observation("您確定嗎？", rect(0.37, 0.39, 0.26, 0.03)),
            observation("使用的護符將會丟失", rect(0.10, 0.49, 0.34, 0.02)),
        ]

        for marker in sensitiveMarkers {
            let result = GameStateClassifier.classify(observations: prompt + [marker])

            #expect(result.state == .unknown)
            #expect(result.allowedActions.isEmpty)
            #expect(result.evidence.contains { $0.kind == .conflictingStateMarkers })
        }
    }

    @Test("Only one measured underlying No label is tolerated by a defeat prompt")
    func ambiguousDefeatDecisionLabelsStop() {
        let prompt = [
            observation("隊伍已被擊敗⋯", rect(0.10, 0.50, 0.23, 0.02)),
            observation("關閉", rect(0.45813, 0.54382, 0.07882, 0.01798)),
        ]
        let measuredNo = observation("否", rect(0.47783, 0.58202, 0.03941, 0.01798))
        let invalidDecisionSets: [[OCRTextObservation]] = [
            [observation("是", rect(0.47783, 0.58202, 0.03941, 0.01798))],
            [observation("否", rect(0.20, 0.40, 0.04, 0.02))],
            [
                measuredNo,
                observation("否", rect(0.47783, 0.61, 0.03941, 0.01798)),
            ],
            [
                measuredNo,
                observation("是", rect(0.47783, 0.61, 0.03941, 0.01798)),
            ],
        ]

        for decisions in invalidDecisionSets {
            let result = GameStateClassifier.classify(observations: prompt + decisions)

            #expect(result.state == .unknown)
            #expect(result.allowedActions.isEmpty)
            #expect(result.evidence.contains { $0.kind == .conflictingStateMarkers })
        }
    }

    @Test("Encounter close-only and title-only observations fail closed")
    func isolatedBattleEncounterAnchorsStop() {
        let partials: [[OCRTextObservation]] = [
            [observation("<<Battle 2>>", rect(0.10, 0.48, 0.20, 0.02))],
            [observation("關閉", rect(0.46, 0.54, 0.08, 0.02))],
        ]

        for observations in partials {
            let result = GameStateClassifier.classify(observations: observations)
            #expect(result.state == .unknown)
            #expect(result.allowedActions.isEmpty)
            #expect(result.evidence.contains { $0.kind == .conflictingStateMarkers })
        }
    }

    @Test("Misplaced encounter anchors fail closed")
    func misplacedBattleEncounterAnchorsStop() {
        let misplacedPairs: [[OCRTextObservation]] = [
            [
                observation("<<Battle 2>>", rect(0.60, 0.20, 0.20, 0.02)),
                observation("關閉", rect(0.46, 0.54, 0.08, 0.02)),
            ],
            [
                observation("<<Battle 2>>", rect(0.10, 0.48, 0.20, 0.02)),
                observation("關閉", rect(0.80, 0.70, 0.08, 0.02)),
            ],
        ]

        for observations in misplacedPairs {
            let result = GameStateClassifier.classify(observations: observations)
            #expect(result.state == .unknown)
            #expect(result.allowedActions.isEmpty)
            #expect(result.evidence.contains { $0.kind == .conflictingStateMarkers })
        }
    }

    @Test("Duplicate encounter title or close anchors fail closed")
    func duplicateBattleEncounterAnchorsStop() {
        let duplicateSets: [[OCRTextObservation]] = [
            [
                observation("<<Battle 2>>", rect(0.10, 0.48, 0.20, 0.02)),
                observation("<<Battle 2>>", rect(0.12, 0.50, 0.20, 0.02)),
                observation("關閉", rect(0.46, 0.54, 0.08, 0.02)),
            ],
            [
                observation("<<Battle 2>>", rect(0.10, 0.48, 0.20, 0.02)),
                observation("關閉", rect(0.46, 0.54, 0.08, 0.02)),
                observation("關閉", rect(0.46, 0.57, 0.08, 0.02)),
            ],
        ]

        for observations in duplicateSets {
            let result = GameStateClassifier.classify(observations: observations)
            #expect(result.state == .unknown)
            #expect(result.allowedActions.isEmpty)
            #expect(result.evidence.contains { $0.kind == .conflictingStateMarkers })
        }
    }

    @Test("A partial battle encounter modal fails closed")
    func partialBattleEncounterModalStops() {
        let result = GameStateClassifier.classify(observations: [
            observation("任務完成！", rect(0.39, 0.10, 0.21, 0.03)),
            observation("重複進行此任務", rect(0.02, 0.23, 0.29, 0.03)),
            observation("<<Battle 2>>", rect(0.10, 0.48, 0.20, 0.02)),
            observation("遭到魔怪襲擊了！", rect(0.10, 0.51, 0.52, 0.03)),
        ])

        #expect(result.state == .unknown)
        #expect(result.allowedActions.isEmpty)
        #expect(result.evidence.contains { $0.kind == .battleEncounterTitle })
        #expect(result.evidence.contains { $0.kind == .battleEncounterDescription })
        #expect(result.evidence.contains { $0.kind == .conflictingStateMarkers })
    }

    @Test("Conflicting battle and mission markers stop")
    func conflictingStatesStop() {
        let result = GameStateClassifier.classify(observations: [
            observation("任務完成！", rect(0.31, 0.06, 0.38, 0.04)),
            observation("第2場戰鬥", rect(0.31, 0.06, 0.38, 0.04)),
            observation("戰利品 3", rect(0.70, 0.10, 0.20, 0.04)),
            observation("撤退", rect(0.76, 0.80, 0.18, 0.05)),
        ])

        #expect(result.state == .unknown)
        #expect(result.allowedActions.isEmpty)
        #expect(result.evidence.contains { $0.kind == .conflictingStateMarkers })
    }

    @Test("A single battle-like control is not enough to classify battle")
    func incompleteBattleEvidenceStops() {
        let result = GameStateClassifier.classify(observations: [
            observation("全部自動", rect(0.72, 0.80, 0.20, 0.05)),
        ])

        #expect(result.state == .unknown)
        #expect(result.allowedActions.isEmpty)
    }

    @Test("Ambiguous duplicate action targets stop")
    func duplicateTargetsStop() {
        let result = GameStateClassifier.classify(observations: [
            observation("任務完成！", rect(0.31, 0.06, 0.38, 0.04)),
            observation("重複進行此任務", rect(0.03, 0.18, 0.31, 0.04)),
            observation("重複進行此任務", rect(0.50, 0.18, 0.31, 0.04)),
        ])

        #expect(result.state == .unknown)
        #expect(result.allowedActions.isEmpty)
        #expect(result.evidence.contains { $0.kind == .conflictingStateMarkers })
    }

    @Test("Mission title outside its expected top region stays unknown")
    func misplacedMissionTitleStops() {
        let result = GameStateClassifier.classify(observations: [
            observation("任務完成！", rect(0.31, 0.56, 0.38, 0.04)),
            observation("重複進行此任務", rect(0.03, 0.18, 0.31, 0.04)),
        ])

        #expect(result.state == .unknown)
        #expect(result.allowedActions.isEmpty)
    }

    @Test("Invalid normalized geometry always stops")
    func invalidGeometryStops() {
        let result = GameStateClassifier.classify(observations: [
            observation("任務完成！", rect(0.31, 0.06, 0.80, 0.04)),
            observation("重複進行此任務", rect(0.03, 0.18, 0.31, 0.04)),
        ])

        #expect(result.state == .unknown)
        #expect(result.allowedActions.isEmpty)
        #expect(result.evidence.map(\.kind) == [.invalidObservation])
    }

    @Test("Similar text and dangerous controls do not become actions")
    func nearMatchesRemainUnknown() {
        let result = GameStateClassifier.classify(observations: [
            observation("任務完成度", rect(0.31, 0.06, 0.38, 0.04)),
            observation("全部出售", rect(0.80, 0.06, 0.17, 0.04)),
            observation("重複進行其他任務", rect(0.03, 0.18, 0.35, 0.04)),
        ])

        #expect(result.state == .unknown)
        #expect(result.allowedActions.isEmpty)
        #expect(result.evidence.isEmpty)
    }

    @Test("A low-confidence known marker always stops")
    func lowConfidenceMarkerStops() {
        let result = GameStateClassifier.classify(observations: [
            OCRTextObservation(
                text: "任務完成！",
                rect: rect(0.31, 0.06, 0.38, 0.04),
                confidence: GameStateClassifier.minimumMarkerConfidence - 0.01
            ),
            observation("重複進行此任務", rect(0.03, 0.18, 0.31, 0.04)),
        ])

        #expect(result.state == .unknown)
        #expect(result.allowedActions.isEmpty)
        #expect(result.evidence.map(\.kind) == [.lowConfidenceMarker])
    }

    private func activeBattleFallbackAnchors() -> [OCRTextObservation] {
        [
            observation("戰利品", rect(0.83, 0.10, 0.10, 0.02)),
            OCRTextObservation(
                text: "Round 1",
                rect: rect(0.03, 0.62, 0.10, 0.02),
                confidence: 0.50
            ),
            observation("暫停", rect(0.84, 0.62, 0.08, 0.02)),
            observation("全部自動", rect(0.23, 0.86, 0.14, 0.03)),
        ]
    }

    private func noRoundBattleControlStackAnchors() -> [OCRTextObservation] {
        [
            observation("戰利品", rect(0.8325, 0.1079, 0.1034, 0.0157)),
            observation("暫停", rect(0.8473, 0.6292, 0.0640, 0.0180)),
            OCRTextObservation(
                text: "撤退",
                rect: rect(0.8424, 0.6584, 0.0690, 0.0180),
                confidence: 0.50
            ),
            observation("全部自動", rect(0.2363, 0.8694, 0.1235, 0.0164)),
        ]
    }

    private func latestLiveLowConfidenceLootControlStackAnchors() -> [OCRTextObservation] {
        [
            OCRTextObservation(
                text: "戰利品 3",
                rect: rect(
                    0.8374384219827585,
                    0.10786516865168538,
                    0.13300492610837444,
                    0.013483146067415741
                ),
                confidence: 0.30000001192092896
            ),
            OCRTextObservation(
                text: "暫停",
                rect: rect(
                    0.847290640851513,
                    0.6292134830497592,
                    0.0640394088669951,
                    0.017977528089887618
                ),
                confidence: 1
            ),
            OCRTextObservation(
                text: "撤退",
                rect: rect(
                    0.8423645311576354,
                    0.6584269664044945,
                    0.06896551724137934,
                    0.017977528089887618
                ),
                confidence: 0.5
            ),
            OCRTextObservation(
                text: "全部自動",
                rect: rect(
                    0.23645320320197044,
                    0.8696629212359551,
                    0.12315270935960593,
                    0.01573033707865168
                ),
                confidence: 1
            ),
        ]
    }

    private func assertUnknownWithoutActions(_ observations: [OCRTextObservation]) {
        let result = GameStateClassifier.classify(observations: observations)
        #expect(result.state == .unknown)
        #expect(result.allowedActions.isEmpty)
        #expect(result.policyGatedActions.isEmpty)
    }

    private func battlePromptBackgroundAnchors() -> [OCRTextObservation] {
        [
            OCRTextObservation(
                text: "戰利品 5",
                rect: rect(0.8374, 0.1079, 0.1330, 0.0157),
                confidence: 0.30
            ),
            OCRTextObservation(
                text: "Round 4",
                rect: rect(0.0345, 0.6292, 0.0887, 0.0112),
                confidence: 0.50
            ),
            OCRTextObservation(
                text: "暫停",
                rect: rect(0.8473, 0.6292, 0.0640, 0.0180),
                confidence: 0.50
            ),
            OCRTextObservation(
                text: "撤退",
                rect: rect(0.8424, 0.6584, 0.0690, 0.0180),
                confidence: 0.50
            ),
        ]
    }

    private func zeroOCRLiveLootObservations() -> [OCRTextObservation] {
        [
            OCRTextObservation(
                text: "任務完成！",
                rect: rect(
                    0.3891067804403232,
                    0.10550803805301134,
                    0.21193422589983257,
                    0.02269178776258829
                ),
                confidence: 1
            ),
            OCRTextObservation(
                text: "獲得拾得物",
                rect: rect(
                    0.7783251214285715,
                    0.14606741552808988,
                    0.1921182266009852,
                    0.020224719101123556
                ),
                confidence: 1
            ),
            OCRTextObservation(
                text: "重複進行此任務",
                rect: rect(
                    0.024630543912737477,
                    0.23595505606741574,
                    0.2857142857142857,
                    0.020224719101123556
                ),
                confidence: 1
            ),
            OCRTextObservation(
                text: "SELECTED",
                rect: rect(
                    0.36982343572043463,
                    0.2232546383556393,
                    0.26002105938389963,
                    0.035046082400204126
                ),
                confidence: 0.5
            ),
            // These real whole-frame observations demonstrate that digits embedded in ordinary
            // status and loot-row text do not masquerade as standalone arrow-like candidates.
            OCRTextObservation(
                text: "2:37$",
                rect: rect(0.0985221681, 0.0629213481, 0.1477832512, 0.0202247191),
                confidence: 0.3
            ),
            observation("全部出售", rect(0.8124748884, 0.1073584793, 0.1287448019, 0.0189909067)),
            OCRTextObservation(
                text: "女22（探索采集品）",
                rect: rect(0.0295566526, 0.3438202246, 0.2315270936, 0.0134831461),
                confidence: 0.3
            ),
        ]
    }

    private func observation(_ text: String, _ rect: NormalizedRect) -> OCRTextObservation {
        OCRTextObservation(text: text, rect: rect, confidence: 1)
    }

    private func rect(
        _ x: Double,
        _ y: Double,
        _ width: Double,
        _ height: Double
    ) -> NormalizedRect {
        NormalizedRect(x: x, y: y, width: width, height: height)
    }
}
