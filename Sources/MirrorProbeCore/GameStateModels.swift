import Foundation

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
    /// Pixel proof that the calibrated selection-stamp region is empty apart from measured noise.
    case repeatUnselectedMarker
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
    /// The battle footer could not be recognized. Any retained glyph matches are diagnostic
    /// until a separate, same-battle recognition-timeout policy authorizes recovery.
    case battleFooterOcclusion
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
    public let visualMatch: VisualResultMatch?
    public let battleVisualMatch: VisualBattleMatch?

    public init(
        kind: GameEvidenceKind,
        observation: OCRTextObservation?,
        detail: String,
        visualMatch: VisualResultMatch? = nil,
        battleVisualMatch: VisualBattleMatch? = nil
    ) {
        self.kind = kind
        self.observation = observation
        self.detail = detail
        self.visualMatch = visualMatch
        self.battleVisualMatch = battleVisualMatch
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
