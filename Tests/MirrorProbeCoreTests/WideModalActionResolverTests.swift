import Testing
@testable import MirrorProbeCore

@Suite("Wide modal action resolver")
struct WideModalActionResolverTests {
    @Test("One button is actionable without OCR text or a recognized state")
    func oneButtonIsGeometryOnly() {
        let button = rect(y: 0.53)
        for source in [
            classification(.unknown),
            classification(.battle),
            classification(.missionCompleteRepeatSelected),
            classification(.unknown, evidence: [conflictEvidence]),
        ] {
            let result = WideModalActionResolver.resolve(
                classification: source,
                detection: detection(.oneButton, [button])
            )

            #expect(result.state == .wideModalOneButton)
            #expect(result.allowedActions.map(\.name) == [.pressWideModalTopButton])
            #expect(result.allowedActions.first?.target.name == .wideModalTopButton)
            #expect(result.allowedActions.first?.target.rect == button)
            #expect(result.allowedActions.first?.target.sourceText
                    == WideModalActionResolver.measuredPrimaryButtonSentinel)
            #expect(result.evidence.last?.kind == .wideModalGeometry)
            #expect(result.policyGatedActions.isEmpty)
        }
    }

    @Test("Two buttons always select the upper row without OCR text")
    func twoButtonsSelectTopRow() {
        let top = rect(y: 0.51)
        let bottom = rect(y: 0.57)
        for source in [
            classification(.unknown),
            classification(.lootCollectionConfirmation),
            classification(.adventurerRecruitment),
            classification(.retreatConfirmation),
        ] {
            let result = WideModalActionResolver.resolve(
                classification: source,
                detection: detection(.twoButtons, [bottom, top])
            )

            #expect(result.state == .wideModalTwoButtons)
            #expect(result.allowedActions.map(\.name) == [.pressWideModalTopButton])
            #expect(result.allowedActions.first?.target.rect == top)
            #expect(result.allowedActions.first?.target.rect != bottom)
            #expect(result.policyGatedActions.isEmpty)
        }
    }

    @Test("Adjacent measured rows tolerate only floating-point normalization noise")
    func adjacentRowsTolerateNormalizationNoise() {
        let top = NormalizedRect(
            x: 0.108,
            y: 0.6202247191011236,
            width: 0.783,
            height: 0.042134831460674156
        )
        let bottom = NormalizedRect(
            x: 0.108,
            y: 0.6623595505617977,
            width: 0.783,
            height: 0.042134831460674156
        )
        #expect(top.y + top.height > bottom.y)

        let result = WideModalActionResolver.resolve(
            classification: classification(.adventurerRecruitment),
            detection: detection(.twoButtons, [top, bottom])
        )

        #expect(result.state == .wideModalTwoButtons)
        #expect(result.allowedActions.map(\.name) == [.pressWideModalTopButton])
        #expect(result.allowedActions.first?.target.rect == top)

        let materiallyOverlapping = NormalizedRect(
            x: bottom.x,
            y: bottom.y - 0.000_001,
            width: bottom.width,
            height: bottom.height
        )
        let rejected = WideModalActionResolver.resolve(
            classification: classification(.adventurerRecruitment),
            detection: detection(.twoButtons, [top, materiallyOverlapping])
        )
        #expect(rejected.state == .adventurerRecruitment)
        #expect(rejected.allowedActions.isEmpty)
    }

    @Test("The historical returned-party layout follows the one-button rule")
    func historicalReturnedPartyLayoutIsOneButton() {
        let button = rect(y: 0.52)
        let result = WideModalActionResolver.resolve(
            classification: classification(.unknown),
            detection: detection(.returnedPartyManualStop, [button])
        )

        #expect(result.state == .wideModalOneButton)
        #expect(result.allowedActions.map(\.name) == [.pressWideModalTopButton])
        #expect(result.allowedActions.first?.target.rect == button)
    }

    @Test("Incomplete or invalid geometry never produces a modal action")
    func invalidGeometryHasNoAction() {
        let top = rect(y: 0.51)
        let bottom = rect(y: 0.57)
        let invalid = NormalizedRect(x: -0.1, y: 0.5, width: 0.7, height: 0.04)
        let cases: [WideModalButtonDetection] = [
            detection(.none, []),
            detection(.unsupportedButtonCount, [top, bottom, rect(y: 0.63)]),
            detection(.oneButton, []),
            detection(.oneButton, [invalid]),
            detection(.twoButtons, [top]),
            detection(.twoButtons, [top, rect(y: 0.54)]),
        ]

        for item in cases {
            let result = WideModalActionResolver.resolve(
                classification: classification(.unknown),
                detection: item
            )
            #expect(result.state == .unknown)
            #expect(result.allowedActions.isEmpty)
            #expect(result.policyGatedActions.isEmpty)
        }
    }

    @Test("A recognized OCR modal cannot bypass missing pixel geometry")
    func recognizedModalRequiresGeometry() {
        let staleAction = AllowedGameAction(
            name: .confirmLootCollection,
            target: NamedGameTarget(
                name: .lootConfirmationYes,
                sourceText: "是",
                rect: rect(y: 0.51),
                point: rect(y: 0.51).center
            )
        )
        let source = GameStateClassification(
            state: .lootCollectionConfirmation,
            evidence: [],
            allowedActions: [staleAction]
        )
        let result = WideModalActionResolver.resolve(
            classification: source,
            detection: detection(.none, [])
        )

        #expect(result.state == .lootCollectionConfirmation)
        #expect(result.allowedActions.isEmpty)
        #expect(result.policyGatedActions.isEmpty)
    }

    @Test("Three or more rows block every actionable background state")
    func unsupportedButtonCountBlocksBackgroundAction() {
        let backgroundAction = AllowedGameAction(
            name: .selectMissionRepeat,
            target: NamedGameTarget(
                name: .missionRepeatOption,
                sourceText: "重複進行此任務",
                rect: rect(y: 0.23),
                point: rect(y: 0.23).center
            )
        )
        let result = WideModalActionResolver.resolve(
            classification: GameStateClassification(
                state: .missionComplete,
                evidence: [],
                allowedActions: [backgroundAction]
            ),
            detection: detection(
                .unsupportedButtonCount,
                [rect(y: 0.47), rect(y: 0.53), rect(y: 0.59)]
            )
        )

        #expect(result.state == .unknown)
        #expect(result.allowedActions.isEmpty)
        #expect(result.policyGatedActions.isEmpty)
        #expect(result.evidence.contains { $0.kind == .conflictingStateMarkers })
    }

    private var conflictEvidence: GameStateEvidence {
        GameStateEvidence(
            kind: .conflictingStateMarkers,
            observation: nil,
            detail: "OCR conflict retained for diagnostics"
        )
    }

    private func classification(
        _ state: GameState,
        evidence: [GameStateEvidence] = []
    ) -> GameStateClassification {
        GameStateClassification(state: state, evidence: evidence, allowedActions: [])
    }

    private func detection(
        _ layout: WideModalLayout,
        _ rects: [NormalizedRect]
    ) -> WideModalButtonDetection {
        WideModalButtonDetection(
            buttons: rects.map(WideModalButton.init),
            layout: layout,
            dialogRect: nil
        )
    }

    private func rect(y: Double) -> NormalizedRect {
        NormalizedRect(x: 0.108, y: y, width: 0.783, height: 0.04)
    }
}
