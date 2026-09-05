import Foundation
import Testing
@testable import MirrorProbeCore

@Suite("Character reroll detector")
struct CharacterRerollDetectorTests {
    @Test("Captured 406 by 890 OCR replays as the total 69 roll")
    func capturedLiveOCRReplay() throws {
        let fixture: CharacterRerollLiveFixture = try loadFixture("character-reroll-live")

        #expect(fixture.imageWidth == 406)
        #expect(fixture.imageHeight == 890)
        #expect(
            fixture.sourceCapture
                == "DevelopmentFixtures/CharacterReroll/total-69-ocr.json"
        )
        #expect(CharacterRerollDetector.detect(
            observations: fixture.observations,
            minimumTotal: 100
        ) == .rerollRequired(
            roll: CharacterRoll(name: "LIONEL", total: 69),
            target: expectedTarget
        ))
    }

    @Test("A live frame with an omitted red stat remains usable because stats are ignored")
    func omittedStatLiveReplay() throws {
        let fixture: CharacterRerollSupplementalLiveFixture = try loadFixture(
            "character-reroll-missing-red-live"
        )

        let primary = CharacterRerollDetector.detect(
            observations: fixture.primaryObservations,
            minimumTotal: 100
        )
        let withIrrelevantSupplement = CharacterRerollDetector.detect(
            observations: fixture.primaryObservations + fixture.supplementalObservations,
            minimumTotal: 100
        )

        guard case let .rerollRequired(roll, target) = primary else {
            Issue.record("Expected the primary OCR snapshot to authorize Random")
            return
        }
        #expect(roll == CharacterRoll(name: "BRUNO", total: 76))
        #expect(target.sourceText == "隨機")
        #expect(target.point == CharacterRerollDetector.measuredRandomButtonPoint)
        #expect(withIrrelevantSupplement == primary)
    }

    @Test("The fixed three-digit boundary rerolls 99 and stops at 100 through 125")
    func threeDigitBoundary() {
        #expect(isReroll(CharacterRerollDetector.detect(
            observations: validObservations(total: 99),
            minimumTotal: 100
        ), total: 99))

        for total in [100, 101, 125] {
            #expect(CharacterRerollDetector.detect(
                observations: validObservations(total: total),
                minimumTotal: 100
            ) == .thresholdReached(roll: CharacterRoll(name: "LIONEL", total: total)))
        }
    }

    @Test("The preliminary OCR decision supports bounded 90 through 100 thresholds")
    func boundedThresholds() {
        for minimum in [90, 95, 99, 100] {
            #expect(isReroll(CharacterRerollDetector.detect(
                observations: validObservations(total: minimum - 1),
                minimumTotal: minimum
            ), total: minimum - 1))
            #expect(CharacterRerollDetector.detect(
                observations: validObservations(total: minimum),
                minimumTotal: minimum
            ) == .thresholdReached(roll: CharacterRoll(name: "LIONEL", total: minimum)))
        }
    }

    @Test("Thresholds outside 90 through 100 fail closed", arguments: [0, 89, 101, 125])
    func otherMinimumFailsClosed(minimum: Int) {
        #expect(CharacterRerollDetector.detect(
            observations: validObservations(),
            minimumTotal: minimum
        ) == .unsafe(reason: .invalidMinimumTotal))
    }

    @Test("Every required page anchor is mandatory")
    func missingAnchorFailsClosed() {
        let requiredTexts = [
            "姓名/種族/信仰", "隨機", "姓名：Lionel", "狀態", "total: 73",
            "請分配點數", "決定", "重置",
        ]

        for missing in requiredTexts {
            let observations = validObservations().filter { $0.text != missing }
            #expect(isUnsafe(CharacterRerollDetector.detect(
                observations: observations,
                minimumTotal: 100
            )), Comment(rawValue: "Missing \(missing) must be unsafe"))
        }
    }

    @Test("Anchor, name, and provisional total confidence floors fail closed below their values")
    func confidenceFloors() {
        let unsafeVariants = [
            replacing(validObservations(), text: "姓名/種族/信仰", confidence: 0.59),
            replacing(validObservations(), text: "姓名：Lionel", confidence: 0.29),
            replacing(validObservations(), text: "隨機", confidence: 0.49),
            replacing(validObservations(), text: "total: 73", confidence: 0.29),
        ]
        for observations in unsafeVariants {
            #expect(isUnsafe(CharacterRerollDetector.detect(
                observations: observations,
                minimumTotal: 100
            )))
        }

        let measuredFloors = replacing(
            replacing(
                replacing(validObservations(), text: "姓名：Lionel", confidence: 0.30),
                text: "隨機",
                confidence: 0.50
            ),
            text: "total: 73",
            confidence: 0.30
        )
        #expect(isReroll(CharacterRerollDetector.detect(
            observations: measuredFloors,
            minimumTotal: 100
        ), total: 73))
    }

    @Test("A measured low-confidence total is provisional without lowering the Random floor")
    func lowConfidenceTotalIsProvisional() {
        let liveConfidence = replacing(
            validObservations(total: 66),
            text: "total: 66",
            confidence: 0.30000001192092896
        )
        #expect(isReroll(CharacterRerollDetector.detect(
            observations: liveConfidence,
            minimumTotal: 100
        ), total: 66))

        let belowFloor = replacing(
            validObservations(total: 66),
            text: "total: 66",
            confidence: 0.2999
        )
        #expect(CharacterRerollDetector.detect(
            observations: belowFloor,
            minimumTotal: 100
        ) == .unsafe(reason: .lowConfidenceAnchor))

        let reached = replacing(
            validObservations(total: 100),
            text: "total: 100",
            confidence: 0.30
        )
        #expect(CharacterRerollDetector.detect(
            observations: reached,
            minimumTotal: 100
        ) == .thresholdReached(roll: CharacterRoll(name: "LIONEL", total: 100)))

        let weakRandom = replacing(
            replacing(
                validObservations(total: 66),
                text: "total: 66",
                confidence: 0.30
            ),
            text: "隨機",
            confidence: 0.49
        )
        #expect(CharacterRerollDetector.detect(
            observations: weakRandom,
            minimumTotal: 100
        ) == .unsafe(reason: .lowConfidenceAnchor))
    }

    @Test("Random must stay within its calibrated top-right control")
    func misplacedRandomFailsClosed() {
        let observations = replacing(
            validObservations(),
            text: "隨機",
            rect: rect(0.45, 0.108, 0.07, 0.018)
        )

        #expect(CharacterRerollDetector.detect(
            observations: observations,
            minimumTotal: 100
        ) == .unsafe(reason: .misplacedAnchor))
    }

    @Test("Duplicate total observations are ambiguous")
    func duplicateTotalFailsClosed() {
        var observations = validObservations()
        observations.append(observation("TOTAL: 73", totalRect, confidence: 0.5))

        #expect(CharacterRerollDetector.detect(
            observations: observations,
            minimumTotal: 100
        ) == .unsafe(reason: .incompleteOrAmbiguousAnchor))
    }

    @Test("Total parsing accepts compatibility characters but rejects guesses")
    func totalGrammarIsExact() {
        let compatible = replacing(
            validObservations(),
            text: "total: 73",
            replacementText: " ＴＯＴＡＬ ： 73 "
        )
        #expect(isReroll(CharacterRerollDetector.detect(
            observations: compatible,
            minimumTotal: 100
        ), total: 73))

        for malformed in [
            "total: 7O", "Base Total: 73", "total: -1", "total: 073", "total: 73 points",
        ] {
            let observations = replacing(
                validObservations(),
                text: "total: 73",
                replacementText: malformed
            )
            #expect(isUnsafe(CharacterRerollDetector.detect(
                observations: observations,
                minimumTotal: 100
            )), Comment(rawValue: malformed))
        }

        let outOfRange = replacing(
            validObservations(),
            text: "total: 73",
            replacementText: "total: 126"
        )
        #expect(CharacterRerollDetector.detect(
            observations: outOfRange,
            minimumTotal: 100
        ) == .unsafe(reason: .totalOutOfRange))
    }

    @Test("Split and merged name rows resolve to the same semantic roll")
    func splitAndMergedNameRowsAreEqual() {
        let merged = CharacterRerollDetector.detect(
            observations: validObservations(),
            minimumTotal: 100
        )
        let splitObservations = validObservations().flatMap { item -> [OCRTextObservation] in
            guard item.text == "姓名：Lionel" else { return [item] }
            return [
                observation("姓名：", rect(0.0246, 0.1551, 0.1000, 0.0202)),
                observation("Lionel", rect(0.1300, 0.1551, 0.1450, 0.0202)),
            ]
        }
        let split = CharacterRerollDetector.detect(
            observations: splitObservations,
            minimumTotal: 100
        )

        #expect(split == merged)
    }

    @Test("The name row must be complete, correctly placed, and unambiguous")
    func nameRowFailsClosed() {
        let malformed = replacing(
            validObservations(),
            text: "姓名：Lionel",
            replacementText: "姓名："
        )
        #expect(CharacterRerollDetector.detect(
            observations: malformed,
            minimumTotal: 100
        ) == .unsafe(reason: .malformedIdentity))

        let misplaced = replacing(
            validObservations(),
            text: "姓名：Lionel",
            rect: rect(0.30, 0.1551, 0.2512, 0.0202)
        )
        #expect(CharacterRerollDetector.detect(
            observations: misplaced,
            minimumTotal: 100
        ) == .unsafe(reason: .misplacedIdentity))

        var ambiguous = validObservations()
        ambiguous.append(observation("其他", rect(0.50, 0.1551, 0.08, 0.0202)))
        #expect(isUnsafe(CharacterRerollDetector.detect(
            observations: ambiguous,
            minimumTotal: 100
        )))
    }

    @Test("Profession, race, faith, stats, and remaining points are ignored")
    func unrelatedCharacterFieldsAreIgnored() {
        let baseline = CharacterRerollDetector.detect(
            observations: validObservations(),
            minimumTotal: 100
        )
        var noisy = validObservations()
        noisy.append(contentsOf: [
            observation("職業：占星師", rect(0.02, 0.19, 0.35, 0.02), confidence: 0.01),
            observation("種族：狼人", rect(0.02, 0.23, 0.30, 0.02), confidence: 0.01),
            observation("信仰：時神", rect(0.02, 0.27, 0.30, 0.02), confidence: 0.01),
            observation("VIT（耐力）：3", rect(0.02, 0.41, 0.35, 0.02), confidence: 0.01),
            observation("（每項參數最高可達25，剩餘28）", rect(0.49, 0.60, 0.46, 0.02), confidence: 0.01),
        ])

        #expect(CharacterRerollDetector.detect(
            observations: noisy,
            minimumTotal: 100
        ) == baseline)
    }

    @Test("An invalid OCR observation poisons the whole snapshot")
    func invalidObservationFailsClosed() {
        var invalidRect = validObservations()
        invalidRect.append(observation("unrelated", rect(-0.01, 0.8, 0.1, 0.02)))
        var invalidConfidence = validObservations()
        invalidConfidence.append(observation(
            "unrelated",
            rect(0.1, 0.8, 0.1, 0.02),
            confidence: .nan
        ))

        for observations in [invalidRect, invalidConfidence] {
            #expect(CharacterRerollDetector.detect(
                observations: observations,
                minimumTotal: 100
            ) == .unsafe(reason: .invalidObservation))
        }
    }

    private let randomRect = NormalizedRect(
        x: 0.8423645313300493,
        y: 0.10786516862921347,
        width: 0.06896551724137934,
        height: 0.017977528089887618
    )
    private let totalRect = NormalizedRect(
        x: 0.8078817806420737,
        y: 0.3213483144569289,
        width: 0.15270935021010534,
        height: 0.01348314606741563
    )

    private var expectedTarget: CharacterRerollTarget {
        CharacterRerollTarget(
            sourceText: "隨機",
            rect: randomRect,
            point: CharacterRerollDetector.measuredRandomButtonPoint
        )
    }

    private func validObservations(total: Int = 73) -> [OCRTextObservation] {
        [
            observation("姓名/種族/信仰", rect(0.3448, 0.1056, 0.3054, 0.0225)),
            observation("隨機", randomRect, confidence: 0.5),
            observation("姓名：Lionel", rect(0.0246, 0.1551, 0.2512, 0.0202)),
            observation("狀態", rect(0.4532, 0.3169, 0.0887, 0.0225)),
            observation("total: \(total)", totalRect, confidence: 0.5),
            observation("請分配點數", rect(0.8078, 0.3616, 0.1579, 0.0162), confidence: 0.5),
            observation("決定", rect(0.4631, 0.6494, 0.0690, 0.0180), confidence: 0.5),
            observation("重置", rect(0.4631, 0.6921, 0.0690, 0.0180)),
        ]
    }

    private func replacing(
        _ observations: [OCRTextObservation],
        text: String,
        replacementText: String? = nil,
        rect replacementRect: NormalizedRect? = nil,
        confidence replacementConfidence: Double? = nil
    ) -> [OCRTextObservation] {
        observations.map { item in
            guard item.text == text else { return item }
            return observation(
                replacementText ?? item.text,
                replacementRect ?? item.rect,
                confidence: replacementConfidence ?? item.confidence
            )
        }
    }

    private func isUnsafe(_ decision: CharacterRerollDecision) -> Bool {
        if case .unsafe = decision { return true }
        return false
    }

    private func isReroll(_ decision: CharacterRerollDecision, total: Int) -> Bool {
        guard case let .rerollRequired(roll, target) = decision else { return false }
        return roll == CharacterRoll(name: "LIONEL", total: total)
            && target == expectedTarget
    }

    private func observation(
        _ text: String,
        _ rect: NormalizedRect,
        confidence: Double = 1
    ) -> OCRTextObservation {
        OCRTextObservation(text: text, rect: rect, confidence: confidence)
    }

    private func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double)
        -> NormalizedRect
    {
        NormalizedRect(x: x, y: y, width: width, height: height)
    }

    private func loadFixture<T: Decodable>(_ name: String) throws -> T {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json"))
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }
}

private struct CharacterRerollLiveFixture: Decodable {
    let sourceCapture: String
    let imageWidth: Int
    let imageHeight: Int
    let observations: [OCRTextObservation]
}

private struct CharacterRerollSupplementalLiveFixture: Decodable {
    let primaryObservations: [OCRTextObservation]
    let supplementalObservations: [OCRTextObservation]
}
