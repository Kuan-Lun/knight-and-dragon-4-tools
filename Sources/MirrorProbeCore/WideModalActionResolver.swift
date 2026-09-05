import Foundation

/// Turns the game's calibrated wide modal rows into actions.
///
/// The user-authorized rule is geometry-first: one detected row means press that row, while two
/// detected rows mean press the upper row. OCR remains useful diagnostic evidence, but is not a
/// prerequisite for a valid modal action.
public enum WideModalActionResolver {
    public static let measuredPrimaryButtonSentinel = "<measured-wide-modal-primary-button>"

    public static func resolve(
        classification: GameStateClassification,
        detection: WideModalButtonDetection
    ) -> GameStateClassification {
        let requiredCount: Int
        let modalState: GameState
        switch detection.layout {
        case .oneButton, .returnedPartyManualStop:
            // `returnedPartyManualStop` is retained only so older reports remain decodable.
            // Current detection emits `oneButton` for this layout as well.
            requiredCount = 1
            modalState = .wideModalOneButton
        case .twoButtons:
            requiredCount = 2
            modalState = .wideModalTwoButtons
        case .unsupportedButtonCount:
            return GameStateClassification(
                state: .unknown,
                evidence: classification.evidence + [
                    GameStateEvidence(
                        kind: .conflictingStateMarkers,
                        observation: nil,
                        detail: "Unsupported wide modal button count: \(detection.buttons.count)"
                    ),
                ],
                allowedActions: [],
                policyGatedActions: []
            )
        case .none:
            return isOCRRecognizedModal(classification.state)
                ? classificationWithoutActions(classification)
                : classification
        }

        let orderedButtons = detection.buttons.sorted {
            if $0.rect.center.y == $1.rect.center.y {
                return $0.rect.center.x < $1.rect.center.x
            }
            return $0.rect.center.y < $1.rect.center.y
        }
        guard orderedButtons.count == requiredCount,
              orderedButtons.allSatisfy({ $0.rect.isValid }),
              let primaryButton = orderedButtons.first,
              rowsAreDistinctAndOrdered(orderedButtons)
        else {
            return isOCRRecognizedModal(classification.state)
                ? classificationWithoutActions(classification)
                : classification
        }

        let measuredEvidence = GameStateEvidence(
            kind: .wideModalGeometry,
            observation: nil,
            detail: "layout=\(detection.layout.rawValue), "
                + "underlyingState=\(classification.state.rawValue), "
                + "buttonCount=\(requiredCount)"
        )
        return GameStateClassification(
            state: modalState,
            evidence: classification.evidence + [measuredEvidence],
            allowedActions: [AllowedGameAction(
                name: .pressWideModalTopButton,
                target: target(.wideModalTopButton, rect: primaryButton.rect)
            )],
            policyGatedActions: []
        )
    }

    private static func rowsAreDistinctAndOrdered(_ buttons: [WideModalButton]) -> Bool {
        guard buttons.count == 2 else { return true }
        let top = buttons[0].rect
        let bottom = buttons[1].rect
        // Pixel-band coordinates are normalized independently. Two rows which share the same
        // measured edge can therefore differ by one floating-point ULP after division, making
        // `top.y + top.height` microscopically larger than `bottom.y`. Accept numerical noise
        // only; a real overlap remains rejected.
        let normalizationTolerance = 1e-12
        return top.center.y < bottom.center.y
            && top.y + top.height <= bottom.y + normalizationTolerance
    }

    private static func isOCRRecognizedModal(_ state: GameState) -> Bool {
        switch state {
        case .battleEncounterPrompt, .battleEventPrompt, .defeatPrompt,
             .lootCollectionConfirmation, .adventurerRecruitment, .retreatConfirmation:
            return true
        default:
            return false
        }
    }

    private static func classificationWithoutActions(
        _ classification: GameStateClassification
    ) -> GameStateClassification {
        GameStateClassification(
            state: classification.state,
            evidence: classification.evidence,
            allowedActions: [],
            policyGatedActions: []
        )
    }

    private static func target(
        _ name: GameTargetName,
        rect: NormalizedRect
    ) -> NamedGameTarget {
        NamedGameTarget(
            name: name,
            sourceText: measuredPrimaryButtonSentinel,
            rect: rect,
            point: rect.center
        )
    }
}
