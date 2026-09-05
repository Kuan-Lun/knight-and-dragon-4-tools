import Foundation
import Testing
@testable import MirrorProbeCore

@Suite("Active battle control-grid regression")
struct ActiveBattleControlGridRegressionTests {
    @Test("A live battle survives simultaneous title and loot-prefix OCR loss")
    func liveBattleWithDamagedHeaderRemainsBattle() throws {
        let observations = try liveObservations()
        let result = GameStateClassifier.classify(observations: observations)

        #expect(result.state == .battle)
        #expect(result.allowedActions.map(\.name) == [.enableAutoBattle])
        #expect(result.policyGatedActions.map(\.name) == [.openBattleRetreatConfirmation])
        #expect(result.allowedActions.first?.target.rect == observation(named: "全部自動", in: observations)?.rect)
        #expect(result.policyGatedActions.first?.target.rect == observation(named: "撤退", in: observations)?.rect)
        #expect(result.evidence.count == 4)
        #expect(Set(result.evidence.compactMap { $0.observation?.text }) == [
            "暫停", "撤退", "跳過", "全部自動",
        ])
    }

    @Test("Every control-grid fallback anchor remains unique trusted and layout-bound")
    func controlGridFailsClosed() throws {
        let observations = try liveObservations()
        let names = ["暫停", "撤退", "跳過", "全部自動"]

        for name in names {
            assertUnknownWithoutActions(observations.filter { $0.text != name })

            let duplicated = try #require(observation(named: name, in: observations))
            assertUnknownWithoutActions(observations + [duplicated])

            let misplaced = observations.map { item in
                guard item.text == name else { return item }
                return OCRTextObservation(
                    text: item.text,
                    rect: NormalizedRect(x: 0.45, y: 0.35, width: 0.10, height: 0.02),
                    confidence: item.confidence
                )
            }
            assertUnknownWithoutActions(misplaced)
        }

        let confidenceFloors = [
            "暫停": 0.499,
            "撤退": 0.499,
            "跳過": 0.599,
            "全部自動": 0.599,
        ]
        for (name, confidence) in confidenceFloors {
            let belowFloor = observations.map { item in
                guard item.text == name else { return item }
                return OCRTextObservation(
                    text: item.text,
                    rect: item.rect,
                    confidence: confidence
                )
            }
            assertUnknownWithoutActions(belowFloor)
        }
    }

    @Test("The right stack and bottom row must keep their measured ordering")
    func controlGridOrderingFailsClosed() throws {
        let observations = try liveObservations()
        let pause = try #require(observation(named: "暫停", in: observations))
        let retreat = try #require(observation(named: "撤退", in: observations))
        let skip = try #require(observation(named: "跳過", in: observations))
        let automatic = try #require(observation(named: "全部自動", in: observations))

        let reversedRightStack = observations.map { item in
            switch item.text {
            case "暫停":
                return OCRTextObservation(text: item.text, rect: retreat.rect, confidence: item.confidence)
            case "撤退":
                return OCRTextObservation(text: item.text, rect: pause.rect, confidence: item.confidence)
            default:
                return item
            }
        }
        assertUnknownWithoutActions(reversedRightStack)

        let reversedBottomRow = observations.map { item in
            switch item.text {
            case "跳過":
                return OCRTextObservation(text: item.text, rect: automatic.rect, confidence: item.confidence)
            case "全部自動":
                return OCRTextObservation(text: item.text, rect: skip.rect, confidence: item.confidence)
            default:
                return item
            }
        }
        assertUnknownWithoutActions(reversedBottomRow)

        let separatedRightStack = observations.map { item in
            guard item.text == "撤退" else { return item }
            return OCRTextObservation(
                text: item.text,
                rect: NormalizedRect(
                    x: item.rect.x,
                    y: 0.70,
                    width: item.rect.width,
                    height: item.rect.height
                ),
                confidence: item.confidence
            )
        }
        assertUnknownWithoutActions(separatedRightStack)

        let separatedBottomRow = observations.map { item in
            guard item.text == "全部自動" else { return item }
            return OCRTextObservation(
                text: item.text,
                rect: NormalizedRect(
                    x: item.rect.x,
                    y: 0.82,
                    width: item.rect.width,
                    height: item.rect.height
                ),
                confidence: item.confidence
            )
        }
        assertUnknownWithoutActions(separatedBottomRow)

        let misalignedRightColumn = observations.map { item in
            guard item.text == "撤退" else { return item }
            return OCRTextObservation(
                text: item.text,
                rect: NormalizedRect(
                    x: 0.70,
                    y: item.rect.y,
                    width: item.rect.width,
                    height: item.rect.height
                ),
                confidence: item.confidence
            )
        }
        assertUnknownWithoutActions(misalignedRightColumn)

        let crowdedBottomControls = observations.map { item in
            guard item.text == "跳過" else { return item }
            return OCRTextObservation(
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
        assertUnknownWithoutActions(crowdedBottomControls)

        let conflictingResult = observations + [OCRTextObservation(
            text: "任務完成！",
            rect: NormalizedRect(x: 0.31, y: 0.06, width: 0.38, height: 0.04),
            confidence: 1
        )]
        assertUnknownWithoutActions(conflictingResult)
    }

    private func liveObservations() throws -> [OCRTextObservation] {
        let url = try #require(Bundle.module.url(
            forResource: "active-battle-control-grid-analysis",
            withExtension: "json"
        ))
        let fixture = try JSONDecoder().decode(
            ActiveBattleAnalysisFixture.self,
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

    private func assertUnknownWithoutActions(_ observations: [OCRTextObservation]) {
        let result = GameStateClassifier.classify(observations: observations)
        #expect(result.state == .unknown)
        #expect(result.allowedActions.isEmpty)
        #expect(result.policyGatedActions.isEmpty)
    }
}

private struct ActiveBattleAnalysisFixture: Decodable {
    let ocr: OCR

    struct OCR: Decodable {
        let observations: [OCRTextObservation]
    }
}
