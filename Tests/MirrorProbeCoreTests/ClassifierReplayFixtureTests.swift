import Foundation
import Testing
@testable import MirrorProbeCore

@Suite("GameStateClassifier live fixture replay")
struct ClassifierReplayFixtureTests {
    @Test("Corpus keeps its opt-in and known-mismatch cases explicit")
    func corpusContract() {
        #expect(classifierReplayFixtures.count == 8)
        #expect(Set(classifierReplayFixtures.map(\.label)).count == 8)
        #expect(
            classifierReplayFixtures.filter(\.permitFallback).map(\.label)
                == ["success-loot-zero-arrow-ocr-measured-fallback"]
        )
        #expect(
            classifierReplayFixtures.filter(\.knownTargetMismatch).map(\.label)
                == []
        )
    }

    @Test(
        "Replays captured OCR together with its screen-layout contract",
        arguments: classifierReplayFixtures
    )
    func replaysCapturedFixture(_ fixture: ClassifierReplayFixture) {
        let result = GameStateClassifier.classify(
            observations: fixture.observations,
            permitMeasuredLootTopAdvanceFallback: fixture.permitFallback
        )

        #expect(result.state == fixture.expectedState, Comment(rawValue: fixture.label))
        #expect(
            result.allowedActions.map(\.name) == fixture.expectedAllowedActions,
            Comment(rawValue: fixture.label)
        )
        #expect(
            result.policyGatedActions.map(\.name) == fixture.expectedPolicyActions,
            Comment(rawValue: fixture.label)
        )

        #expect(fixture.expectedButtonCount == fixture.buttons.count)
        #expect(fixture.sourceCapture.hasSuffix(".json"))
        #expect(fixture.sourceImage.hasSuffix(".png"))
        #expect(!fixture.expectedTransition.isEmpty)
        #expect(!fixture.notes.isEmpty)

        for button in fixture.buttons {
            #expect(button.normalizedRect.isValid, Comment(rawValue: fixture.label))
            #expect(button.targetAnchorRect.isValid, Comment(rawValue: fixture.label))
            #expect(
                button.normalizedRect.contains(button.targetAnchorRect.center),
                Comment(rawValue: "\(fixture.label): \(button.role) anchor escaped its button")
            )
        }
        for rect in fixture.forbiddenTargetRects {
            #expect(rect.isValid, Comment(rawValue: fixture.label))
        }

        if let expectedTargetIndex = fixture.expectedTargetIndex {
            #expect(fixture.buttons.indices.contains(expectedTargetIndex))
            let intended = fixture.buttons[expectedTargetIndex]
            #expect(intended.targetAnchorRect == fixture.expectedTargetRect)
            switch fixture.selectionRule {
            case .top:
                #expect(expectedTargetIndex == 0)
            case .bottom:
                #expect(expectedTargetIndex == fixture.buttons.count - 1)
            case .none:
                Issue.record("\(fixture.label): a target needs a top/bottom selection rule")
            }
            #expect(
                !fixture.forbiddenTargetRects.contains {
                    $0.contains(fixture.expectedTargetRect?.center)
                },
                Comment(rawValue: "\(fixture.label): intended target is forbidden")
            )
        } else {
            #expect(fixture.expectedTargetRect == nil)
        }

        let classifierTarget = target(for: fixture.expectedAction, in: result)
        if let classifierTargetIndex = fixture.currentClassifierTargetIndex {
            #expect(fixture.buttons.indices.contains(classifierTargetIndex))
            let current = fixture.buttons[classifierTargetIndex]
            #expect(classifierTarget?.rect == current.targetAnchorRect)
            #expect(
                current.normalizedRect.contains(classifierTarget?.point),
                Comment(rawValue: "\(fixture.label): classifier target escaped its button")
            )
        } else {
            #expect(classifierTarget == nil)
        }

        let hasKnownMismatch = fixture.currentClassifierTargetIndex.map {
            $0 != fixture.expectedTargetIndex
        } ?? false
        #expect(fixture.knownTargetMismatch == hasKnownMismatch)
        if fixture.knownTargetMismatch, let point = classifierTarget?.point {
            #expect(
                fixture.forbiddenTargetRects.contains { $0.contains(point) },
                Comment(rawValue: "\(fixture.label): documented mismatch is no longer forbidden")
            )
        } else if let point = classifierTarget?.point {
            #expect(
                !fixture.forbiddenTargetRects.contains { $0.contains(point) },
                Comment(rawValue: "\(fixture.label): classifier selected a forbidden control")
            )
        }
    }

    private func target(
        for expectation: ReplayActionExpectation?,
        in result: GameStateClassification
    ) -> NamedGameTarget? {
        guard let expectation else {
            return nil
        }

        switch expectation.channel {
        case .allowed:
            let matches = result.allowedActions.filter { $0.name == expectation.name }
            #expect(matches.count == 1)
            return matches.first?.target
        case .policyGated:
            let matches = result.policyGatedActions.filter { $0.name == expectation.name }
            #expect(matches.count == 1)
            return matches.first?.target
        }
    }
}

struct ClassifierReplayFixture: Decodable, Sendable, CustomTestStringConvertible {
    let label: String
    let sourceCapture: String
    let sourceImage: String
    let screenLayoutType: ReplayScreenLayoutType
    let observations: [OCRTextObservation]
    let permitFallback: Bool
    let expectedState: GameState
    let expectedAction: ReplayActionExpectation?
    let expectedAllowedActions: [GameActionName]
    let expectedPolicyActions: [GameActionName]
    let expectedButtonCount: Int
    let buttons: [ReplayButton]
    let expectedTargetIndex: Int?
    let currentClassifierTargetIndex: Int?
    let expectedTargetRect: NormalizedRect?
    let forbiddenTargetRects: [NormalizedRect]
    let selectionRule: ReplaySelectionRule
    let knownTargetMismatch: Bool
    let expectedTransition: String
    let notes: String

    var testDescription: String { label }
}

struct ReplayActionExpectation: Decodable, Sendable {
    let name: GameActionName
    let channel: ReplayActionChannel
}

enum ReplayActionChannel: String, Decodable, Sendable {
    case allowed
    case policyGated
}

enum ReplaySelectionRule: String, Decodable, Sendable {
    case top
    case bottom
    case none
}

enum ReplayScreenLayoutType: String, Decodable, Sendable {
    case missionResultExperience
    case missionResultLoot
    case lootCollectionConfirmation
    case retreatConfirmation
    case adventurerRecruitment
    case battleFrozenAfterDefeat
    case defeatPrompt
}

struct ReplayButton: Decodable, Sendable {
    let role: String
    /// Approximate full visible control bounds, measured in the captured 406 x 890 screen.
    let normalizedRect: NormalizedRect
    /// Exact OCR/fallback anchor used by the current classifier as a click target.
    let targetAnchorRect: NormalizedRect
}

let classifierReplayFixtures: [ClassifierReplayFixture] = {
    let url = Bundle.module.url(
        forResource: "classifier-replays",
        withExtension: "json"
    )!
    let data = try! Data(contentsOf: url)
    return try! JSONDecoder().decode([ClassifierReplayFixture].self, from: data)
}()

private extension NormalizedRect {
    func contains(_ point: NormalizedPoint?) -> Bool {
        guard let point else { return false }
        return point.x >= x
            && point.x <= x + width
            && point.y >= y
            && point.y <= y + height
    }
}
