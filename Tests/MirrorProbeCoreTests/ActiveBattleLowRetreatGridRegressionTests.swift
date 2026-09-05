import Foundation
import Testing
@testable import MirrorProbeCore

@Suite("Active battle low-retreat control-grid regression")
struct ActiveBattleLowRetreatGridRegressionTests {
    private let anchorNames = ["戰利品", "暫停", "撤退", "跳過", "全部自動"]

    @Test("A measured battle accepts a 0.30 retreat marker only with the full corroborating grid")
    func lowConfidenceRetreatWithFullGridRemainsBattle() throws {
        let observations = try liveObservations()
        let retreat = try #require(observation(named: "撤退", in: observations))
        let automatic = try #require(observation(named: "全部自動", in: observations))
        let result = GameStateClassifier.classify(observations: observations)

        #expect(retreat.confidence >= 0.30)
        #expect(retreat.confidence < 0.50)
        #expect(result.state == .battle)
        #expect(result.allowedActions.map(\.name) == [.enableAutoBattle])
        #expect(result.allowedActions.first?.target.rect == automatic.rect)
        #expect(result.policyGatedActions.isEmpty)
        #expect(result.evidence.count == 5)
        #expect(Set(result.evidence.compactMap { $0.observation?.text }) == Set(anchorNames))
    }

    @Test("Every low-retreat fallback anchor must remain unique and present")
    func everyAnchorMustRemainUniqueAndPresent() throws {
        let observations = try liveObservations()

        for name in anchorNames {
            assertUnknownWithoutActions(
                observations.filter { $0.text != name },
                comment: "missing \(name)"
            )

            let duplicate = try #require(observation(named: name, in: observations))
            assertUnknownWithoutActions(
                observations + [duplicate],
                comment: "duplicate \(name)"
            )
        }
    }

    @Test("Every low-retreat fallback anchor must remain trusted and layout-bound")
    func everyAnchorMustRemainTrustedAndLayoutBound() throws {
        let observations = try liveObservations()

        for name in anchorNames {
            let misplaced = replacing(name, in: observations) { item in
                OCRTextObservation(
                    text: item.text,
                    rect: NormalizedRect(x: 0.45, y: 0.35, width: 0.10, height: 0.02),
                    confidence: item.confidence
                )
            }
            assertUnknownWithoutActions(misplaced, comment: "misplaced \(name)")
        }

        let confidenceFloors = [
            "戰利品": 0.599,
            "暫停": 0.499,
            "撤退": 0.299,
            "跳過": 0.599,
            "全部自動": 0.599,
        ]
        for (name, confidence) in confidenceFloors {
            let belowFloor = replacing(name, in: observations) { item in
                OCRTextObservation(text: item.text, rect: item.rect, confidence: confidence)
            }
            assertUnknownWithoutActions(belowFloor, comment: "below confidence floor: \(name)")
        }
    }

    @Test("The low-retreat grid must preserve both measured control orderings")
    func gridOrderingMustRemainMeasured() throws {
        let observations = try liveObservations()
        let pause = try #require(observation(named: "暫停", in: observations))
        let retreat = try #require(observation(named: "撤退", in: observations))
        let skip = try #require(observation(named: "跳過", in: observations))
        let automatic = try #require(observation(named: "全部自動", in: observations))

        let reversedRightStack = observations.map { item in
            switch item.text {
            case "暫停":
                OCRTextObservation(text: item.text, rect: retreat.rect, confidence: item.confidence)
            case "撤退":
                OCRTextObservation(text: item.text, rect: pause.rect, confidence: item.confidence)
            default:
                item
            }
        }
        assertUnknownWithoutActions(reversedRightStack, comment: "reversed right stack")

        let reversedBottomRow = observations.map { item in
            switch item.text {
            case "跳過":
                OCRTextObservation(text: item.text, rect: automatic.rect, confidence: item.confidence)
            case "全部自動":
                OCRTextObservation(text: item.text, rect: skip.rect, confidence: item.confidence)
            default:
                item
            }
        }
        assertUnknownWithoutActions(reversedBottomRow, comment: "reversed bottom row")

        let separatedRightStack = replacing("撤退", in: observations) { item in
            OCRTextObservation(
                text: item.text,
                rect: NormalizedRect(
                    x: item.rect.x,
                    y: 0.72,
                    width: item.rect.width,
                    height: item.rect.height
                ),
                confidence: item.confidence
            )
        }
        assertUnknownWithoutActions(separatedRightStack, comment: "separated right stack")

        let misalignedRightStack = replacing("撤退", in: observations) { item in
            OCRTextObservation(
                text: item.text,
                rect: NormalizedRect(
                    x: 0.75,
                    y: item.rect.y,
                    width: item.rect.width,
                    height: item.rect.height
                ),
                confidence: item.confidence
            )
        }
        assertUnknownWithoutActions(misalignedRightStack, comment: "misaligned right stack")

        let separatedBottomRow = replacing("全部自動", in: observations) { item in
            OCRTextObservation(
                text: item.text,
                rect: NormalizedRect(
                    x: item.rect.x,
                    y: 0.83,
                    width: item.rect.width,
                    height: item.rect.height
                ),
                confidence: item.confidence
            )
        }
        assertUnknownWithoutActions(separatedBottomRow, comment: "separated bottom row")

        let crowdedBottomRow = replacing("跳過", in: observations) { item in
            OCRTextObservation(
                text: item.text,
                rect: NormalizedRect(
                    x: 0.164,
                    y: item.rect.y,
                    width: item.rect.width,
                    height: item.rect.height
                ),
                confidence: item.confidence
            )
        }
        assertUnknownWithoutActions(crowdedBottomRow, comment: "crowded bottom row")
    }

    @Test("A conflicting mission result keeps the low-retreat frame fail-closed")
    func conflictingResultRemainsUnknown() throws {
        let observations = try liveObservations()
        let conflictingResult = observations + [OCRTextObservation(
            text: "任務完成！",
            rect: NormalizedRect(x: 0.31, y: 0.06, width: 0.38, height: 0.04),
            confidence: 1
        )]

        assertUnknownWithoutActions(conflictingResult, comment: "conflicting result")
    }

    private func liveObservations() throws -> [OCRTextObservation] {
        let url = try #require(Bundle.module.url(
            forResource: "active-battle-low-retreat-grid-analysis",
            withExtension: "json"
        ))
        let fixture = try JSONDecoder().decode(
            LowRetreatBattleAnalysisFixture.self,
            from: Data(contentsOf: url)
        )
        return fixture.ocr.observations
    }

    private func observation(
        named name: String,
        in observations: [OCRTextObservation]
    ) -> OCRTextObservation? {
        let matches = observations.filter { $0.text == name }
        return matches.count == 1 ? matches[0] : nil
    }

    private func replacing(
        _ name: String,
        in observations: [OCRTextObservation],
        with replacement: (OCRTextObservation) -> OCRTextObservation
    ) -> [OCRTextObservation] {
        observations.map { item in
            item.text == name ? replacement(item) : item
        }
    }

    private func assertUnknownWithoutActions(
        _ observations: [OCRTextObservation],
        comment: String
    ) {
        let result = GameStateClassifier.classify(observations: observations)
        #expect(result.state == .unknown, Comment(rawValue: comment))
        #expect(result.allowedActions.isEmpty, Comment(rawValue: comment))
        #expect(result.policyGatedActions.isEmpty, Comment(rawValue: comment))
    }
}

private struct LowRetreatBattleAnalysisFixture: Decodable {
    let ocr: OCR

    struct OCR: Decodable {
        let observations: [OCRTextObservation]
    }
}
