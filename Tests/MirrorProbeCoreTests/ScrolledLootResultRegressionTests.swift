import Foundation
import Testing
@testable import MirrorProbeCore

/// Two runs on 2026-09-20 (22:45 after 55 cycles, 23:23 after 31) and the 00:13 start on
/// 2026-09-21 all stopped on the same loot page at 211x468: its list sat about seven canvas
/// rows higher than the calibrated page, the repeat row scored -0.05 at the fixed region and
/// the page stayed unknown until the acknowledgement timeout. The fixtures are the runner's
/// normalized 204x445 canvases (final.png) from the first and last of those runs.
@Suite("Scrolled loot list regression")
struct ScrolledLootResultRegressionTests {
    private static let captures: [(name: String, sha256: String)] = [
        ("scrolled-loot-result-20260920-224537",
         "8ec11a857ac097daabf040faecceac00f454091194963257b626a975d3c65e89"),
        ("scrolled-loot-result-20260921-001348",
         "ddc2ddd1719769e6ac68738c7c4a1798fd549d85a49f3acea05760968bef9ef6"),
    ]

    @Test("The scrolled loot page is recognized with every result target moved by the list offset",
          arguments: captures)
    func scrolledLootPageFollowsItsListOffset(capture: (name: String, sha256: String)) throws {
        let classification = try classify(capture)
        #expect(classification.state == .missionCompleteRepeatSelected)
        #expect(MissionSuccessPageIdentity.resolve(in: classification) == .loot)
        #expect(VisualResultEvidence.hasConsistentVisualEvidence(in: classification))
        let matches = classification.evidence.compactMap(\.visualMatch)
        let row = try #require(matches.first { $0.marker == .repeatOption })
        #expect(row.similarity >= VisualResultListOffset.minimumSimilarity)
        // About six canvas rows (6/445) above the calibrated position.
        #expect((-0.020 ... -0.011).contains(row.listOffset))
        #expect(row.region == VisualResultMatch.region(for: .repeatOption, listOffset: row.listOffset))
        #expect(VisualResultEvidence.listOffset(in: classification) == row.listOffset)
        #expect(matches.filter { $0.marker != .repeatOption }.allSatisfy { $0.listOffset == 0 })
        #expect(classification.evidence.contains { $0.kind == .repeatSelectedMarker })

        #expect(classification.allowedActions.count == 1)
        let action = try #require(classification.allowedActions.first)
        #expect(action.name == .advanceMissionComplete)
        let target = AutoLevelActionTarget(action.target)
        let expectedRect = MissionResultTopActionResolver.measuredTopAdvanceRect(listOffset: row.listOffset)
        #expect(target.rect == expectedRect && target.point == expectedRect.center)
        #expect(target.rect != MissionResultTopActionResolver.measuredTopAdvanceRect)
        #expect(MissionResultTopActionResolver.isMeasuredTopAdvanceTarget(target, in: classification))
    }

    @Test("The controller advances from the scrolled page and retries its arrow at the same offset")
    func controllerAdvancesAndRetriesOnScrolledPage() throws {
        let classification = try classify(Self.captures[1])
        let identity = AutoLevelWindowIdentity(processID: 98263, windowID: 13881)
        func snapshot(at time: TimeInterval, fingerprint: String) -> AutoLevelSnapshot {
            .init(classification: classification, runtime: .init(
                observedAt: time, windowIdentity: identity, frameFingerprint: fingerprint
            ))
        }
        var controller = AutoLevelController(
            session: .init(sessionID: "scrolled-loot", startedAt: 0, windowIdentity: identity),
            policy: .init(actionCooldown: 0, postActionTimeout: 3)
        )
        #expect(controller.consume(snapshot(at: 1, fingerprint: "loot"))
            == .completedCycle(.init(count: 1, outcome: .success)))
        let request = try action(controller.consume(snapshot(at: 1.5, fingerprint: "loot")))
        #expect(request.intent == .advanceMissionSuccess)
        let offset = VisualResultEvidence.listOffset(in: classification)
        #expect(offset < 0)
        #expect(request.target.rect == MissionResultTopActionResolver.measuredTopAdvanceRect(listOffset: offset))
        let posted = controller.markActionPosted(request, at: 2)
        #expect(posted)
        // The same scrolled page after the timeout re-posts the same offset arrow.
        let retry = try action(controller.consume(snapshot(at: 6, fingerprint: "loot-still")))
        #expect(retry.requestID == request.requestID + 1)
        #expect(retry.target == request.target)
        #expect(controller.completedCycles == 1)
        #expect(controller.actionsIssued == 2)
    }

    @Test("The resolver moves the fixed top control by the repeat row's list offset")
    func resolverFollowsListOffset() throws {
        let offset = -0.02
        let classification = GameStateClassification(state: .missionCompleteRepeatSelected, evidence: [
            marker(.successTitle, kind: .missionCompleteTitle),
            marker(.lootHeader, kind: .missionLootPage),
            marker(.repeatOption, kind: .missionRepeatOption, offset: offset),
            .init(kind: .repeatSelectedMarker, observation: nil,
                  detail: RepeatSelectedStampDetector.evidenceSentinel),
        ], allowedActions: [])
        let resolved = MissionResultTopActionResolver.resolve(classification: classification)
        let target = try #require(resolved.allowedActions.first?.target)
        let rect = MissionResultTopActionResolver.measuredTopAdvanceRect(listOffset: offset)
        #expect(target.rect == rect && target.point == rect.center)
        #expect(MissionResultTopActionResolver.measuredTopAdvanceRect(listOffset: 0)
            == MissionResultTopActionResolver.measuredTopAdvanceRect)
    }

    @Test("A repeat retry proof accepts the row at its list offset")
    func repeatProofFollowsListOffset() {
        let offset = -0.02
        let rowRect = VisualResultMatch.region(for: .repeatOption, listOffset: offset)
        let classification = GameStateClassification(state: .missionComplete, evidence: [
            marker(.successTitle, kind: .missionCompleteTitle),
            marker(.lootHeader, kind: .missionLootPage),
            marker(.repeatOption, kind: .missionRepeatOption, offset: offset),
            .init(kind: .repeatUnselectedMarker, observation: nil,
                  detail: RepeatSelectedStampDetector.absentEvidenceSentinel),
        ], allowedActions: [
            .init(name: .selectMissionRepeat, target: .init(
                name: .missionRepeatOption,
                sourceText: VisualResultEvidence.measuredRepeatOptionSentinel,
                rect: rowRect, point: rowRect.center
            )),
        ])
        let target = AutoLevelActionTarget(classification.allowedActions[0].target)
        #expect(MissionRepeatSelectionProof.page(in: classification, matching: target) == .loot)
        #expect(VisualResultEvidence.trustedRepeatRect(in: classification) == rowRect)
    }

    private func classify(_ capture: (name: String, sha256: String)) throws -> GameStateClassification {
        let frame = try loadRGBAFixture(capture.name, sha256: capture.sha256)
        #expect(frame.width == 204 && frame.height == 445)
        return try AutoLevelVisualClassifier.classifyRGBA(
            frame.bytes, width: frame.width, height: frame.height, bytesPerRow: frame.bytesPerRow
        )
    }

    private func marker(
        _ marker: VisualResultMarker, kind: GameEvidenceKind, offset: Double = 0
    ) -> GameStateEvidence {
        .init(kind: kind, observation: nil, detail: "test", visualMatch: .init(
            marker: marker, region: VisualResultMatch.region(for: marker, listOffset: offset),
            similarity: 0.99, listOffset: offset
        ))
    }

    private func action(_ decision: AutoLevelDecision) throws -> AutoLevelActionRequest {
        guard case let .requestAction(request) = decision else {
            Issue.record("Expected a result action, received \(decision)")
            throw ScrolledFixtureError.expectedAction
        }
        return request
    }

    private enum ScrolledFixtureError: Error { case expectedAction }
}
