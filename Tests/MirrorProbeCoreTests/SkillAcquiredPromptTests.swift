import Foundation
import Testing
@testable import MirrorProbeCore

@Suite("Geometry-first modal regression")
struct SkillAcquiredPromptTests {
    @Test("The missed new-skill popup is actionable from its one-button geometry")
    func liveOCRReplay() throws {
        let url = try #require(Bundle.module.url(
            forResource: "skill-acquired-live-analysis",
            withExtension: "json"
        ))
        let fixture = try JSONDecoder().decode(
            LiveAnalysisFixture.self,
            from: Data(contentsOf: url)
        )
        let ocrClassification = GameStateClassifier.classify(
            observations: fixture.ocr.observations
        )
        let button = NormalizedRect(
            x: 0.108,
            y: 0.5325842696629214,
            width: 0.783,
            height: 0.0398876404494382
        )
        let result = WideModalActionResolver.resolve(
            classification: ocrClassification,
            detection: WideModalButtonDetection(
                buttons: [WideModalButton(rect: button)],
                layout: .oneButton,
                dialogRect: nil
            )
        )

        #expect(result.state == .wideModalOneButton)
        #expect(result.allowedActions.map(\.name) == [.pressWideModalTopButton])
        #expect(result.allowedActions.first?.target.name == .wideModalTopButton)
        #expect(result.allowedActions.first?.target.rect == button)
    }

    @Test("Modal authorization does not require any recognized text")
    func emptyOCRStillAllowsMeasuredButton() {
        let button = NormalizedRect(x: 0.108, y: 0.53, width: 0.783, height: 0.04)
        for observations in [
            [OCRTextObservation](),
            [OCRTextObservation(
                text: "完全不同的新通知",
                rect: NormalizedRect(x: 0.1, y: 0.47, width: 0.4, height: 0.02),
                confidence: 0.1
            )],
        ] {
            let base = GameStateClassifier.classify(observations: observations)
            let result = WideModalActionResolver.resolve(
                classification: base,
                detection: WideModalButtonDetection(
                    buttons: [WideModalButton(rect: button)],
                    layout: .oneButton,
                    dialogRect: nil
                )
            )
            #expect(result.state == .wideModalOneButton)
            #expect(result.allowedActions.map(\.name) == [.pressWideModalTopButton])
        }
    }
}

private struct LiveAnalysisFixture: Decodable {
    let ocr: OCR

    struct OCR: Decodable {
        let observations: [OCRTextObservation]
    }
}
