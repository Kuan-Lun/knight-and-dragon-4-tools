import Foundation
import Testing
@testable import MirrorProbeCore

@Suite("Visual result evidence at controller boundaries")
struct VisualResultEvidenceTests {
    @Test("Visual EXP and loot results advance with no OCR observations",
          arguments: [MissionSuccessPageIdentity.experience, .loot], [false, true])
    func selectedVisualResultsReachTheController(page: MissionSuccessPageIdentity, failure: Bool) throws {
        let classification = result(page: page, failure: failure)
        #expect(classification.evidence.allSatisfy { $0.observation == nil })
        #expect(VisualResultEvidence.hasConsistentVisualEvidence(in: classification))
        #expect(MissionSuccessPageIdentity.resolve(in: classification) == page)
        #expect(classification.allowedActions.map(\.name) == [.advanceMissionComplete])
        var controller = makeController()
        let origin = snapshot(classification, at: 1)
        #expect(controller.consume(origin) == .completedCycle(.init(
            count: 1, outcome: failure ? .failure : .success
        )))
        let request = try action(controller.consume(origin))
        #expect(request.intent == (failure ? .advanceMissionFailure : .advanceMissionSuccess))
        #expect(request.target.rect == MissionResultTopActionResolver.measuredTopAdvanceRect)
        #expect(request.target.sourceText == MissionResultTopActionResolver.measuredTopAdvanceSentinel)
    }

    @Test("Visual EXP-to-loot identity acknowledges the posted advance without recounting")
    func visualPageTransitionAcknowledgesAdvance() throws {
        var controller = makeController()
        let exp = snapshot(result(page: .experience), at: 1)
        _ = controller.consume(exp)
        let first = try action(controller.consume(exp))
        let posted = controller.markActionPosted(first, at: 2)
        #expect(posted)
        let second = try action(controller.consume(snapshot(result(page: .loot), at: 3)))
        #expect(second.intent == .advanceMissionSuccess)
        #expect(second.requestID == first.requestID + 1)
        #expect(controller.completedCycles == 1)
    }

    @Test("An empty stamp supports the same bounded visual repeat retry for both result families",
          arguments: [MissionSuccessPageIdentity.experience, .loot], [false, true])
    func visualRepeatRetryPreservesItsTargetAndPage(page: MissionSuccessPageIdentity, failure: Bool) throws {
        let classification = result(page: page, failure: failure, selected: false)
        let target = AutoLevelActionTarget(try #require(classification.allowedActions.first).target)
        #expect(target.sourceText == VisualResultEvidence.measuredRepeatOptionSentinel)
        #expect(target.rect == VisualResultMatch.region(for: .repeatOption))
        #expect(MissionRepeatSelectionProof.page(in: classification, matching: target) == page)
        var controller = makeController()
        let origin = snapshot(classification, at: 1)
        _ = controller.consume(origin)
        let first = try action(controller.consume(origin))
        let posted = controller.markActionPosted(first, at: 2)
        #expect(posted)
        let retry = try action(controller.consume(snapshot(classification, at: 5)))
        #expect(retry.intent == .selectMissionRepeat)
        #expect(retry.target == first.target)
        #expect(retry.repeatSelectionRetryPage == page)
        #expect(controller.completedCycles == 1)
    }

    @Test("The visual similarity floor is finite and bounded independently of OCR confidence")
    func rejectsInvalidSimilarity() {
        let valid = marker(.experienceHeader, similarity: VisualResultMatch.minimumSimilarity)
        #expect(VisualResultEvidence.validatedMatch(valid) != nil)
        for similarity in [VisualResultMatch.minimumSimilarity - 0.000_001, -1, 1.001,
                           Double.nan, .infinity, -.infinity] {
            let invalid = marker(.experienceHeader, similarity: similarity)
            #expect(VisualResultEvidence.validatedMatch(invalid) == nil)
            let classification = replacing(.missionExperiencePage, in: result(), with: invalid)
            #expect(MissionSuccessPageIdentity.resolve(in: classification) == nil)
            #expect(VisualResultEvidence.trustedRepeatRect(in: classification) == nil)
        }
    }

    @Test("Marker kind, fixed region, and provenance must agree")
    func rejectsWrongMarkerRegionAndMixedObservation() {
        let valid = marker(.experienceHeader)
        let match = valid.visualMatch!
        let bad = [
            GameStateEvidence(kind: .missionExperiencePage, observation: nil, detail: "wrong marker",
                              visualMatch: .init(marker: .lootHeader, region: match.region, similarity: 1)),
            GameStateEvidence(kind: .missionExperiencePage, observation: nil, detail: "moved region",
                              visualMatch: .init(marker: .experienceHeader,
                                                region: .init(x: 0.774, y: 0.145, width: 0.20, height: 0.026),
                                                similarity: 1)),
            GameStateEvidence(kind: .missionExperiencePage, observation: nil, detail: "missing match"),
            GameStateEvidence(kind: .missionExperiencePage,
                              observation: .init(text: "獲得經驗值", rect: match.region, confidence: 1),
                              detail: "mixed provenance", visualMatch: match),
            GameStateEvidence(kind: .missionExperiencePage, observation: nil,
                              detail: "mixed battle and result provenance", visualMatch: match,
                              battleVisualMatch: .init(marker: .pauseControl,
                                  region: VisualBattleMatch.regions(for: .pauseControl)[0],
                                  similarity: 1)),
        ]
        for evidence in bad {
            #expect(VisualResultEvidence.validatedMatch(evidence) == nil)
            let classification = replacing(.missionExperiencePage, in: result(), with: evidence)
            #expect(!VisualResultEvidence.hasConsistentVisualEvidence(in: classification))
            #expect(MissionSuccessPageIdentity.resolve(in: classification) == nil)
        }
    }

    @Test("Duplicate or conflicting visual anchors cannot identify a result")
    func rejectsAmbiguousMarkersAndAdverseEvidence() {
        let baseline = result()
        let additions: [GameStateEvidence] = [
            marker(.successTitle), marker(.failureTitle), marker(.experienceHeader),
            marker(.lootHeader), marker(.repeatOption),
            .init(kind: .repeatUnselectedMarker, observation: nil,
                  detail: RepeatSelectedStampDetector.absentEvidenceSentinel),
            .init(kind: .invalidObservation, observation: nil, detail: "invalid"),
            .init(kind: .lowConfidenceMarker, observation: nil, detail: "weak"),
            .init(kind: .conflictingStateMarkers, observation: nil, detail: "conflict"),
            .init(kind: .battleMarker, observation: nil, detail: "battle"),
            .init(kind: .inventoryFullMarker, observation: nil, detail: "inventory"),
        ]
        for extra in additions {
            let classification = GameStateClassification(
                state: baseline.state, evidence: baseline.evidence + [extra],
                allowedActions: baseline.allowedActions
            )
            #expect(!VisualResultEvidence.hasConsistentVisualEvidence(in: classification))
            #expect(MissionSuccessPageIdentity.resolve(in: classification) == nil)
            #expect(VisualResultEvidence.trustedRepeatRect(in: classification) == nil)
        }
    }

    @Test("An OCR anchor cannot complete an otherwise visual result")
    func rejectsMixedVisualAndOCRAnchors() {
        let texts: [(GameEvidenceKind, VisualResultMarker, String)] = [
            (.missionCompleteTitle, .successTitle, "任務完成！"),
            (.missionExperiencePage, .experienceHeader, "獲得經驗值"),
            (.missionRepeatOption, .repeatOption, "重複進行此任務"),
        ]
        for (kind, visual, text) in texts {
            let ocr = GameStateEvidence(kind: kind, observation: .init(
                text: text, rect: VisualResultMatch.region(for: visual), confidence: 1
            ), detail: "legacy OCR")
            let classification = replacing(kind, in: result(), with: ocr)
            #expect(!VisualResultEvidence.hasConsistentVisualEvidence(in: classification))
            #expect(MissionSuccessPageIdentity.resolve(in: classification) == nil)
            #expect(VisualResultEvidence.trustedRepeatRect(in: classification) == nil)
        }
    }

    @Test("Every visual result requires its title, page, repeat row, and positive stamp evidence")
    func missingVisualAnchorCannotAuthorizeContinuation() {
        let baseline = result()
        for missing in [GameEvidenceKind.missionCompleteTitle, .missionExperiencePage,
                        .missionRepeatOption, .repeatSelectedMarker] {
            let classification = GameStateClassification(
                state: baseline.state,
                evidence: baseline.evidence.filter { $0.kind != missing },
                allowedActions: baseline.allowedActions
            )
            #expect(!VisualResultEvidence.hasConsistentVisualEvidence(in: classification))
            #expect(MissionSuccessPageIdentity.resolve(in: classification) == nil)
            #expect(VisualResultEvidence.trustedRepeatRect(in: classification) == nil)
            #expect(MissionResultTopActionResolver.resolve(classification: classification).allowedActions.isEmpty)
            var controller = makeController()
            let observation = snapshot(classification, at: 1)
            _ = controller.consume(observation)
            if case .requestAction = controller.consume(observation) {
                Issue.record("Missing \(missing) allowed a visual result action")
            }
            #expect(controller.actionsIssued == 0)
        }
    }

    @Test("Visual repeat retries require the measured source and unchanged empty-stamp proof")
    func visualRepeatRetryRejectsMalformedTargetsAndStamp() throws {
        let classification = result(selected: false)
        let target = AutoLevelActionTarget(try #require(classification.allowedActions.first).target)
        let wrongSource = AutoLevelActionTarget(name: target.name, sourceText: "重複進行此任務",
                                               rect: target.rect, point: target.point)
        #expect(MissionRepeatSelectionProof.page(in: classification, matching: wrongSource) == nil)
        let missingStamp = GameStateClassification(
            state: classification.state,
            evidence: classification.evidence.filter { $0.kind != .repeatUnselectedMarker },
            allowedActions: classification.allowedActions
        )
        #expect(MissionRepeatSelectionProof.page(in: missingStamp, matching: target) == nil)
        let wrongFamily = replacing(.missionCompleteTitle, in: classification, with: marker(.failureTitle))
        #expect(MissionRepeatSelectionProof.page(in: wrongFamily, matching: target) == nil)
    }

    @Test("Visual evidence round-trips without inventing OCR and old evidence still decodes")
    func serializationRetainsVisualProvenance() throws {
        let visual = marker(.successTitle)
        let encoded = try JSONEncoder().encode(visual)
        let decoded = try JSONDecoder().decode(GameStateEvidence.self, from: encoded)
        #expect(decoded == visual)
        #expect(decoded.observation == nil)
        #expect(decoded.visualMatch?.marker == .successTitle)
        let legacy = Data("{\"kind\":\"missionCompleteTitle\",\"detail\":\"legacy\"}".utf8)
        #expect(try JSONDecoder().decode(GameStateEvidence.self, from: legacy).visualMatch == nil)
    }

    private var identity: AutoLevelWindowIdentity { .init(processID: 31, windowID: 41) }

    private func makeController() -> AutoLevelController {
        .init(session: .init(sessionID: "visual-result", startedAt: 0, windowIdentity: identity),
              policy: .init(actionCooldown: 0, postActionTimeout: 3))
    }

    private func snapshot(_ classification: GameStateClassification, at time: Double) -> AutoLevelSnapshot {
        .init(classification: classification, runtime: .init(
            observedAt: time, windowIdentity: identity,
            frameFingerprint: "visual-\(MissionSuccessPageIdentity.resolve(in: classification)?.rawValue ?? "unknown")"
        ))
    }

    private func action(_ decision: AutoLevelDecision) throws -> AutoLevelActionRequest {
        guard case let .requestAction(request) = decision else {
            Issue.record("Expected a visual result action, received \(decision)")
            throw ExpectedAction.missing
        }
        return request
    }

    private func marker(_ marker: VisualResultMarker, similarity: Double = 1) -> GameStateEvidence {
        let kind: GameEvidenceKind
        switch marker {
        case .successTitle: kind = .missionCompleteTitle
        case .failureTitle: kind = .missionFailedTitle
        case .experienceHeader: kind = .missionExperiencePage
        case .lootHeader: kind = .missionLootPage
        case .repeatOption: kind = .missionRepeatOption
        }
        return .init(kind: kind, observation: nil, detail: "source=visualResultTemplate",
                     visualMatch: .init(marker: marker, region: VisualResultMatch.region(for: marker),
                                        similarity: similarity))
    }

    @Test("A repeat row matched on a scrolled list validates only within the bounded offset")
    func repeatRowListOffsetValidation() {
        let inRange = -7.0 / 445.0
        func evidence(_ match: VisualResultMatch, kind: GameEvidenceKind = .missionRepeatOption) -> GameStateEvidence {
            .init(kind: kind, observation: nil, detail: "scrolled", visualMatch: match)
        }
        let shifted = VisualResultMatch(
            marker: .repeatOption, region: VisualResultMatch.region(for: .repeatOption, listOffset: inRange),
            similarity: 0.98, listOffset: inRange
        )
        #expect(VisualResultEvidence.validatedMatch(evidence(shifted)) == shifted)
        // The region must be the calibrated one moved by exactly the recorded offset.
        let inconsistent = VisualResultMatch(
            marker: .repeatOption, region: VisualResultMatch.region(for: .repeatOption),
            similarity: 0.98, listOffset: inRange
        )
        #expect(VisualResultEvidence.validatedMatch(evidence(inconsistent)) == nil)
        for outOfRange in [-0.04, 0.01, .nan, .infinity] {
            let match = VisualResultMatch(
                marker: .repeatOption,
                region: VisualResultMatch.region(for: .repeatOption, listOffset: outOfRange),
                similarity: 0.98, listOffset: outOfRange
            )
            #expect(VisualResultEvidence.validatedMatch(evidence(match)) == nil)
        }
        // A scrolled row is held to the lower floor; the calibrated position keeps 0.94.
        let weakShifted = VisualResultMatch(
            marker: .repeatOption, region: VisualResultMatch.region(for: .repeatOption, listOffset: inRange),
            similarity: 0.80, listOffset: inRange
        )
        #expect(VisualResultEvidence.validatedMatch(evidence(weakShifted)) == weakShifted)
        let weakCanonical = VisualResultMatch(
            marker: .repeatOption, region: VisualResultMatch.region(for: .repeatOption), similarity: 0.80
        )
        #expect(VisualResultEvidence.validatedMatch(evidence(weakCanonical)) == nil)
        let tooWeak = VisualResultMatch(
            marker: .repeatOption, region: VisualResultMatch.region(for: .repeatOption, listOffset: inRange),
            similarity: 0.70, listOffset: inRange
        )
        #expect(VisualResultEvidence.validatedMatch(evidence(tooWeak)) == nil)
        // The title and page header never move.
        let title = VisualResultMatch(
            marker: .successTitle, region: VisualResultMatch.region(for: .successTitle),
            similarity: 0.98, listOffset: inRange
        )
        #expect(VisualResultEvidence.validatedMatch(evidence(title, kind: .missionCompleteTitle)) == nil)
        #expect(VisualResultListOffset.candidates.allSatisfy(VisualResultListOffset.isAllowed))
        #expect(VisualResultListOffset.candidates.contains { $0 < inRange } )
        #expect(!VisualResultListOffset.isAllowed(-0.04) && !VisualResultListOffset.isAllowed(0.01))
    }

    private func result(page: MissionSuccessPageIdentity = .experience,
                        failure: Bool = false, selected: Bool = true) -> GameStateClassification {
        let state: GameState = failure
            ? (selected ? .missionFailedRepeatSelected : .missionFailed)
            : (selected ? .missionCompleteRepeatSelected : .missionComplete)
        let repeatRect = VisualResultMatch.region(for: .repeatOption)
        let classification = GameStateClassification(state: state, evidence: [
            marker(failure ? .failureTitle : .successTitle),
            marker(page == .experience ? .experienceHeader : .lootHeader),
            marker(.repeatOption),
            .init(kind: selected ? .repeatSelectedMarker : .repeatUnselectedMarker, observation: nil,
                  detail: selected ? RepeatSelectedStampDetector.evidenceSentinel
                      : RepeatSelectedStampDetector.absentEvidenceSentinel),
        ], allowedActions: selected ? [] : [
            .init(name: .selectMissionRepeat, target: .init(
                name: .missionRepeatOption, sourceText: VisualResultEvidence.measuredRepeatOptionSentinel,
                rect: repeatRect, point: repeatRect.center
            )),
        ])
        return selected ? MissionResultTopActionResolver.resolve(classification: classification) : classification
    }

    private func replacing(_ kind: GameEvidenceKind, in classification: GameStateClassification,
                           with evidence: GameStateEvidence) -> GameStateClassification {
        .init(state: classification.state,
              evidence: classification.evidence.map { $0.kind == kind ? evidence : $0 },
              allowedActions: classification.allowedActions,
              policyGatedActions: classification.policyGatedActions)
    }

    private enum ExpectedAction: Error { case missing }
}
