import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import MirrorProbeCore

@Suite("Auto-level recognition uses only measured image evidence")
struct AutoLevelVisualClassifierTests {
    @Test("Native result captures retain visual state, page identity and their single authorized action",
          arguments: [
            "mission-repeat-selected-srlected", "mission-repeat-unselected",
            "mission-result-no-modal", "failure-repeat-confirmation-before",
            "visual-result-failure-selected", "visual-result-latest-experience",
            "visual-result-latest-loot-after", "visual-result-live-unselected-loot",
          ])
    func nativeResultRecognition(resource: String) throws {
        let capture = try load(resource)
        let classification = try classify(capture)
        let expected = try resultFixture(resource)
        #expect(classification.state == expected.expectedState)
        #expect(MissionSuccessPageIdentity.resolve(in: classification) == expected.expectedPage)
        #expect(VisualResultEvidence.hasConsistentVisualEvidence(in: classification))
        #expect(classification.evidence.allSatisfy { $0.observation == nil })
        #expect(classification.evidence.compactMap(\.visualMatch).count == 3)
        #expect(classification.policyGatedActions.isEmpty)
        #expect(classification.allowedActions.count == 1)
        #expect(snapshot(classification, at: 1, fingerprint: resource).actionCandidates.map(\.intent)
            == [try #require(expected.expectedIntent)])
    }

    @Test("Encounter, event, defeat, skill and returned-party dialogs take priority over their background",
          arguments: [
            "battle-intro-one-button", "battle-event-one-button", "defeat-one-button",
            "battle-prompt-one-button-alt", "mission-skill-acquired-one-button",
            "returned-party-manual-stop",
          ])
    func singleButtonModalPriority(resource: String) throws {
        try verifyModal(resource, expectedLayout: .oneButton, expectedState: .wideModalOneButton)
    }

    @Test("Loot, retreat and recruitment dialogs expose only the upper of two measured rows",
          arguments: [
            "loot-two-buttons", "retreat-two-buttons", "adventurer-two-buttons",
            "adventurer-two-buttons-colin",
          ])
    func twoButtonModalPriority(resource: String) throws {
        try verifyModal(resource, expectedLayout: .twoButtons, expectedState: .wideModalTwoButtons)
    }

    @Test("Native battle captures carry graphical battle evidence and only a gated retreat target",
          arguments: ["battle-no-modal", "active-battle-control-grid", "active-battle-low-retreat-grid"])
    func battleRecognitionCannotAuthorizeAnImmediateRetreat(resource: String) throws {
        let classification = try classify(load(resource))
        #expect(classification.state == .battle)
        #expect(classification.allowedActions.isEmpty)
        #expect(!classification.evidence.isEmpty)
        #expect(classification.evidence.allSatisfy { $0.observation == nil })
        #expect(VisualBattleEvidence.hasConsistentVisualEvidence(in: classification))
        #expect(classification.policyGatedActions.count == 1)
        let retreat = try #require(classification.policyGatedActions.first)
        #expect(retreat.name == .openBattleRetreatConfirmation)
        #expect(retreat.requirement == .temporalDefeatRecovery)
        #expect(retreat.target.rect.isValid)

        // Pixels identifying a battle do not supply a temporal stall authorization.
        var controller = AutoLevelController(
            session: .init(sessionID: "graphical-active-battle", startedAt: 0, windowIdentity: identity),
            policy: .init(postActionTimeout: 12)
        )
        let activeBattle = AutoLevelSnapshot(
            classification: classification,
            runtime: .init(observedAt: 1, windowIdentity: identity, frameFingerprint: resource,
                           battleSessionID: "same-battle", allAutoStatus: .active,
                           battleStatus: .inProgress)
        )
        #expect(controller.consume(activeBattle) == .wait(.battleInProgress))
        #expect(controller.actionsIssued == 0)
    }

    @Test("Temporal stall metadata permits only a complete graphical battle proof and its exact retreat target")
    func graphicalRetreatRequiresAllAnchorsAndExactTarget() throws {
        let classification = try classify(load("active-battle-control-grid"))
        #expect(VisualBattleEvidence.hasConsistentVisualEvidence(in: classification))
        let gated = try #require(classification.policyGatedActions.first)
        let measured = VisualBattleEvidence.measuredRetreatRect
        let shifted = NormalizedRect(x: measured.x - 0.02, y: measured.y,
                                     width: measured.width, height: measured.height)
        func altered(evidence: [GameStateEvidence], rect: NormalizedRect? = nil,
                     sourceText: String = VisualBattleEvidence.measuredRetreatSentinel)
            -> GameStateClassification {
            let targetRect = rect ?? measured
            return .init(state: .battle, evidence: evidence, allowedActions: [], policyGatedActions: [
                .init(name: gated.name,
                      target: .init(name: gated.target.name, sourceText: sourceText,
                                    rect: targetRect, point: targetRect.center),
                      requirement: gated.requirement),
            ])
        }
        let invalid: [GameStateClassification] = [
            altered(evidence: Array(classification.evidence.dropFirst())),
            altered(evidence: classification.evidence, rect: shifted),
            altered(evidence: classification.evidence, sourceText: "forged-visual-retreat"),
            altered(evidence: []),
        ]
        func stalledSnapshot(_ value: GameStateClassification) -> AutoLevelSnapshot {
            .init(classification: value,
                  runtime: .init(observedAt: 1, windowIdentity: identity, frameFingerprint: "stalled",
                                 battleSessionID: "same-battle", allAutoStatus: .active,
                                 battleStatus: .stalledAfterDefeat))
        }
        func controller() -> AutoLevelController {
            .init(session: .init(sessionID: "graphical-retreat", startedAt: 0, windowIdentity: identity),
                  policy: .init(postActionTimeout: 12))
        }
        var validController = controller()
        let validDecision = validController.consume(stalledSnapshot(classification))
        guard case let .requestAction(request) = validDecision else {
            Issue.record("Complete visual proof with temporal stall should request retreat: \(validDecision)")
            return
        }
        #expect(request.intent == .requestRetreat)
        #expect(request.target.rect == measured)
        #expect(request.target.sourceText == VisualBattleEvidence.measuredRetreatSentinel)

        for candidate in invalid {
            #expect(!VisualBattleEvidence.hasConsistentVisualEvidence(in: candidate))
            var invalidController = controller()
            #expect(invalidController.consume(stalledSnapshot(candidate))
                == .wait(.transientState(kind: .ambiguousAction, observationCount: 1)))
            #expect(invalidController.actionsIssued == 0)
        }
    }

    @Test("A real partially obscured result cannot fall through to battle or authorize any action")
    func partialResultRemainsUnknown() throws {
        let capture = try load("result-title-occlusion-confirmation")
        let partial = try VisualResultDetector.detectRGBA(
            capture.bytes, width: capture.width, height: capture.height,
            bytesPerRow: capture.bytesPerRow
        )
        #expect(partial.isResultCandidate)
        #expect(partial.classification.state == .unknown)
        let classification = try classify(capture)
        #expect(classification == partial.classification)
        #expect(classification.allowedActions.isEmpty)
        #expect(classification.policyGatedActions.isEmpty)
        #expect(classification.evidence.allSatisfy { $0.observation == nil })
        #expect(snapshot(classification, at: 1, fingerprint: "occluded").actionCandidates.isEmpty)
    }

    @Test("Blank black and white images cannot produce graphical actions", arguments: [UInt8(0), UInt8(255)])
    func blankFramesRemainUnknown(luminance: UInt8) throws {
        let width = 406
        let height = 890
        var bytes = [UInt8](repeating: luminance, count: width * height * 4)
        for index in stride(from: 3, to: bytes.count, by: 4) { bytes[index] = 255 }
        let classification = try AutoLevelVisualClassifier.classifyRGBA(
            bytes, width: width, height: height, bytesPerRow: width * 4
        )
        #expect(classification.state == .unknown)
        #expect(classification.allowedActions.isEmpty)
        #expect(classification.policyGatedActions.isEmpty)
        #expect(classification.evidence.allSatisfy { $0.observation == nil })
    }

    @Test("Invalid geometry and truncated input are rejected before any classifier can authorize an action")
    func malformedBuffersThrow() {
        for dimensions in [(0, 890, 0), (406, -1, 1_624), (406, 890, 1_623),
                           (Int.max, Int.max, Int.max), (406, 890, Int.max)] {
            #expect(throws: VisualResultDetectorError.invalidDimensions) {
                try AutoLevelVisualClassifier.classifyRGBA(
                    [], width: dimensions.0, height: dimensions.1, bytesPerRow: dimensions.2
                )
            }
        }
        #expect(throws: VisualResultDetectorError.insufficientBytes) {
            try AutoLevelVisualClassifier.classifyRGBA(
                [UInt8](repeating: 0, count: 1_624 * 890 - 1),
                width: 406, height: 890, bytesPerRow: 1_624
            )
        }
    }

    private func verifyModal(_ resource: String, expectedLayout: WideModalLayout,
                             expectedState: GameState) throws {
        let capture = try load(resource)
        let detection = try WideModalButtonDetector.detectRGBA(
            capture.bytes, width: capture.width, height: capture.height,
            bytesPerRow: capture.bytesPerRow
        )
        #expect(detection.layout == expectedLayout)
        let classification = try classify(capture)
        #expect(classification.state == expectedState)
        #expect(classification.evidence.allSatisfy { $0.observation == nil })
        #expect(classification.policyGatedActions.isEmpty)
        #expect(classification.allowedActions.map(\.name) == [.pressWideModalTopButton])
        let primary = try #require(detection.buttons.first)
        #expect(classification.allowedActions.first?.target.rect == primary.rect)
        #expect(classification.allowedActions.first?.target.point == primary.rect.center)
        #expect(snapshot(classification, at: 1, fingerprint: resource).actionCandidates.map(\.intent)
            == [.pressWideModalTopButton])
        if detection.buttons.count == 2 {
            #expect(primary.rect.center.y < detection.buttons[1].rect.center.y)
        }
    }

    private func snapshot(_ classification: GameStateClassification, at time: TimeInterval,
                          fingerprint: String) -> AutoLevelSnapshot {
        .init(classification: classification,
              runtime: .init(observedAt: time, windowIdentity: identity, frameFingerprint: fingerprint))
    }

    private func classify(_ capture: Capture) throws -> GameStateClassification {
        try AutoLevelVisualClassifier.classifyRGBA(
            capture.bytes, width: capture.width, height: capture.height,
            bytesPerRow: capture.bytesPerRow
        )
    }

    private func resultFixture(_ resource: String) throws -> ResultFixture {
        let url = try #require(Bundle.module.url(forResource: "visual-result-corpus", withExtension: "json"))
        let manifest = try JSONDecoder().decode(ResultManifest.self, from: Data(contentsOf: url))
        return try #require(manifest.fixtures.first { $0.resource == resource })
    }

    private func load(_ resource: String) throws -> Capture {
        let url = try #require(Bundle.module.url(forResource: resource, withExtension: "png"))
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let bytesPerRow = image.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * image.height)
        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let address = buffer.baseAddress,
                  let context = CGContext(
                    data: address, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                        | CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        #expect(rendered)
        return .init(bytes: bytes, width: image.width, height: image.height, bytesPerRow: bytesPerRow)
    }

    private let identity = AutoLevelWindowIdentity(processID: 91507, windowID: 65194)
    private struct Capture {
        let bytes: [UInt8]
        let width: Int
        let height: Int
        let bytesPerRow: Int
    }
    private struct ResultManifest: Decodable { let fixtures: [ResultFixture] }
    private struct ResultFixture: Decodable {
        let resource: String
        let expectedState: GameState
        let expectedPage: MissionSuccessPageIdentity?
        let expectedIntent: AutoLevelActionIntent?
    }
}
