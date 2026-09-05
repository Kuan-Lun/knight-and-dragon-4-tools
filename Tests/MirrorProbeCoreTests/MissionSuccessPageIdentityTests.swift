import Foundation
import Testing
@testable import MirrorProbeCore

@Suite("Mission success page identity")
struct MissionSuccessPageIdentityTests {
    @Test("One trusted page label identifies EXP or loot including OCR whitespace")
    func recognizesUniqueTrustedPage() {
        #expect(resolve([marker(.missionExperiencePage, "獲得經驗值")]) == .experience)
        #expect(resolve([marker(.missionLootPage, "獲得拾得物")]) == .loot)
        #expect(resolve([marker(.missionExperiencePage, "獲得 經驗值\n", confidence: 0.6)]) == .experience)
    }

    @Test("Missing, unobserved, duplicate, and conflicting page labels have no identity")
    func requiresOneObservedPage() {
        let experience = marker(.missionExperiencePage, "獲得經驗值")
        let loot = marker(.missionLootPage, "獲得拾得物")
        #expect(resolve([]) == nil)
        #expect(resolve([GameStateEvidence(
            kind: .missionExperiencePage, observation: nil, detail: "missing observation"
        )]) == nil)
        #expect(resolve([experience, experience]) == nil)
        #expect(resolve([experience, loot]) == nil)
        #expect(resolve([experience, marker(.missionLootPage, "獲得拾得物", confidence: 0.1)]) == nil)
    }

    @Test("Page confidence must be finite and within the trusted probability range")
    func rejectsUntrustedConfidence() {
        for confidence in [0.599, -1, 1.001, Double.nan, .infinity, -.infinity] {
            #expect(resolve([marker(.missionExperiencePage, "獲得經驗值", confidence: confidence)]) == nil)
        }
    }

    @Test("Page labels remain bound to the measured upper-right header")
    func rejectsMisplacedAndInvalidRectangles() {
        for rect in [
            NormalizedRect(x: 0.40, y: 0.146, width: 0.19, height: 0.02),
            NormalizedRect(x: 0.78, y: 0.30, width: 0.19, height: 0.02),
            NormalizedRect(x: 0.78, y: 0.09, width: 0.19, height: 0.02),
            NormalizedRect(x: 0.95, y: 0.146, width: 0.19, height: 0.02),
            NormalizedRect(x: .nan, y: 0.146, width: 0.19, height: 0.02),
        ] {
            #expect(resolve([marker(.missionExperiencePage, "獲得經驗值", rect: rect)]) == nil)
        }
    }

    @Test("Evidence kind and complete label text must agree")
    func rejectsTruncatedOrMismatchedText() {
        #expect(resolve([marker(.missionExperiencePage, "獲得拾得物")]) == nil)
        #expect(resolve([marker(.missionLootPage, "獲得經驗值")]) == nil)
        #expect(resolve([marker(.missionExperiencePage, "經驗值")]) == nil)
        #expect(resolve([marker(.missionLootPage, "獲得拾得物?")]) == nil)
        #expect(resolve([marker(.missionCompleteTitle, "獲得經驗值")]) == nil)
    }

    private func resolve(_ evidence: [GameStateEvidence]) -> MissionSuccessPageIdentity? {
        MissionSuccessPageIdentity.resolve(in: GameStateClassification(
            state: .missionCompleteRepeatSelected,
            evidence: evidence,
            allowedActions: [],
            policyGatedActions: []
        ))
    }

    private func marker(
        _ kind: GameEvidenceKind,
        _ text: String,
        confidence: Double = 1,
        rect: NormalizedRect = NormalizedRect(x: 0.78, y: 0.146, width: 0.19, height: 0.02)
    ) -> GameStateEvidence {
        GameStateEvidence(
            kind: kind,
            observation: OCRTextObservation(text: text, rect: rect, confidence: confidence),
            detail: "page identity test"
        )
    }
}
