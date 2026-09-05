import Foundation

/// OCR observations use a top-left origin and normalized coordinates in the closed range 0...1.
public struct OCRTextObservation: Codable, Equatable, Sendable {
    public let text: String
    public let rect: NormalizedRect
    public let confidence: Double

    public init(text: String, rect: NormalizedRect, confidence: Double) {
        self.text = text
        self.rect = rect
        self.confidence = confidence
    }
}

public struct NormalizedRect: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var center: NormalizedPoint {
        NormalizedPoint(x: x + width / 2, y: y + height / 2)
    }

    public var isValid: Bool {
        x.isFinite
            && y.isFinite
            && width.isFinite
            && height.isFinite
            && x >= 0
            && y >= 0
            && width > 0
            && height > 0
            && x + width <= 1
            && y + height <= 1
    }
}

public struct NormalizedPoint: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public enum GameState: String, Codable, Equatable, Sendable {
    case missionComplete
    case missionCompleteRepeatSelected
    /// Calibrated central modals established from rendered button geometry rather than OCR text.
    /// The separate states let a one-row modal transition directly into a two-row modal (or vice
    /// versa) without being mistaken for the same dialog.
    case wideModalOneButton
    case wideModalTwoButtons
    case missionFailed
    case missionFailedRepeatSelected
    case lootCollectionConfirmation
    case adventurerRecruitment
    case defeatPrompt
    case retreatConfirmation
    case battleEventPrompt
    case battleEncounterPrompt
    case battle
    case defeat
    case inventoryFull
    case unknown
}

public enum GameEvidenceKind: String, Codable, Equatable, Sendable {
    case missionCompleteTitle
    case missionFailedTitle
    case missionRepeatOption
    case repeatSelectedMarker
    /// Identifies the successful result page whose body lists earned EXP.
    case missionExperiencePage
    /// Identifies the successful result page whose body lists collected loot.
    case missionLootPage
    case wideModalGeometry
    case missionCompleteAdvance
    /// Records the runtime's fixed top-row result continuation target. The result state and page
    /// identity still come from the classifier; OCR of the decorative `>>` glyph is unnecessary.
    case missionResultAdvanceMeasuredFallback
    /// Records the sole opt-in case where an empty, separately retried top ROI permits the
    /// controller to use the calibrated loot-page continuation rectangle without OCR geometry.
    case missionCompleteAdvanceMeasuredFallback
    case lootCollectionPrompt
    case confirmationTitle
    case adventurerRecruitmentTitle
    case adventurerRecruitmentPrompt
    case adventurerRecruitOption
    case adventurerLeaveOption
    case defeatPromptMessage
    case defeatPromptClose
    case retreatConfirmationPrompt
    case retreatCharmLossWarning
    case battleEventDescription
    case battleEventClose
    case battleEncounterTitle
    case battleEncounterDescription
    case battleEncounterClose
    case battleMarker
    case defeatMarker
    case inventoryFullMarker
    case invalidObservation
    case lowConfidenceMarker
    case conflictingStateMarkers
}

public struct GameStateEvidence: Codable, Equatable, Sendable {
    public let kind: GameEvidenceKind
    public let observation: OCRTextObservation?
    public let detail: String

    public init(
        kind: GameEvidenceKind,
        observation: OCRTextObservation?,
        detail: String
    ) {
        self.kind = kind
        self.observation = observation
        self.detail = detail
    }
}

public enum GameActionName: String, Codable, Equatable, Sendable {
    case selectMissionRepeat
    /// Activates the result page's layout-specific continuation glyph after repeat is selected.
    case advanceMissionComplete
    case recruitAdventurer
    /// Retained for decoding older reports; the auto-level policy no longer emits this action.
    case leaveAdventurer
    case closeBattlePrompt
    case pressWideModalTopButton
    case enableAutoBattle
    case confirmLootCollection
    /// Opens the destructive retreat confirmation sheet. This is never a normal allowed action.
    case openBattleRetreatConfirmation
    /// Legacy serialized name; confirms the runtime's retreat transaction regardless of talismans.
    case confirmNoTalismanRetreat
}

public enum GameTargetName: String, Codable, Equatable, Sendable {
    case missionRepeatOption
    case missionCompleteAdvance
    case adventurerRecruit
    /// Retained for decoding older reports; the auto-level policy no longer targets this control.
    case adventurerLeave
    case battlePromptClose
    case wideModalTopButton
    case battleAuto
    case lootConfirmationYes
    case battleRetreat
    case retreatConfirmationYes
}

/// An action target is normally traceable to one exact OCR observation. The sole exception is the
/// explicitly tagged, opt-in loot-page measured fallback, which is emitted only after a caller has
/// independently retried an empty top-glyph ROI and the classifier has verified its exact layout.
public struct NamedGameTarget: Codable, Equatable, Sendable {
    public let name: GameTargetName
    public let sourceText: String
    public let rect: NormalizedRect
    public let point: NormalizedPoint

    public init(
        name: GameTargetName,
        sourceText: String,
        rect: NormalizedRect,
        point: NormalizedPoint
    ) {
        self.name = name
        self.sourceText = sourceText
        self.rect = rect
        self.point = point
    }
}

public struct AllowedGameAction: Codable, Equatable, Sendable {
    public let name: GameActionName
    public let target: NamedGameTarget

    public init(name: GameActionName, target: NamedGameTarget) {
        self.name = name
        self.target = target
    }
}

/// An action target that the classifier can locate, but that a caller must not execute merely
/// because it is present. The runtime must satisfy the named policy using evidence outside this
/// single OCR snapshot before promoting the candidate to an actual click.
public enum GameActionPolicyRequirement: String, Codable, Equatable, Sendable {
    case temporalDefeatRecovery
    case explicitRetreatConfirmation
}

public struct PolicyGatedGameAction: Codable, Equatable, Sendable {
    public let name: GameActionName
    public let target: NamedGameTarget
    public let requirement: GameActionPolicyRequirement

    public init(
        name: GameActionName,
        target: NamedGameTarget,
        requirement: GameActionPolicyRequirement
    ) {
        self.name = name
        self.target = target
        self.requirement = requirement
    }
}

public struct GameStateClassification: Codable, Equatable, Sendable {
    public let state: GameState
    public let evidence: [GameStateEvidence]
    public let allowedActions: [AllowedGameAction]
    public let policyGatedActions: [PolicyGatedGameAction]

    public init(
        state: GameState,
        evidence: [GameStateEvidence],
        allowedActions: [AllowedGameAction],
        policyGatedActions: [PolicyGatedGameAction] = []
    ) {
        self.state = state
        self.evidence = evidence
        self.allowedActions = allowedActions
        self.policyGatedActions = policyGatedActions
    }
}

public enum GameStateClassifier {
    public static let minimumMarkerConfidence = 0.60
    public static let minimumActionGlyphConfidence = 0.30
    public static let measuredLootTopAdvanceSentinel = "<measured-loot-top-advance>"
    public static let measuredLootTopAdvanceRect = NormalizedRect(
        x: 0.024630541297208562,
        y: 0.19775280880149815,
        width: 0.04433497536945812,
        height: 0.011235955056179803
    )

    /// Classifies one OCR snapshot plus optional rendered-pixel evidence. This function is
    /// intentionally conservative:
    /// invalid input or mutually inconsistent state markers always produces `unknown`, and
    /// only explicitly whitelisted state-and-target combinations can contain an allowed action.
    /// `permitMeasuredLootTopAdvanceFallback` must remain false for the initial whole-frame OCR
    /// pass. A caller may opt in only after a separate measured top-ROI OCR pass returned no text.
    public static func classify(
        observations: [OCRTextObservation],
        permitMeasuredLootTopAdvanceFallback: Bool = false,
        repeatSelectedStampDetection: RepeatSelectedStampDetection? = nil
    ) -> GameStateClassification {
        if let repeatSelectedStampDetection,
           !repeatSelectedStampDetection.isValid
        {
            return GameStateClassification(
                state: .unknown,
                evidence: [GameStateEvidence(
                    kind: .invalidObservation,
                    observation: nil,
                    detail: "The repeat-selection pixel detection was invalid"
                )],
                allowedActions: []
            )
        }

        let invalid = observations.filter {
            !$0.rect.isValid
                || canonicalText($0.text).isEmpty
                || !$0.confidence.isFinite
                || !(0...1).contains($0.confidence)
        }
        guard invalid.isEmpty else {
            return GameStateClassification(
                state: .unknown,
                evidence: invalid.map {
                    GameStateEvidence(
                        kind: .invalidObservation,
                        observation: $0,
                        detail: "OCR text and its normalized rectangle must both be valid"
                    )
                },
                allowedActions: []
            )
        }

        let indexed = observations.map { IndexedObservation(observation: $0) }
        let modalCloseMarkers = indexed.filter {
            modalCloseTexts.contains($0.canonicalText)
        }
        let battlePromptBackground = battlePromptBackgroundEvidence(in: indexed)

        // The defeat prompt uses unusually low-confidence OCR in the measured fixture. It is
        // checked first so its 0.30 `關閉` marker cannot be rejected as another modal's partial.
        let defeatPromptMessages = indexed.filter {
            isDefeatPromptMessageText($0.canonicalText)
        }
        if !defeatPromptMessages.isEmpty {
            let defeatPromptMarkers = defeatPromptMessages + modalCloseMarkers
            let lowConfidenceMarkers = defeatPromptMarkers.filter {
                $0.observation.confidence < minimumDefeatPromptMarkerConfidence
            }
            guard lowConfidenceMarkers.isEmpty else {
                return lowConfidence(
                    lowConfidenceMarkers,
                    detail: "A defeat-prompt marker was below its fixed confidence threshold"
                )
            }

            let promptEvidence = defeatPromptMessages.map {
                evidence(.defeatPromptMessage, $0)
            } + modalCloseMarkers.map {
                evidence(.defeatPromptClose, $0)
            }
            guard defeatPromptMessages.count == 1,
                  modalCloseMarkers.count == 1,
                  let message = defeatPromptMessages.first,
                  let close = modalCloseMarkers.first,
                  isDefeatPromptMessageRegion(message.observation.rect),
                  isDefeatPromptCloseRegion(close.observation.rect)
            else {
                return conflict(
                    promptEvidence,
                    detail: "An incomplete, misplaced, or ambiguous defeat prompt was observed"
                )
            }

            // The defeated-party overlay is drawn above the retreat sheet; exactly one inert
            // underlying `否` label remains OCR-visible immediately below `關閉` in every measured
            // frame. Only that narrowly positioned label is tolerated. `是`, duplicate/misplaced
            // `否`, warning text, and every other sensitive marker still conflict.
            let conflictingMarkers = battlePromptConflictingMarkers(
                in: indexed,
                toleratingDefeatUnderlyingNoBelow: close
            )
            guard conflictingMarkers.isEmpty else {
                return conflict(
                    promptEvidence + conflictingMarkers.map {
                        evidence(.conflictingStateMarkers, $0)
                    },
                    detail: "A defeat prompt was observed with conflicting controls"
                )
            }
            return GameStateClassification(
                state: .defeatPrompt,
                evidence: promptEvidence,
                allowedActions: [closeBattlePromptAction(targeting: close)]
            )
        }

        let retreatConfirmationPrompts = indexed.filter {
            isRetreatConfirmationPromptText($0.canonicalText)
        }
        let retreatCharmLossWarnings = indexed.filter {
            isRetreatCharmLossWarningText($0.canonicalText)
        }
        let retreatConfirmationMarkers = retreatConfirmationPrompts + retreatCharmLossWarnings
        if !retreatConfirmationMarkers.isEmpty {
            let lowConfidenceMarkers = retreatConfirmationMarkers.filter {
                $0.observation.confidence < minimumRetreatConfirmationMarkerConfidence
            }
            guard lowConfidenceMarkers.isEmpty else {
                return lowConfidence(
                    lowConfidenceMarkers,
                    detail: "A retreat-confirmation marker was below its fixed confidence threshold"
                )
            }

            let confirmationEvidence = retreatConfirmationPrompts.map {
                evidence(.retreatConfirmationPrompt, $0)
            } + retreatCharmLossWarnings.map {
                evidence(.retreatCharmLossWarning, $0)
            }
            guard retreatConfirmationPrompts.count == 1,
                  retreatCharmLossWarnings.count == 1,
                  let prompt = retreatConfirmationPrompts.first,
                  let warning = retreatCharmLossWarnings.first,
                  isRetreatConfirmationPromptRegion(prompt.observation.rect),
                  isRetreatCharmLossWarningRegion(warning.observation.rect)
            else {
                return conflict(
                    confirmationEvidence,
                    detail: "An incomplete, misplaced, or ambiguous retreat confirmation was observed"
                )
            }

            let conflictingMarkers = retreatConfirmationConflictingMarkers(in: indexed)
            guard conflictingMarkers.isEmpty else {
                return conflict(
                    confirmationEvidence + conflictingMarkers.map {
                        evidence(.conflictingStateMarkers, $0)
                    },
                    detail: "A retreat confirmation was observed with conflicting state markers"
                )
            }

            let yesCandidates = indexed.filter { $0.canonicalText == "是" }
            let noCandidates = indexed.filter { $0.canonicalText == "否" }
            let policyGatedActions: [PolicyGatedGameAction]
            if yesCandidates.isEmpty && noCandidates.isEmpty {
                policyGatedActions = []
            } else {
                guard yesCandidates.count == 1,
                      noCandidates.count == 1,
                      modalCloseMarkers.isEmpty,
                      let yes = yesCandidates.first,
                      let no = noCandidates.first
                else {
                    return conflict(
                        confirmationEvidence,
                        detail: "Retreat decision controls were incomplete or ambiguous"
                    )
                }
                let lowConfidenceDecisions = [yes, no].filter {
                    $0.observation.confidence < minimumDecisionControlConfidence
                }
                guard lowConfidenceDecisions.isEmpty else {
                    return lowConfidence(
                        lowConfidenceDecisions,
                        detail: "A retreat decision control was below its fixed confidence threshold"
                    )
                }
                guard isRetreatConfirmationYesRegion(yes.observation.rect),
                      isRetreatConfirmationNoRegion(no.observation.rect)
                else {
                    return conflict(
                        confirmationEvidence,
                        detail: "A retreat decision control was outside its measured region"
                    )
                }

                // A recognized confirmation is not an independent retreat authorization. The
                // runtime must bind it to its already-posted recovery action. Talisman use does
                // not affect this candidate or the user's authorization to retreat.
                policyGatedActions = [
                    PolicyGatedGameAction(
                        name: .confirmNoTalismanRetreat,
                        target: target(.retreatConfirmationYes, from: yes),
                        requirement: .explicitRetreatConfirmation
                    ),
                ]
            }
            return GameStateClassification(
                state: .retreatConfirmation,
                evidence: confirmationEvidence,
                allowedActions: [],
                policyGatedActions: policyGatedActions
            )
        }

        // A battle event description also contains `魔怪`, so it must be resolved before the
        // broader encounter-description predicate sees the shared `關閉` marker.
        let battleEventDescriptions = indexed.filter {
            isBattleEventDescriptionText($0.canonicalText)
        }
        if !battleEventDescriptions.isEmpty {
            let lowConfidenceDescriptions = battleEventDescriptions.filter {
                $0.observation.confidence < minimumBattleEventDescriptionConfidence
            }
            let lowConfidenceCloses = modalCloseMarkers.filter {
                $0.observation.confidence < minimumBattleEventCloseConfidence
            }
            let lowConfidenceMarkers = lowConfidenceDescriptions + lowConfidenceCloses
            guard lowConfidenceMarkers.isEmpty else {
                return lowConfidence(
                    lowConfidenceMarkers,
                    detail: "A battle-event modal marker was below its measured confidence threshold"
                )
            }

            let eventEvidence = battleEventDescriptions.map {
                evidence(.battleEventDescription, $0)
            } + modalCloseMarkers.map {
                evidence(.battleEventClose, $0)
            }
            let conflictingMarkers = battlePromptConflictingMarkers(in: indexed)
            guard battleEventDescriptions.count == 1,
                  modalCloseMarkers.count == 1,
                  conflictingMarkers.isEmpty
            else {
                return conflict(
                    eventEvidence + conflictingMarkers.map {
                        evidence(.conflictingStateMarkers, $0)
                    },
                    detail: "An incomplete or ambiguous battle-event modal was observed"
                )
            }

            let actions: [AllowedGameAction]
            if let description = battleEventDescriptions.first,
               let close = modalCloseMarkers.first,
               isBattleEventDescriptionRegion(description.observation.rect),
               isBattleEncounterCloseRegion(close.observation.rect)
            {
                actions = [closeBattlePromptAction(targeting: close)]
            } else {
                actions = []
            }
            return GameStateClassification(
                state: .battleEventPrompt,
                evidence: eventEvidence,
                allowedActions: actions
            )
        }

        let battleEncounterTitles = indexed.filter {
            isBattleEncounterTitleText($0.canonicalText)
        }
        let trustedBattleEncounterTitles = battleEncounterTitles.filter {
            $0.observation.confidence >= minimumBattleEncounterTitleConfidence
        }
        let battleEncounterDescriptions = indexed.filter {
            isBattleEncounterDescriptionRegion($0.observation.rect)
                && isBattleEncounterDescriptionText($0.canonicalText)
                && !isBattleEncounterTitleText($0.canonicalText)
                && !modalCloseTexts.contains($0.canonicalText)
        }
        let hasBattleEncounterHint = !battleEncounterTitles.isEmpty
            || !battleEncounterDescriptions.isEmpty
            || !modalCloseMarkers.isEmpty
        if hasBattleEncounterHint {
            // Vision measured the exact modal title at 0.50 and its exact close label at 0.30.
            // These exceptions are deliberately local to the modal anchors. Narrative text is
            // optional and can be split into several OCR fragments, so it is supporting evidence
            // only. When a trusted title is absent, a unique central close marker requires a
            // stricter fingerprint of independent battle-background anchors.
            let lowConfidenceTitles = battleEncounterTitles.filter {
                $0.observation.confidence < minimumBattleEncounterTitleConfidence
            }
            let lowConfidenceMarkers = (
                battlePromptBackground.isComplete ? [] : lowConfidenceTitles
            ) + modalCloseMarkers.filter {
                $0.observation.confidence < minimumBattleEncounterCloseConfidence
            }
            guard lowConfidenceMarkers.isEmpty else {
                return lowConfidence(
                    lowConfidenceMarkers,
                    detail: "A required battle-encounter anchor was below its measured confidence threshold"
                )
            }

            let encounterEvidence = trustedBattleEncounterTitles.map {
                evidence(.battleEncounterTitle, $0)
            } + battleEncounterDescriptions.map {
                evidence(.battleEncounterDescription, $0)
            } + modalCloseMarkers.map {
                evidence(.battleEncounterClose, $0)
            }

            // Battle controls are expected underneath this overlay. Other exact state markers
            // are not, and must stop classification rather than letting the modal hide them.
            let conflictingMarkers = indexed.filter {
                safetyCriticalMarkerTexts.contains($0.canonicalText)
                    || isLootCollectionPrompt($0.canonicalText)
                    || confirmationTitleTexts.contains($0.canonicalText)
                    || isBattlePromptExclusiveConflictText($0.canonicalText)
            }
            guard modalCloseMarkers.count == 1,
                  let close = modalCloseMarkers.first,
                  isBattleEncounterCloseRegion(close.observation.rect),
                  battleEncounterTitles.count <= 1,
                  conflictingMarkers.isEmpty
            else {
                return conflict(
                    encounterEvidence + conflictingMarkers.map {
                        evidence(.conflictingStateMarkers, $0)
                    },
                    detail: "An incomplete, misplaced, or ambiguous battle-encounter modal was observed"
                )
            }

            let isSpecificEncounter: Bool
            if trustedBattleEncounterTitles.isEmpty {
                isSpecificEncounter = false
            } else if trustedBattleEncounterTitles.count == 1,
                      let title = trustedBattleEncounterTitles.first,
                      isBattleEncounterTitleRegion(title.observation.rect),
                      isBattleEncounterAnchorPair(title: title, close: close)
            {
                isSpecificEncounter = true
            } else {
                return conflict(
                    encounterEvidence,
                    detail: "An incomplete, misplaced, or ambiguous battle-encounter modal was observed"
                )
            }

            guard isSpecificEncounter || battlePromptBackground.isComplete else {
                return conflict(
                    encounterEvidence + battlePromptBackground.evidence,
                    detail: "A title-free close marker lacked a complete battle-background fingerprint"
                )
            }

            var finalEvidence = encounterEvidence
            if !isSpecificEncounter {
                finalEvidence += battlePromptBackground.evidence
            }
            return GameStateClassification(
                state: .battleEncounterPrompt,
                evidence: finalEvidence,
                allowedActions: [closeBattlePromptAction(targeting: close)]
            )
        }

        let trustedBattleMarkers = indexed.filter {
            isBattleMarkerText($0.canonicalText)
                && $0.observation.confidence >= minimumMarkerConfidence
        }
        let battleRoundMarkers = indexed.filter {
            isBattleRoundText($0.canonicalText)
        }
        let trustedBattleRoundMarkers = battleRoundMarkers.filter {
            $0.observation.confidence >= minimumBattleRoundConfidence
        }
        let isStrictBattle = isConfirmedBattle(markers: trustedBattleMarkers)
        let isFallbackBattle = isConfirmedBattleFallback(
            markers: trustedBattleMarkers,
            roundMarkers: trustedBattleRoundMarkers
        )
        let isControlStackBattle = isConfirmedBattleControlStackFallback(in: indexed)
        let controlGridBattleMarkers = confirmedBattleControlGridFallback(in: indexed)
        let isControlGridBattle = controlGridBattleMarkers != nil
        let isBattle = isStrictBattle
            || isFallbackBattle
            || isControlStackBattle
            || isControlGridBattle

        let lowConfidenceMarkers = indexed.filter {
            let isNonBattleSafetyMarker = safetyCriticalMarkerTexts.contains($0.canonicalText)
                || isLootCollectionPrompt($0.canonicalText)
                || confirmationTitleTexts.contains($0.canonicalText)
                || isMissionSuccessPageText($0.canonicalText)
            let isUncorroboratedBattleMarker = isBattleMarkerText($0.canonicalText) && !isBattle
            return (isNonBattleSafetyMarker || isUncorroboratedBattleMarker)
                && $0.observation.confidence < minimumMarkerConfidence
        }
        let lowConfidenceBattleRoundMarkers = isBattle ? [] : battleRoundMarkers.filter {
            $0.observation.confidence < minimumBattleRoundConfidence
        }
        // When rendered-pixel evidence is available, OCR of the red stamp is diagnostic only.
        // Vision routinely substitutes letters in this stylized, low-contrast word.
        let lowConfidenceSelectedMarkers = repeatSelectedStampDetection?.isPresent == true
            ? []
            : indexed.filter {
                isRepeatSelectedText($0.canonicalText)
                    && $0.observation.confidence < minimumActionGlyphConfidence
            }
        guard lowConfidenceMarkers.isEmpty,
              lowConfidenceBattleRoundMarkers.isEmpty,
              lowConfidenceSelectedMarkers.isEmpty
        else {
            return GameStateClassification(
                state: .unknown,
                evidence: (
                    lowConfidenceMarkers
                        + lowConfidenceBattleRoundMarkers
                        + lowConfidenceSelectedMarkers
                ).map {
                    GameStateEvidence(
                        kind: .lowConfidenceMarker,
                        observation: $0.observation,
                        detail: "A known state marker was below the fixed confidence threshold"
                    )
                },
                allowedActions: []
            )
        }
        let trusted = indexed.filter {
            $0.observation.confidence >= minimumMarkerConfidence
        }
        let inventoryMarkers = trusted.filter { inventoryFullTexts.contains($0.canonicalText) }
        let defeatMarkers = trusted.filter { defeatTexts.contains($0.canonicalText) }
        let missionTitles = trusted.filter {
            missionCompleteTexts.contains($0.canonicalText) && isMissionTitleRegion($0.observation.rect)
        }
        // Provisional recovery path observed after a manual retreat. This exact title does not
        // claim to cover every natural-defeat flow; unknown defeat variants remain stop-only.
        let missionFailedTitles = trusted.filter {
            missionFailedTexts.contains($0.canonicalText) && isMissionTitleRegion($0.observation.rect)
        }
        let battleMarkers = trustedBattleMarkers
        let lootPrompts = trusted.filter { isLootCollectionPrompt($0.canonicalText) }
        let confirmationTitles = trusted.filter { confirmationTitleTexts.contains($0.canonicalText) }
        let adventurerRecruitmentTitles = trusted.filter {
            adventurerRecruitmentTitleTexts.contains($0.canonicalText)
        }
        let adventurerRecruitmentPrompts = trusted.filter {
            adventurerRecruitmentPromptTexts.contains($0.canonicalText)
        }
        let adventurerRecruitMarkers = indexed.filter {
            adventurerRecruitTexts.contains($0.canonicalText)
        }
        let trustedAdventurerRecruitMarkers = adventurerRecruitMarkers.filter {
            $0.observation.confidence >= minimumMarkerConfidence
        }
        let adventurerLeaveMarkers = indexed.filter {
            adventurerLeaveTexts.contains($0.canonicalText)
        }

        if !adventurerRecruitmentTitles.isEmpty
            || !adventurerRecruitmentPrompts.isEmpty
            || !adventurerRecruitMarkers.isEmpty
            || !adventurerLeaveMarkers.isEmpty
        {
            let recruitmentEvidence = adventurerRecruitmentTitles.map {
                evidence(.adventurerRecruitmentTitle, $0)
            } + adventurerRecruitmentPrompts.map {
                evidence(.adventurerRecruitmentPrompt, $0)
            } + adventurerRecruitMarkers.map {
                evidence(.adventurerRecruitOption, $0)
            } + adventurerLeaveMarkers.map {
                evidence(.adventurerLeaveOption, $0)
            }
            guard adventurerRecruitmentTitles.count == 1,
                  adventurerRecruitmentPrompts.count == 1
            else {
                return conflict(
                    recruitmentEvidence,
                    detail: "An incomplete or ambiguous adventurer-recruitment modal was observed"
                )
            }

            let actions: [AllowedGameAction]
            let hasConflictingActionBlocker = !lootPrompts.isEmpty
                || !confirmationTitles.isEmpty
                || !inventoryMarkers.isEmpty
                || !defeatMarkers.isEmpty
                || !missionFailedTitles.isEmpty
                || !battleMarkers.isEmpty
                || !trustedBattleRoundMarkers.isEmpty
            if !hasConflictingActionBlocker,
               adventurerRecruitMarkers.count == 1,
               trustedAdventurerRecruitMarkers.count == 1,
               let recruit = trustedAdventurerRecruitMarkers.first,
               isAdventurerRecruitRegion(recruit.observation.rect)
            {
                actions = [
                    AllowedGameAction(
                        name: .recruitAdventurer,
                        target: target(.adventurerRecruit, from: recruit)
                    ),
                ]
            } else {
                actions = []
            }
            return GameStateClassification(
                state: .adventurerRecruitment,
                evidence: recruitmentEvidence,
                allowedActions: actions
            )
        }

        if !lootPrompts.isEmpty || !confirmationTitles.isEmpty {
            let confirmationEvidence = confirmationTitles.map {
                evidence(.confirmationTitle, $0)
            } + lootPrompts.map {
                evidence(.lootCollectionPrompt, $0)
            }
            guard lootPrompts.count == 1,
                  confirmationTitles.count == 1,
                  let title = confirmationTitles.first,
                  let prompt = lootPrompts.first,
                  isLootConfirmationTitleRegion(title.observation.rect),
                  isLootConfirmationPromptRegion(prompt.observation.rect)
            else {
                return conflict(
                    confirmationEvidence,
                    detail: "An incomplete, misplaced, or ambiguous loot confirmation was observed"
                )
            }

            let conflictingMarkers = lootConfirmationConflictingMarkers(in: indexed)
            guard conflictingMarkers.isEmpty, !isBattle else {
                return conflict(
                    confirmationEvidence + conflictingMarkers.map {
                        evidence(.conflictingStateMarkers, $0)
                    },
                    detail: "A loot confirmation was observed with conflicting state markers"
                )
            }

            let yesCandidates = indexed.filter { $0.canonicalText == "是" }
            let noCandidates = indexed.filter { $0.canonicalText == "否" }
            let actions: [AllowedGameAction]
            if yesCandidates.isEmpty && noCandidates.isEmpty {
                actions = []
            } else {
                guard yesCandidates.count == 1,
                      noCandidates.count == 1,
                      let yes = yesCandidates.first,
                      let no = noCandidates.first
                else {
                    return conflict(
                        confirmationEvidence,
                        detail: "Loot-confirmation decision controls were incomplete or ambiguous"
                    )
                }
                let lowConfidenceDecisions = [yes, no].filter {
                    $0.observation.confidence < minimumDecisionControlConfidence
                }
                guard lowConfidenceDecisions.isEmpty else {
                    return lowConfidence(
                        lowConfidenceDecisions,
                        detail: "A loot-confirmation decision control was below its fixed confidence threshold"
                    )
                }
                guard isLootConfirmationYesRegion(yes.observation.rect),
                      isLootConfirmationNoRegion(no.observation.rect)
                else {
                    return conflict(
                        confirmationEvidence,
                        detail: "A loot-confirmation decision control was outside its measured region"
                    )
                }
                actions = [
                    AllowedGameAction(
                        name: .confirmLootCollection,
                        target: target(.lootConfirmationYes, from: yes)
                    ),
                ]
            }
            return GameStateClassification(
                state: .lootCollectionConfirmation,
                evidence: confirmationEvidence,
                allowedActions: actions
            )
        }

        if !inventoryMarkers.isEmpty && !defeatMarkers.isEmpty {
            return conflict(
                inventoryMarkers.map { evidence(.inventoryFullMarker, $0) }
                    + defeatMarkers.map { evidence(.defeatMarker, $0) },
                detail: "Both inventory-full and defeat markers were observed"
            )
        }

        if !inventoryMarkers.isEmpty {
            return GameStateClassification(
                state: .inventoryFull,
                evidence: inventoryMarkers.map { evidence(.inventoryFullMarker, $0) },
                allowedActions: []
            )
        }

        if !defeatMarkers.isEmpty {
            return GameStateClassification(
                state: .defeat,
                evidence: defeatMarkers.map { evidence(.defeatMarker, $0) },
                allowedActions: []
            )
        }

        if !missionTitles.isEmpty && !missionFailedTitles.isEmpty {
            return conflict(
                missionTitles.map { evidence(.missionCompleteTitle, $0) }
                    + missionFailedTitles.map { evidence(.missionFailedTitle, $0) },
                detail: "Mission-complete and mission-failed titles were observed together"
            )
        }

        if (!missionTitles.isEmpty || !missionFailedTitles.isEmpty)
            && (!battleMarkers.isEmpty || !trustedBattleRoundMarkers.isEmpty)
        {
            return conflict(
                missionTitles.map { evidence(.missionCompleteTitle, $0) }
                    + missionFailedTitles.map { evidence(.missionFailedTitle, $0) }
                    + battleMarkers.map { evidence(.battleMarker, $0) }
                    + trustedBattleRoundMarkers.map { evidence(.battleMarker, $0) },
                detail: "A mission-result title and battle markers were observed together"
            )
        }

        if missionTitles.count > 1 {
            return conflict(
                missionTitles.map { evidence(.missionCompleteTitle, $0) },
                detail: "More than one mission-complete title candidate was observed"
            )
        }

        if missionFailedTitles.count > 1 {
            return conflict(
                missionFailedTitles.map { evidence(.missionFailedTitle, $0) },
                detail: "More than one mission-failed title candidate was observed"
            )
        }

        if let title = missionFailedTitles.first {
            return classifyMissionResult(
                indexed: indexed,
                title: title,
                titleEvidenceKind: .missionFailedTitle,
                state: .missionFailed,
                selectedState: .missionFailedRepeatSelected,
                permitMeasuredLootTopAdvanceFallback: false,
                repeatSelectedStampDetection: repeatSelectedStampDetection
            )
        }

        if let title = missionTitles.first {
            return classifyMissionResult(
                indexed: indexed,
                title: title,
                titleEvidenceKind: .missionCompleteTitle,
                state: .missionComplete,
                selectedState: .missionCompleteRepeatSelected,
                permitMeasuredLootTopAdvanceFallback: permitMeasuredLootTopAdvanceFallback,
                repeatSelectedStampDetection: repeatSelectedStampDetection
            )
        }

        if isBattle {
            let battleEvidenceMarkers = isControlGridBattle
                && !isStrictBattle
                && !isFallbackBattle
                && !isControlStackBattle
                ? controlGridBattleMarkers ?? []
                : battleMarkers + trustedBattleRoundMarkers
            let autoCandidates = indexed.filter { $0.canonicalText == "全部自動" }
            let trustedAutoTargets = autoCandidates.filter {
                $0.observation.confidence >= minimumMarkerConfidence
                    && isBattleAutoRegion($0.observation.rect)
            }
            let actionBlockers = battleActionConflictingMarkers(in: indexed)
            let actions: [AllowedGameAction]
            if autoCandidates.count == 1,
               trustedAutoTargets.count == 1,
               actionBlockers.isEmpty,
               let auto = trustedAutoTargets.first
            {
                actions = [
                    AllowedGameAction(
                        name: .enableAutoBattle,
                        target: target(.battleAuto, from: auto)
                    ),
                ]
            } else {
                actions = []
            }

            let retreatCandidates = indexed.filter { $0.canonicalText == "撤退" }
            let trustedRetreatTargets = retreatCandidates.filter {
                $0.observation.confidence >= minimumBattleRetreatTargetConfidence
                    && isBattleRetreatRegion($0.observation.rect)
            }
            let policyGatedActions: [PolicyGatedGameAction]
            if retreatCandidates.count == 1,
               trustedRetreatTargets.count == 1,
               actionBlockers.isEmpty,
               let retreat = trustedRetreatTargets.first
            {
                // A single frame can locate this control, but cannot establish a stalled defeat.
                // Only the temporal recovery coordinator may promote this candidate.
                policyGatedActions = [
                    PolicyGatedGameAction(
                        name: .openBattleRetreatConfirmation,
                        target: target(.battleRetreat, from: retreat),
                        requirement: .temporalDefeatRecovery
                    ),
                ]
            } else {
                policyGatedActions = []
            }

            return GameStateClassification(
                state: .battle,
                evidence: battleEvidenceMarkers.map {
                    evidence(.battleMarker, $0)
                },
                allowedActions: actions,
                policyGatedActions: policyGatedActions
            )
        }

        return GameStateClassification(state: .unknown, evidence: [], allowedActions: [])
    }

    private static func classifyMissionResult(
        indexed: [IndexedObservation],
        title: IndexedObservation,
        titleEvidenceKind: GameEvidenceKind,
        state: GameState,
        selectedState: GameState,
        permitMeasuredLootTopAdvanceFallback: Bool,
        repeatSelectedStampDetection: RepeatSelectedStampDetection?
    ) -> GameStateClassification {
        let repeatOptions = indexed.filter {
            missionRepeatTexts.contains($0.canonicalText)
                && $0.observation.confidence >= minimumMarkerConfidence
                && isMissionRepeatRegion($0.observation.rect)
        }
        let selectedMarkers = indexed.filter {
            isRepeatSelectedText($0.canonicalText)
                && $0.observation.confidence >= minimumActionGlyphConfidence
        }

        var baseEvidence = [evidence(titleEvidenceKind, title)]
        baseEvidence += repeatOptions.map { evidence(.missionRepeatOption, $0) }

        let successPageMarkers = indexed.filter {
            isMissionSuccessPageText($0.canonicalText)
        }

        if repeatOptions.count > 1 {
            return conflict(
                baseEvidence,
                detail: "More than one mission-repeat target candidate was observed"
            )
        }

        let hasMeasuredSelectedStamp = repeatSelectedStampDetection?.isPresent == true
        let usesOCRSelectedMarker = repeatSelectedStampDetection == nil && !selectedMarkers.isEmpty

        if repeatSelectedStampDetection?.isPresent == false, !selectedMarkers.isEmpty {
            return conflict(
                baseEvidence + selectedMarkers.map { evidence(.repeatSelectedMarker, $0) },
                detail: "OCR reported SELECTED but the fixed red-stamp region was empty"
            )
        }

        if hasMeasuredSelectedStamp || usesOCRSelectedMarker {
            guard let repeatOption = repeatOptions.first else {
                return conflict(
                    baseEvidence + selectedMarkers.map { evidence(.repeatSelectedMarker, $0) },
                    detail: "Selection evidence was observed without a unique mission-repeat option"
                )
            }

            let selectedMarker: IndexedObservation?
            if let repeatSelectedStampDetection, hasMeasuredSelectedStamp {
                selectedMarker = nil
                baseEvidence.append(GameStateEvidence(
                    kind: .repeatSelectedMarker,
                    observation: nil,
                    detail: RepeatSelectedStampDetector.evidenceSentinel
                        + "; redPixelRatio=\(repeatSelectedStampDetection.redPixelRatio)"
                ))
            } else {
                guard selectedMarkers.count == 1,
                      let marker = selectedMarkers.first,
                      isSelectedMarker(
                          marker.observation.rect,
                          beside: repeatOption.observation.rect
                      )
                else {
                    return conflict(
                        baseEvidence + selectedMarkers.map {
                            evidence(.repeatSelectedMarker, $0)
                        },
                        detail: "SELECTED was observed without a spatially related repeat option"
                    )
                }
                selectedMarker = marker
                baseEvidence.append(evidence(.repeatSelectedMarker, marker))
            }

            var successPageIdentity: GameEvidenceKind? = nil
            if state == .missionComplete {
                if successPageMarkers.count > 1 {
                    return conflict(
                        baseEvidence + successPageMarkers.map(successPageEvidence),
                        detail: "More than one successful mission result-page header was observed"
                    )
                }
                // The top continuation glyph is fixed across the EXP and loot pages. Never
                // authorize it without one exact content-page identity.
                guard let successPageMarker = successPageMarkers.first else {
                    return GameStateClassification(
                        state: selectedState,
                        evidence: baseEvidence,
                        allowedActions: []
                    )
                }
                guard successPageMarker.observation.confidence >= minimumMarkerConfidence,
                      isMissionSuccessPageMarkerRegion(successPageMarker.observation.rect)
                else {
                    return conflict(
                        baseEvidence + [successPageEvidence(successPageMarker)],
                        detail: "The successful mission result-page header was not trusted in its fixed region"
                    )
                }
                let pageEvidence = successPageEvidence(successPageMarker)
                baseEvidence.append(pageEvidence)
                successPageIdentity = pageEvidence.kind
            }
            let advanceMarkers = indexed.filter {
                guard $0.observation.confidence >= minimumActionGlyphConfidence else {
                    return false
                }
                if isMissionAdvanceText($0.canonicalText) {
                    return isMissionAdvanceRegion(
                        $0.observation.rect,
                        relativeTo: repeatOption.observation.rect
                    )
                }
                // On the latest measured loot page Vision read the visible top `>>` as `22`.
                // Accept only that exact substitution, only for the trusted loot-page identity,
                // and only inside its tightly measured top glyph box. Numeric loot rows and every
                // lower glyph remain outside this gate.
                return successPageIdentity == .missionLootPage
                    && $0.canonicalText == "22"
                    && isMeasuredLootTopAdvanceSubstitution(
                        $0.observation.rect,
                        relativeTo: repeatOption.observation.rect
                    )
            }
            baseEvidence += advanceMarkers.map { evidence(.missionCompleteAdvance, $0) }

            if advanceMarkers.count > 1 {
                return conflict(
                    baseEvidence,
                    detail: "More than one layout-valid mission-result advance target was observed"
                )
            }

            let usesMeasuredLootTopAdvanceFallback: Bool
            if let selectedMarker {
                usesMeasuredLootTopAdvanceFallback = advanceMarkers.isEmpty
                    && permitMeasuredLootTopAdvanceFallback
                    && successPageIdentity == .missionLootPage
                    && supportsMeasuredLootTopAdvanceFallback(
                        indexed: indexed,
                        title: title,
                        repeatOption: repeatOption,
                        selectedMarker: selectedMarker
                    )
            } else {
                usesMeasuredLootTopAdvanceFallback = false
            }
            if usesMeasuredLootTopAdvanceFallback {
                baseEvidence.append(GameStateEvidence(
                    kind: .missionCompleteAdvanceMeasuredFallback,
                    observation: nil,
                    detail: measuredLootTopAdvanceSentinel
                ))
            }

            let actions: [AllowedGameAction]
            if let advance = advanceMarkers.first {
                actions = [
                    AllowedGameAction(
                        name: .advanceMissionComplete,
                        target: target(.missionCompleteAdvance, from: advance)
                    ),
                ]
            } else if usesMeasuredLootTopAdvanceFallback {
                actions = [measuredLootTopAdvanceFallbackAction()]
            } else {
                actions = []
            }

            return GameStateClassification(
                state: selectedState,
                evidence: baseEvidence,
                allowedActions: actions
            )
        }

        let actions: [AllowedGameAction]
        if let repeatOption = repeatOptions.first {
            actions = [
                AllowedGameAction(
                    name: .selectMissionRepeat,
                    target: target(.missionRepeatOption, from: repeatOption)
                ),
            ]
        } else {
            actions = []
        }

        return GameStateClassification(
            state: state,
            evidence: baseEvidence,
            allowedActions: actions
        )
    }

    private static func conflict(
        _ evidence: [GameStateEvidence],
        detail: String
    ) -> GameStateClassification {
        GameStateClassification(
            state: .unknown,
            evidence: evidence + [
                GameStateEvidence(
                    kind: .conflictingStateMarkers,
                    observation: nil,
                    detail: detail
                ),
            ],
            allowedActions: []
        )
    }

    private static func lowConfidence(
        _ markers: [IndexedObservation],
        detail: String
    ) -> GameStateClassification {
        GameStateClassification(
            state: .unknown,
            evidence: markers.map {
                GameStateEvidence(
                    kind: .lowConfidenceMarker,
                    observation: $0.observation,
                    detail: detail
                )
            },
            allowedActions: []
        )
    }

    private static func evidence(
        _ kind: GameEvidenceKind,
        _ indexed: IndexedObservation
    ) -> GameStateEvidence {
        GameStateEvidence(
            kind: kind,
            observation: indexed.observation,
            detail: indexed.canonicalText
        )
    }

    private static func target(
        _ name: GameTargetName,
        from indexed: IndexedObservation
    ) -> NamedGameTarget {
        NamedGameTarget(
            name: name,
            sourceText: indexed.observation.text,
            rect: indexed.observation.rect,
            point: indexed.observation.rect.center
        )
    }

    private static func measuredLootTopAdvanceFallbackAction() -> AllowedGameAction {
        AllowedGameAction(
            name: .advanceMissionComplete,
            target: NamedGameTarget(
                name: .missionCompleteAdvance,
                sourceText: measuredLootTopAdvanceSentinel,
                rect: measuredLootTopAdvanceRect,
                point: measuredLootTopAdvanceRect.center
            )
        )
    }

    private static func closeBattlePromptAction(
        targeting close: IndexedObservation
    ) -> AllowedGameAction {
        AllowedGameAction(
            name: .closeBattlePrompt,
            target: target(.battlePromptClose, from: close)
        )
    }

    /// Strong context required before a title-free central `關閉` can be treated as a battle
    /// prompt. Candidate counts include low-confidence and misplaced observations so a second,
    /// ambiguous copy cannot disappear merely by falling below a threshold or outside the ROI.
    private struct BattlePromptBackgroundEvidence {
        let lootCandidates: [IndexedObservation]
        let lootMarkers: [IndexedObservation]
        let roundCandidates: [IndexedObservation]
        let roundMarkers: [IndexedObservation]
        let pauseCandidates: [IndexedObservation]
        let pauseMarkers: [IndexedObservation]
        let retreatCandidates: [IndexedObservation]
        let retreatMarkers: [IndexedObservation]

        var isComplete: Bool {
            lootCandidates.count == 1
                && lootMarkers.count == 1
                && roundCandidates.count == 1
                && roundMarkers.count == 1
                && pauseCandidates.count == 1
                && pauseMarkers.count == 1
                && retreatCandidates.count == 1
                && retreatMarkers.count == 1
        }

        var markers: [IndexedObservation] {
            lootMarkers + roundMarkers + pauseMarkers + retreatMarkers
        }

        var evidence: [GameStateEvidence] {
            markers.map { GameStateClassifier.evidence(.battleMarker, $0) }
        }
    }

    private static func battlePromptBackgroundEvidence(
        in indexed: [IndexedObservation]
    ) -> BattlePromptBackgroundEvidence {
        let lootCandidates = indexed.filter { $0.canonicalText.hasPrefix("戰利品") }
        let roundCandidates = indexed.filter { isBattleRoundText($0.canonicalText) }
        let pauseCandidates = indexed.filter { $0.canonicalText == "暫停" }
        let retreatCandidates = indexed.filter { $0.canonicalText == "撤退" }

        return BattlePromptBackgroundEvidence(
            lootCandidates: lootCandidates,
            lootMarkers: lootCandidates.filter {
                $0.observation.confidence >= minimumBattlePromptLootConfidence
                    && isBattleLootRegion($0.observation.rect)
            },
            roundCandidates: roundCandidates,
            roundMarkers: roundCandidates.filter {
                $0.observation.confidence >= minimumBattlePromptRoundConfidence
                    && isBattleRoundRegion($0.observation.rect)
            },
            pauseCandidates: pauseCandidates,
            pauseMarkers: pauseCandidates.filter {
                $0.observation.confidence >= minimumBattlePromptRightControlConfidence
                    && isBattleRightStackRegion($0.observation.rect)
            },
            retreatCandidates: retreatCandidates,
            retreatMarkers: retreatCandidates.filter {
                $0.observation.confidence >= minimumBattlePromptRightControlConfidence
                    && isBattleRightStackRegion($0.observation.rect)
            }
        )
    }

    private static func battlePromptConflictingMarkers(
        in indexed: [IndexedObservation],
        toleratingDefeatUnderlyingNoBelow close: IndexedObservation? = nil
    ) -> [IndexedObservation] {
        let decisionMarkers = indexed.filter {
            battlePromptUnderlyingDecisionTexts.contains($0.canonicalText)
        }
        let toleratedUnderlyingNo: IndexedObservation?
        if decisionMarkers.count == 1,
           let decision = decisionMarkers.first,
           decision.canonicalText == "否",
           let close,
           isDefeatUnderlyingNo(decision, immediatelyBelow: close)
        {
            toleratedUnderlyingNo = decision
        } else {
            toleratedUnderlyingNo = nil
        }

        return indexed.filter {
            if let toleratedUnderlyingNo,
               $0.observation == toleratedUnderlyingNo.observation
            {
                return false
            }
            return safetyCriticalMarkerTexts.contains($0.canonicalText)
                || isLootCollectionPrompt($0.canonicalText)
                || confirmationTitleTexts.contains($0.canonicalText)
                || isBattlePromptExclusiveConflictText($0.canonicalText)
        }
    }

    private static func isDefeatUnderlyingNo(
        _ decision: IndexedObservation,
        immediatelyBelow close: IndexedObservation
    ) -> Bool {
        let decisionCenter = decision.observation.rect.center
        let closeCenter = close.observation.rect.center
        let verticalSeparation = decisionCenter.y - closeCenter.y
        return (0.48...0.52).contains(decisionCenter.x)
            && (0.58...0.60).contains(decisionCenter.y)
            && abs(decisionCenter.x - closeCenter.x) <= 0.02
            && (0.025...0.055).contains(verticalSeparation)
    }

    private static func isBattlePromptExclusiveConflictText(_ text: String) -> Bool {
        battlePromptExclusiveConflictTexts.contains(text)
            || text.contains("出售")
            || text.contains("購買")
            || text.contains("護符")
    }

    private static func retreatConfirmationConflictingMarkers(
        in indexed: [IndexedObservation]
    ) -> [IndexedObservation] {
        indexed.filter {
            let text = $0.canonicalText
            return safetyCriticalMarkerTexts.contains(text)
                || confirmationTitleTexts.contains(text)
                || isLootCollectionPrompt(text)
                || adventurerRecruitTexts.contains(text)
                || adventurerLeaveTexts.contains(text)
                || isDefeatPromptMessageText(text)
                || isBattleEventDescriptionText(text)
                || isBattleEncounterTitleText(text)
                || isBattleEncounterDescriptionText(text)
                || text.contains("購買")
                || (text.contains("出售") && text != "撤退")
        }
    }

    private static func lootConfirmationConflictingMarkers(
        in indexed: [IndexedObservation]
    ) -> [IndexedObservation] {
        indexed.filter {
            let text = $0.canonicalText
            return defeatTexts.contains(text)
                || inventoryFullTexts.contains(text)
                || adventurerRecruitmentTitleTexts.contains(text)
                || adventurerRecruitmentPromptTexts.contains(text)
                || adventurerRecruitTexts.contains(text)
                || adventurerLeaveTexts.contains(text)
                || modalCloseTexts.contains(text)
                || isDefeatPromptMessageText(text)
                || isRetreatConfirmationPromptText(text)
                || isRetreatCharmLossWarningText(text)
                || isBattleEventDescriptionText(text)
                || isBattleEncounterTitleText(text)
                || isBattleEncounterDescriptionText(text)
                || battleControlTexts.contains(text)
                || isBattleRoundText(text)
                || text.contains("購買")
        }
    }

    private static func battleActionConflictingMarkers(
        in indexed: [IndexedObservation]
    ) -> [IndexedObservation] {
        indexed.filter {
            let text = $0.canonicalText
            return safetyCriticalMarkerTexts.contains(text)
                || confirmationTitleTexts.contains(text)
                || isLootCollectionPrompt(text)
                || adventurerRecruitTexts.contains(text)
                || adventurerLeaveTexts.contains(text)
                || modalCloseTexts.contains(text)
                || battlePromptUnderlyingDecisionTexts.contains(text)
                || isDefeatPromptMessageText(text)
                || isRetreatConfirmationPromptText(text)
                || isRetreatCharmLossWarningText(text)
                || isBattleEventDescriptionText(text)
                || isBattleEncounterTitleText(text)
                || text.contains("購買")
                || text.contains("出售")
        }
    }

    private static func isMissionTitleRegion(_ rect: NormalizedRect) -> Bool {
        rect.center.y <= 0.25
    }

    private static func isMissionRepeatRegion(_ rect: NormalizedRect) -> Bool {
        (0.08...0.45).contains(rect.center.y)
    }

    private static func isMissionSuccessPageMarkerRegion(_ rect: NormalizedRect) -> Bool {
        (0.70...1.0).contains(rect.center.x)
            && (0.12...0.20).contains(rect.center.y)
    }

    private static func isMissionSuccessPageText(_ text: String) -> Bool {
        missionExperiencePageTexts.contains(text) || missionLootPageTexts.contains(text)
    }

    private static func successPageEvidence(
        _ marker: IndexedObservation
    ) -> GameStateEvidence {
        evidence(
            missionExperiencePageTexts.contains(marker.canonicalText)
                ? .missionExperiencePage
                : .missionLootPage,
            marker
        )
    }

    private static func isSelectedMarker(
        _ selected: NormalizedRect,
        beside repeatOption: NormalizedRect
    ) -> Bool {
        abs(selected.center.y - repeatOption.center.y) <= 0.08
            && selected.center.x > repeatOption.center.x
    }

    private static func isMissionAdvanceRegion(
        _ rect: NormalizedRect,
        relativeTo repeatOption: NormalizedRect
    ) -> Bool {
        guard rect.center.x <= 0.15,
              rect.center.x < repeatOption.center.x
        else {
            return false
        }

        let verticalSeparation = repeatOption.center.y - rect.center.y
        return (0.015...0.10).contains(verticalSeparation)
    }

    private static func isMissionAdvanceText(_ text: String) -> Bool {
        // The measured `>2` substitution belongs to a lower decorative glyph and is excluded.
        missionAdvanceTexts.contains(text)
    }

    private static func isMeasuredLootTopAdvanceSubstitution(
        _ rect: NormalizedRect,
        relativeTo repeatOption: NormalizedRect
    ) -> Bool {
        let verticalSeparation = repeatOption.center.y - rect.center.y
        return rect.isValid
            && (0.015...0.040).contains(rect.x)
            && (0.030...0.060).contains(rect.width)
            && (0.006...0.016).contains(rect.height)
            && (0.190...0.220).contains(rect.center.y)
            && (0.030...0.060).contains(verticalSeparation)
            && rect.center.x < repeatOption.center.x
    }

    /// This fallback is intentionally much narrower than ordinary OCR-derived navigation. The
    /// caller must also have completed a separate top-ROI OCR retry that returned no observations;
    /// the opt-in flag is how that out-of-band fact reaches this pure classifier.
    private static func supportsMeasuredLootTopAdvanceFallback(
        indexed: [IndexedObservation],
        title: IndexedObservation,
        repeatOption: IndexedObservation,
        selectedMarker: IndexedObservation
    ) -> Bool {
        let titleCandidates = indexed.filter {
            missionCompleteTexts.contains($0.canonicalText)
        }
        let failureTitleCandidates = indexed.filter {
            missionFailedTexts.contains($0.canonicalText)
        }
        let repeatCandidates = indexed.filter {
            missionRepeatTexts.contains($0.canonicalText)
        }
        let selectedCandidates = indexed.filter {
            isRepeatSelectedText($0.canonicalText)
        }
        let successPageCandidates = indexed.filter {
            isMissionSuccessPageText($0.canonicalText)
        }

        guard titleCandidates.count == 1,
              titleCandidates.first?.observation == title.observation,
              failureTitleCandidates.isEmpty,
              repeatCandidates.count == 1,
              repeatCandidates.first?.observation == repeatOption.observation,
              selectedCandidates.count == 1,
              selectedCandidates.first?.observation == selectedMarker.observation,
              successPageCandidates.count == 1,
              let lootPage = successPageCandidates.first,
              missionLootPageTexts.contains(lootPage.canonicalText),
              title.observation.confidence >= 0.95,
              repeatOption.observation.confidence >= 0.95,
              selectedMarker.observation.confidence >= 0.50,
              lootPage.observation.confidence >= 0.95,
              isNearMeasuredRect(title.observation.rect, measuredLootMissionTitleRect),
              isNearMeasuredRect(lootPage.observation.rect, measuredLootPageHeaderRect),
              isNearMeasuredRect(repeatOption.observation.rect, measuredLootRepeatOptionRect),
              isNearMeasuredRect(selectedMarker.observation.rect, measuredLootSelectedMarkerRect),
              !indexed.contains(where: { isArrowLikeCandidateText($0.canonicalText) }),
              !indexed.contains(where: {
                  point($0.observation.rect.center, isInside: measuredLootTopOCRRegion)
              })
        else {
            return false
        }
        return true
    }

    private static func isArrowLikeCandidateText(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 4 else { return false }
        let glyphs: Set<Character> = [">", "»", "›", "≫", "2"]
        return text.allSatisfy(glyphs.contains)
    }

    private static func isNearMeasuredRect(
        _ rect: NormalizedRect,
        _ measured: NormalizedRect
    ) -> Bool {
        rect.isValid
            && abs(rect.x - measured.x) <= measuredLootLayoutTolerance
            && abs(rect.y - measured.y) <= measuredLootLayoutTolerance
            && abs(rect.width - measured.width) <= measuredLootLayoutTolerance
            && abs(rect.height - measured.height) <= measuredLootLayoutTolerance
    }

    private static func point(
        _ point: NormalizedPoint,
        isInside rect: NormalizedRect
    ) -> Bool {
        (rect.x...(rect.x + rect.width)).contains(point.x)
            && (rect.y...(rect.y + rect.height)).contains(point.y)
    }

    private static func isAdventurerRecruitRegion(_ rect: NormalizedRect) -> Bool {
        (0.45...0.55).contains(rect.center.x)
            && (0.61...0.66).contains(rect.center.y)
    }

    private static func isLootConfirmationTitleRegion(_ rect: NormalizedRect) -> Bool {
        (0.35...0.65).contains(rect.center.x)
            && (0.42...0.47).contains(rect.center.y)
    }

    private static func isLootConfirmationPromptRegion(_ rect: NormalizedRect) -> Bool {
        rect.center.x <= 0.60 && (0.46...0.51).contains(rect.center.y)
    }

    private static func isLootConfirmationYesRegion(_ rect: NormalizedRect) -> Bool {
        (0.45...0.55).contains(rect.center.x)
            && (0.51...0.55).contains(rect.center.y)
    }

    private static func isLootConfirmationNoRegion(_ rect: NormalizedRect) -> Bool {
        (0.45...0.55).contains(rect.center.x)
            && (0.55...0.60).contains(rect.center.y)
    }

    private static func isRetreatConfirmationPromptRegion(_ rect: NormalizedRect) -> Bool {
        rect.center.x <= 0.45 && (0.44...0.50).contains(rect.center.y)
    }

    private static func isRetreatCharmLossWarningRegion(_ rect: NormalizedRect) -> Bool {
        rect.center.x <= 0.60 && (0.48...0.54).contains(rect.center.y)
    }

    private static func isRetreatConfirmationYesRegion(_ rect: NormalizedRect) -> Bool {
        (0.45...0.55).contains(rect.center.x)
            && (0.53...0.57).contains(rect.center.y)
    }

    private static func isRetreatConfirmationNoRegion(_ rect: NormalizedRect) -> Bool {
        (0.45...0.55).contains(rect.center.x)
            && (0.57...0.62).contains(rect.center.y)
    }

    private static func isDefeatPromptMessageRegion(_ rect: NormalizedRect) -> Bool {
        (0.15...0.30).contains(rect.center.x)
            && (0.47...0.54).contains(rect.center.y)
    }

    private static func isDefeatPromptCloseRegion(_ rect: NormalizedRect) -> Bool {
        (0.45...0.55).contains(rect.center.x)
            && (0.52...0.59).contains(rect.center.y)
    }

    private static func isBattleEncounterTitleRegion(_ rect: NormalizedRect) -> Bool {
        (0.05...0.45).contains(rect.center.x)
            && (0.46...0.54).contains(rect.center.y)
    }

    private static func isBattleEncounterDescriptionRegion(_ rect: NormalizedRect) -> Bool {
        rect.center.x <= 0.85 && (0.50...0.55).contains(rect.center.y)
    }

    private static func isBattleEventDescriptionRegion(_ rect: NormalizedRect) -> Bool {
        rect.center.x <= 0.85 && (0.48...0.55).contains(rect.center.y)
    }

    private static func isBattleEncounterCloseRegion(_ rect: NormalizedRect) -> Bool {
        (0.45...0.55).contains(rect.center.x)
            && (0.53...0.61).contains(rect.center.y)
    }

    private static func isBattleEncounterAnchorPair(
        title: IndexedObservation,
        close: IndexedObservation
    ) -> Bool {
        let verticalSeparation = close.observation.rect.center.y
            - title.observation.rect.center.y
        return (0.05...0.16).contains(verticalSeparation)
    }

    private static func isBattleMarkerText(_ text: String) -> Bool {
        isBattleTitleText(text)
            || text.hasPrefix("戰利品")
            || battleControlTexts.contains(text)
    }

    private static func isBattleRoundText(_ text: String) -> Bool {
        let prefix = "ROUND"
        guard text.hasPrefix(prefix),
              let round = Int(text.dropFirst(prefix.count))
        else {
            return false
        }
        return round > 0
    }

    private static func isLootCollectionPrompt(_ text: String) -> Bool {
        lootCollectionPromptTexts.contains(text)
    }

    private static func isDefeatPromptMessageText(_ text: String) -> Bool {
        text.hasPrefix("隊伍已被擊敗")
    }

    private static func isRetreatConfirmationPromptText(_ text: String) -> Bool {
        text.contains("確認要撤退嗎")
    }

    private static func isRetreatCharmLossWarningText(_ text: String) -> Bool {
        text.contains("使用的護符將會丟失")
    }

    private static func isBattleEventDescriptionText(_ text: String) -> Bool {
        let ordinaryDefeatNarrative = text.contains("魔怪") && text.contains("倒下")
        // This exact post-boss narrative has no <<Battle N>> title. Require all four semantic
        // fragments in the same OCR observation so a generic mention of monsters or a clipped
        // battle header cannot authorize the central close button.
        let bossDefeatNarrative = text.contains("擊退了魔怪")
            && text.contains("首領")
            && text.contains("剩下的魔怪")
            && text.contains("四散逃走")
        return ordinaryDefeatNarrative || bossDefeatNarrative
    }

    private static func isBattleEncounterTitleText(_ text: String) -> Bool {
        let prefix = "<<BATTLE"
        guard text.hasPrefix(prefix), text.hasSuffix(">>") else {
            return false
        }
        let battleNumber = text.dropFirst(prefix.count).dropLast(2)
        return battleNumber.allSatisfy(\.isNumber)
            && Int(battleNumber).map { $0 > 0 } == true
    }

    private static func isBattleEncounterDescriptionText(_ text: String) -> Bool {
        text.contains("魔怪")
    }

    private static func isRepeatSelectedText(_ text: String) -> Bool {
        repeatSelectedTexts.contains(text)
    }

    private static func isBattleTitleText(_ text: String) -> Bool {
        text.contains("第") && text.contains("場戰鬥")
    }

    private static func isConfirmedBattle(markers: [IndexedObservation]) -> Bool {
        markers.contains { isBattleTitleText($0.canonicalText) }
            && markers.contains { $0.canonicalText.hasPrefix("戰利品") }
            && markers.contains { battleControlTexts.contains($0.canonicalText) }
    }

    private static func isConfirmedBattleFallback(
        markers: [IndexedObservation],
        roundMarkers: [IndexedObservation]
    ) -> Bool {
        markers.contains {
            $0.canonicalText.hasPrefix("戰利品")
                && isBattleLootRegion($0.observation.rect)
        }
            && roundMarkers.contains {
                isBattleRoundRegion($0.observation.rect)
            }
            && markers.contains {
                battleRightStackControlTexts.contains($0.canonicalText)
                    && isBattleRightStackRegion($0.observation.rect)
            }
            && markers.contains {
                battleBottomBarControlTexts.contains($0.canonicalText)
                    && isBattleBottomBarRegion($0.observation.rect)
            }
    }

    /// Some measured active-battle frames omit `Round N` and misread the decorative title. A
    /// second fallback therefore requires four independent, uniquely observed controls in their
    /// exact layout regions. Candidate counts include low-confidence and misplaced copies so an
    /// ambiguous duplicate can never be hidden by filtering.
    private static func isConfirmedBattleControlStackFallback(
        in indexed: [IndexedObservation]
    ) -> Bool {
        let lootCandidates = indexed.filter { $0.canonicalText.hasPrefix("戰利品") }
        let pauseCandidates = indexed.filter { $0.canonicalText == "暫停" }
        let retreatCandidates = indexed.filter { $0.canonicalText == "撤退" }
        let autoCandidates = indexed.filter { $0.canonicalText == "全部自動" }

        guard lootCandidates.count == 1,
              pauseCandidates.count == 1,
              retreatCandidates.count == 1,
              autoCandidates.count == 1,
              let loot = lootCandidates.first,
              let pause = pauseCandidates.first,
              let retreat = retreatCandidates.first,
              let auto = autoCandidates.first
        else {
            return false
        }

        return loot.observation.confidence >= minimumBattleControlStackLootConfidence
            && isBattleLootRegion(loot.observation.rect)
            && pause.observation.confidence >= minimumBattleControlStackPauseConfidence
            && isBattleRightStackRegion(pause.observation.rect)
            && retreat.observation.confidence >= minimumBattleRetreatTargetConfidence
            && isBattleRetreatRegion(retreat.observation.rect)
            && auto.observation.confidence >= minimumMarkerConfidence
            && isBattleAutoRegion(auto.observation.rect)
    }

    /// Active battle animation can consistently make Vision lose both the decorative title and
    /// the leading character of `戰利品`. In that case, require the two right-side controls and
    /// the two independent bottom-row controls to be unique, trusted, and in their measured grid.
    /// A measured 0.30 `撤退` is accepted only when a fifth, independently trusted `戰利品`
    /// header is also unique and correctly placed. This classification-only exception never
    /// relaxes the higher confidence required to expose the retreat control as a click target.
    /// Modal geometry is resolved separately before the background classification can be used.
    private static func confirmedBattleControlGridFallback(
        in indexed: [IndexedObservation]
    ) -> [IndexedObservation]? {
        let lootCandidates = indexed.filter { $0.canonicalText.hasPrefix("戰利品") }
        let pauseCandidates = indexed.filter { $0.canonicalText == "暫停" }
        let retreatCandidates = indexed.filter { $0.canonicalText == "撤退" }
        let skipCandidates = indexed.filter { $0.canonicalText == "跳過" }
        let autoCandidates = indexed.filter { $0.canonicalText == "全部自動" }

        guard pauseCandidates.count == 1,
              retreatCandidates.count == 1,
              skipCandidates.count == 1,
              autoCandidates.count == 1,
              let pause = pauseCandidates.first,
              let retreat = retreatCandidates.first,
              let skip = skipCandidates.first,
              let auto = autoCandidates.first
        else {
            return nil
        }

        let rightStackSeparation = retreat.observation.rect.center.y
            - pause.observation.rect.center.y
        let rightStackHorizontalOffset = abs(
            retreat.observation.rect.center.x - pause.observation.rect.center.x
        )
        let bottomRowOffset = abs(
            skip.observation.rect.center.y - auto.observation.rect.center.y
        )
        let bottomControlSeparation = auto.observation.rect.center.x
            - skip.observation.rect.center.x
        let trustedLootSupport: IndexedObservation? = {
            guard lootCandidates.count == 1,
                  let loot = lootCandidates.first,
                  loot.observation.confidence >= minimumMarkerConfidence,
                  isBattleLootRegion(loot.observation.rect)
            else {
                return nil
            }
            return loot
        }()
        let retreatMeetsActionTargetFloor = retreat.observation.confidence
            >= minimumBattleRetreatTargetConfidence
        let retreatMeetsCorroboratedClassificationFloor = retreat.observation.confidence
            >= minimumBattleControlGridRetreatConfidence
            && trustedLootSupport != nil
        guard pause.observation.confidence >= minimumBattleControlStackPauseConfidence,
              retreatMeetsActionTargetFloor || retreatMeetsCorroboratedClassificationFloor,
              skip.observation.confidence >= minimumMarkerConfidence,
              auto.observation.confidence >= minimumMarkerConfidence,
              isBattleRightStackRegion(pause.observation.rect),
              isBattleRetreatRegion(retreat.observation.rect),
              isBattleSkipRegion(skip.observation.rect),
              isBattleAutoRegion(auto.observation.rect),
              (0.015...0.060).contains(rightStackSeparation),
              rightStackHorizontalOffset <= 0.040,
              bottomRowOffset <= 0.030,
              (0.10...0.30).contains(bottomControlSeparation)
        else {
            return nil
        }

        if !retreatMeetsActionTargetFloor, let trustedLootSupport {
            return [trustedLootSupport, pause, retreat, skip, auto]
        }
        return [pause, retreat, skip, auto]
    }

    private static func isBattleLootRegion(_ rect: NormalizedRect) -> Bool {
        rect.center.x >= 0.65 && rect.center.y <= 0.20
    }

    private static func isBattleRoundRegion(_ rect: NormalizedRect) -> Bool {
        rect.center.x <= 0.35 && (0.55...0.75).contains(rect.center.y)
    }

    private static func isBattleRightStackRegion(_ rect: NormalizedRect) -> Bool {
        rect.center.x >= 0.70 && (0.55...0.75).contains(rect.center.y)
    }

    private static func isBattleBottomBarRegion(_ rect: NormalizedRect) -> Bool {
        (0.80...0.95).contains(rect.center.y)
    }

    private static func isBattleAutoRegion(_ rect: NormalizedRect) -> Bool {
        (0.15...0.50).contains(rect.center.x)
            && isBattleBottomBarRegion(rect)
    }

    private static func isBattleSkipRegion(_ rect: NormalizedRect) -> Bool {
        rect.center.x <= 0.20 && isBattleBottomBarRegion(rect)
    }

    private static func isBattleRetreatRegion(_ rect: NormalizedRect) -> Bool {
        isBattleRightStackRegion(rect)
    }

    private static func canonicalText(_ text: String) -> String {
        let compatible = text.precomposedStringWithCompatibilityMapping.uppercased()
        let scalars = compatible.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }
        return String(String.UnicodeScalarView(scalars))
            .replacingOccurrences(of: "！", with: "!")
            .replacingOccurrences(of: "＞", with: ">")
    }

    private struct IndexedObservation {
        let observation: OCRTextObservation
        let canonicalText: String

        init(observation: OCRTextObservation) {
            self.observation = observation
            canonicalText = GameStateClassifier.canonicalText(observation.text)
        }
    }

    // Calibrated from the stable 406 x 890 loot result captured on 2026-09-04. The window
    // identity and geometry are independently locked by the runtime. A six-thousandth normalized
    // tolerance is only about 2.4 horizontal or 5.3 vertical pixels at that resolution.
    private static let measuredLootLayoutTolerance = 0.006
    private static let measuredLootMissionTitleRect = NormalizedRect(
        x: 0.3891067804403232,
        y: 0.10550803805301134,
        width: 0.21193422589983257,
        height: 0.02269178776258829
    )
    private static let measuredLootPageHeaderRect = NormalizedRect(
        x: 0.7783251214285715,
        y: 0.14606741552808988,
        width: 0.1921182266009852,
        height: 0.020224719101123556
    )
    private static let measuredLootRepeatOptionRect = NormalizedRect(
        x: 0.024630543912737477,
        y: 0.23595505606741574,
        width: 0.2857142857142857,
        height: 0.020224719101123556
    )
    private static let measuredLootSelectedMarkerRect = NormalizedRect(
        x: 0.36982343572043463,
        y: 0.2232546383556393,
        width: 0.26002105938389963,
        height: 0.035046082400204126
    )
    /// Top-left coordinates corresponding to Vision's bottom-left ROI x=0...0.12,
    /// y=0.76...0.84. Center containment avoids treating the repeat row, whose box merely
    /// touches the ROI boundary, as a glyph observation.
    private static let measuredLootTopOCRRegion = NormalizedRect(
        x: 0,
        y: 0.16,
        width: 0.12,
        height: 0.08
    )

    private static let missionCompleteTexts: Set<String> = [
        "任務完成",
        "任務完成!",
    ]

    private static let missionFailedTexts: Set<String> = [
        "任務失敗",
        "任務失敗!",
    ]

    private static let missionRepeatTexts: Set<String> = [
        "重複進行此任務",
    ]

    private static let repeatSelectedTexts: Set<String> = [
        "SELECTED",
        "ISELECTED",
        // Vision emitted this exact substitution for the visible red SELECTED stamp in the
        // 2026-09-04 live result-page regression. The marker is still required to be unique,
        // trusted, and spatially related to the sole mission-repeat option before it can act.
        "SALECTED",
    ]

    private static let missionExperiencePageTexts: Set<String> = [
        "獲得經驗值",
    ]

    private static let missionLootPageTexts: Set<String> = [
        "獲得拾得物",
    ]

    private static let missionAdvanceTexts: Set<String> = [
        ">>",
        "»",
    ]

    private static let battleControlTexts: Set<String> = [
        "暫停",
        "撤退",
        "跳過",
        "全部自動",
        "技能>",
        "READY",
    ]

    private static let battleRightStackControlTexts: Set<String> = [
        "暫停",
        "撤退",
    ]

    private static let battleBottomBarControlTexts: Set<String> = [
        "跳過",
        "全部自動",
        "技能>",
        "READY",
    ]

    private static let defeatTexts: Set<String> = [
        "戰鬥失敗",
        "戰鬥失敗!",
        "全滅",
    ]

    private static let inventoryFullTexts: Set<String> = [
        "背包已滿",
        "物品欄已滿",
        "道具欄已滿",
        "持有物品已滿",
    ]

    private static let confirmationTitleTexts: Set<String> = [
        "您確定嗎?",
        "您確定嗎？",
    ]

    private static let lootCollectionPromptTexts: Set<String> = [
        "確定要獲取所有物品嗎?",
        "確定要獲取所有物品嗎？",
    ]

    private static let adventurerRecruitmentTitleTexts: Set<String> = [
        "遇到了新的冒險者",
    ]

    private static let adventurerRecruitmentPromptTexts: Set<String> = [
        "您想將這位冒險者迎入隊伍嗎?",
        "您想將這位冒險者迎入隊伍嗎？",
    ]

    private static let adventurerRecruitTexts: Set<String> = [
        "招募入隊",
    ]

    private static let adventurerLeaveTexts: Set<String> = [
        "離開",
    ]

    private static let minimumDefeatPromptMarkerConfidence = 0.30
    private static let minimumRetreatConfirmationMarkerConfidence = 0.30
    private static let minimumBattleEventDescriptionConfidence = 0.50
    private static let minimumBattleEventCloseConfidence = 0.30
    private static let minimumBattleEncounterTitleConfidence = 0.50
    private static let minimumBattleEncounterCloseConfidence = 0.30
    // These are local, measured floors for the stronger title-free prompt fingerprint. They do
    // not relax the confidence floor used to classify an ordinary active battle.
    private static let minimumBattlePromptLootConfidence = 0.30
    private static let minimumBattlePromptRoundConfidence = 0.50
    private static let minimumBattlePromptRightControlConfidence = 0.50
    // Vision measured the fixed battle-header loot counter at 0.30 in a normal live frame.
    // This lower floor is safe only inside the unique, four-control layout fingerprint above.
    private static let minimumBattleControlStackLootConfidence = 0.30
    // The right-side pause label repeatedly measures 0.50 during active battle animation. This
    // floor applies only when loot, retreat, and all-auto are also unique in their fixed regions.
    private static let minimumBattleControlStackPauseConfidence = 0.50
    // This measured floor is classification-only and is accepted solely inside the five-anchor
    // battle grid above. Retreat click targeting continues to require the independent 0.50 floor.
    private static let minimumBattleControlGridRetreatConfidence = 0.30
    private static let minimumBattleRoundConfidence = 0.50
    private static let minimumBattleRetreatTargetConfidence = 0.50
    private static let minimumDecisionControlConfidence = 0.60

    private static let modalCloseTexts: Set<String> = [
        "關閉",
    ]

    private static let battlePromptExclusiveConflictTexts: Set<String> = [
        "招募入隊",
        "離開",
        "是",
        "否",
    ]

    private static let battlePromptUnderlyingDecisionTexts: Set<String> = [
        "是",
        "否",
    ]

    private static let safetyCriticalMarkerTexts = missionCompleteTexts
        .union(missionFailedTexts)
        .union(missionRepeatTexts)
        .union(defeatTexts)
        .union(inventoryFullTexts)
        .union(adventurerRecruitmentTitleTexts)
        .union(adventurerRecruitmentPromptTexts)
}
