import Foundation
import Testing
@testable import MirrorProbeCore

@Suite("Active battle low-auto OCR regression")
struct ActiveBattleLowAutoRegressionTests {
    private let anchors = ["戰利品", "暫停", "撤退", "跳過", "全部自動"]

    @Test("The captured sequence remains battle without authorizing low-confidence auto clicks")
    func replayCapturedSequence() throws {
        let frames = try capturedFrames()
        #expect(frames.count == 8)
        #expect(frames.first?.originalClassification.state == .battle)
        #expect(frames.dropFirst().allSatisfy { $0.originalClassification.state == .unknown })
        let identity = AutoLevelWindowIdentity(processID: 91507, windowID: 65194)
        var controller = AutoLevelController(session: .init(
            sessionID: "low-auto-replay", startedAt: 0, windowIdentity: identity
        ))

        for (index, frame) in frames.enumerated() {
            let classification = GameStateClassifier.classify(observations: frame.observations)
            #expect(classification.state == .battle)
            let auto = try #require(frame.observations.first { $0.text == "全部自動" })
            if index > 0 {
                #expect(auto.confidence == 0.5)
                #expect(classification.allowedActions.isEmpty)
                #expect(Set(classification.evidence.compactMap { $0.observation?.text }) == Set(anchors))
            } else {
                #expect(classification.allowedActions.map(\.name) == [.enableAutoBattle])
            }
            #expect(classification.policyGatedActions.map(\.name) == [.openBattleRetreatConfirmation])
            // Cover a sequence longer than the uncertainty grace period. An active automatic
            // battle must keep waiting even though its auto button is no longer a click target.
            let decision = controller.consume(AutoLevelSnapshot(
                classification: classification,
                runtime: .init(
                    observedAt: Double(index) * 5 + 1,
                    windowIdentity: identity,
                    frameFingerprint: "capture-\(index)",
                    battleSessionID: "battle-14",
                    allAutoStatus: .active,
                    battleStatus: .inProgress
                )
            ))
            #expect(decision == .wait(.battleInProgress))
        }
        #expect(controller.actionsIssued == 0)
        #expect(controller.completedCycles == 0)
    }

    @Test("All five low-auto anchors must be present, unique, and in their measured regions")
    func anchorsFailClosed() throws {
        let observations = try finalObservations()
        for name in anchors {
            assertUnknown(observations.filter { $0.text != name })
            let original = try #require(observations.first { $0.text == name })
            assertUnknown(observations + [original])
            assertUnknown(replacing(name, in: observations) { item in
                .init(text: item.text, rect: .init(x: 0.45, y: 0.35, width: 0.10, height: 0.02),
                      confidence: item.confidence)
            })
        }
    }

    @Test("Low-auto classification retains independent confidence floors")
    func confidenceFloorsFailClosed() throws {
        let observations = try finalObservations()
        for (name, confidence) in [
            "戰利品": 0.599, "暫停": 0.499, "撤退": 0.499,
            "跳過": 0.599, "全部自動": 0.499,
        ] {
            assertUnknown(replacing(name, in: observations) { item in
                .init(text: item.text, rect: item.rect, confidence: confidence)
            })
        }
        // Strong corroboration identifies the screen, but never lowers the auto click floor.
        for confidence in [0.5, 0.599, 0.6] {
            let result = GameStateClassifier.classify(observations: replacing("全部自動", in: observations) {
                .init(text: $0.text, rect: $0.rect, confidence: confidence)
            })
            #expect(result.state == .battle)
            #expect(result.allowedActions.map(\.name) == (confidence >= 0.6 ? [.enableAutoBattle] : []))
        }
    }

    @Test("Low-auto fallback requires ordered and aligned control rows")
    func gridGeometryFailsClosed() throws {
        let observations = try finalObservations()
        let pause = try #require(observations.first { $0.text == "暫停" })
        let retreat = try #require(observations.first { $0.text == "撤退" })
        let skip = try #require(observations.first { $0.text == "跳過" })
        let auto = try #require(observations.first { $0.text == "全部自動" })
        for (left, right) in [(pause, retreat), (skip, auto)] {
            assertUnknown(observations.map { item in
                let rect = item.text == left.text ? right.rect : item.text == right.text ? left.rect : item.rect
                return .init(text: item.text, rect: rect, confidence: item.confidence)
            })
        }
        for (name, x, y) in [("撤退", 0.75, retreat.rect.y), ("撤退", retreat.rect.x, 0.72),
                             ("全部自動", auto.rect.x, 0.83), ("跳過", 0.164, skip.rect.y)] {
            assertUnknown(replacing(name, in: observations) { item in
                .init(text: item.text,
                      rect: .init(x: x, y: y, width: item.rect.width, height: item.rect.height),
                      confidence: item.confidence)
            })
        }
    }

    @Test("A conflicting result still blocks the corroborated battle")
    func conflictingResultFailsClosed() throws {
        assertUnknown(try finalObservations() + [
            .init(text: "任務完成！", rect: .init(x: 0.31, y: 0.06, width: 0.38, height: 0.04), confidence: 1),
        ])
    }

    private func capturedFrames() throws -> [CapturedFrame] {
        let url = try #require(Bundle.module.url(forResource: "active-battle-low-auto-sequence", withExtension: "json"))
        return try JSONDecoder().decode([CapturedFrame].self, from: Data(contentsOf: url))
    }

    private func finalObservations() throws -> [OCRTextObservation] {
        try #require(capturedFrames().last).observations
    }

    private func replacing(
        _ name: String, in observations: [OCRTextObservation],
        with replacement: (OCRTextObservation) -> OCRTextObservation
    ) -> [OCRTextObservation] {
        observations.map { $0.text == name ? replacement($0) : $0 }
    }

    private func assertUnknown(_ observations: [OCRTextObservation]) {
        let result = GameStateClassifier.classify(observations: observations)
        #expect(result.state == .unknown)
        #expect(result.allowedActions.isEmpty)
        #expect(result.policyGatedActions.isEmpty)
    }

    private struct CapturedFrame: Decodable {
        let originalClassification: GameStateClassification
        let observations: [OCRTextObservation]
    }
}
