import Foundation

/// The identity of the exact iPhone Mirroring window selected when an automation session starts.
/// Both values are checked on every observation so a recycled window number in another process
/// cannot silently become an automation target.
public struct AutoLevelWindowIdentity: Codable, Equatable, Hashable, Sendable {
    public let processID: Int32
    public let windowID: UInt32

    public init(processID: Int32, windowID: UInt32) {
        self.processID = processID
        self.windowID = windowID
    }
}

/// Facts which are fixed for one user-started automation session.
public struct AutoLevelSessionMetadata: Codable, Equatable, Sendable {
    public let sessionID: String
    public let startedAt: TimeInterval
    public let windowIdentity: AutoLevelWindowIdentity

    public init(
        sessionID: String,
        startedAt: TimeInterval,
        windowIdentity: AutoLevelWindowIdentity
    ) {
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.windowIdentity = windowIdentity
    }
}

public enum AutoLevelAllAutoStatus: String, Codable, Equatable, Sendable {
    case active
    case inactive
    case unknown
}

public enum AutoLevelBattleStatus: String, Codable, Equatable, Sendable {
    case inProgress
    /// A separate temporal policy confirmed a frozen battle eligible for retreat, including
    /// the bounded startup recovery path. A single classified frame must never set this value.
    case stalledAfterDefeat
    case unknown
}

/// Per-frame runtime facts supplied by capture/UI detectors rather than inferred by this state
/// machine. `frameFingerprint` must identify the pixels used to produce the classification.
public struct AutoLevelRuntimeMetadata: Codable, Equatable, Sendable {
    public let observedAt: TimeInterval
    public let windowIdentity: AutoLevelWindowIdentity
    public let frameFingerprint: String
    public let battleSessionID: String?
    public let allAutoStatus: AutoLevelAllAutoStatus
    public let battleStatus: AutoLevelBattleStatus

    public init(
        observedAt: TimeInterval,
        windowIdentity: AutoLevelWindowIdentity,
        frameFingerprint: String,
        battleSessionID: String? = nil,
        allAutoStatus: AutoLevelAllAutoStatus = .unknown,
        battleStatus: AutoLevelBattleStatus = .inProgress
    ) {
        self.observedAt = observedAt
        self.windowIdentity = windowIdentity
        self.frameFingerprint = frameFingerprint
        self.battleSessionID = battleSessionID
        self.allAutoStatus = allAutoStatus
        self.battleStatus = battleStatus
    }
}

/// Named state actions remain explicit. `pressWideModalTopButton` is the separate user-authorized
/// geometry rule for the game's calibrated central modal skin: sole row for one button, upper row
/// for two buttons.
public enum AutoLevelActionIntent: String, Codable, Equatable, Hashable, Sendable {
    case closeBattlePrompt
    case pressWideModalTopButton
    case enableAllAuto
    case selectMissionRepeat
    case advanceMissionSuccess
    case advanceMissionFailure
    case confirmLootCollection
    case recruitAdventurer
    /// Retained for decoding older reports; the controller no longer requests this intent.
    case leaveAdventurer
    case requestRetreat
    /// Legacy internal name for confirming a requested retreat; no equipment prerequisite applies.
    case confirmRetreatWithoutTalisman
}

/// A neutral target lets a UI detector add buttons which the OCR classifier does not yet expose,
/// while preserving the classifier's named target and exact observed coordinates when it does.
public struct AutoLevelActionTarget: Codable, Equatable, Sendable {
    public let name: String
    public let sourceText: String
    public let rect: NormalizedRect
    public let point: NormalizedPoint

    public init(
        name: String,
        sourceText: String,
        rect: NormalizedRect,
        point: NormalizedPoint? = nil
    ) {
        self.name = name
        self.sourceText = sourceText
        self.rect = rect
        self.point = point ?? rect.center
    }

    public init(_ target: NamedGameTarget) {
        self.init(
            name: target.name.rawValue,
            sourceText: target.sourceText,
            rect: target.rect,
            point: target.point
        )
    }

    public var isValid: Bool {
        let center = rect.center
        return rect.isValid
            && point.x.isFinite
            && point.y.isFinite
            && (0...1).contains(point.x)
            && (0...1).contains(point.y)
            && abs(point.x - center.x) <= 0.000_001
            && abs(point.y - center.y) <= 0.000_001
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public struct AutoLevelActionCandidate: Codable, Equatable, Sendable {
    public let intent: AutoLevelActionIntent
    public let target: AutoLevelActionTarget

    public init(intent: AutoLevelActionIntent, target: AutoLevelActionTarget) {
        self.intent = intent
        self.target = target
    }
}

/// One immutable observation consumed by `AutoLevelController`.
public struct AutoLevelSnapshot: Codable, Equatable, Sendable {
    public let classification: GameStateClassification
    public let runtime: AutoLevelRuntimeMetadata
    public let actionCandidates: [AutoLevelActionCandidate]

    public init(
        classification: GameStateClassification,
        runtime: AutoLevelRuntimeMetadata,
        supplementalActionCandidates: [AutoLevelActionCandidate] = []
    ) {
        self.classification = classification
        self.runtime = runtime
        self.actionCandidates = Self.adapt(classification) + supplementalActionCandidates
    }

    private static func adapt(
        _ classification: GameStateClassification
    ) -> [AutoLevelActionCandidate] {
        let ordinary: [AutoLevelActionCandidate] = classification.allowedActions.compactMap {
            action -> AutoLevelActionCandidate? in
            let intent: AutoLevelActionIntent
            switch action.name {
            case .selectMissionRepeat:
                intent = .selectMissionRepeat
            case .advanceMissionComplete:
                switch classification.state {
                case .missionCompleteRepeatSelected:
                    intent = .advanceMissionSuccess
                case .missionFailedRepeatSelected:
                    intent = .advanceMissionFailure
                default:
                    return nil
                }
            case .recruitAdventurer:
                intent = .recruitAdventurer
            case .leaveAdventurer:
                intent = .leaveAdventurer
            case .closeBattlePrompt:
                intent = .closeBattlePrompt
            case .pressWideModalTopButton:
                intent = .pressWideModalTopButton
            case .enableAutoBattle:
                intent = .enableAllAuto
            case .confirmLootCollection:
                intent = .confirmLootCollection
            case .openBattleRetreatConfirmation:
                intent = .requestRetreat
            case .confirmNoTalismanRetreat:
                intent = .confirmRetreatWithoutTalisman
            }
            return AutoLevelActionCandidate(
                intent: intent,
                target: AutoLevelActionTarget(action.target)
            )
        }
        let gated: [AutoLevelActionCandidate] = classification.policyGatedActions.compactMap {
            action -> AutoLevelActionCandidate? in
            let intent: AutoLevelActionIntent
            switch (action.name, action.requirement) {
            case (.openBattleRetreatConfirmation, .temporalDefeatRecovery):
                intent = .requestRetreat
            case (.confirmNoTalismanRetreat, .explicitRetreatConfirmation):
                intent = .confirmRetreatWithoutTalisman
            default:
                return nil
            }
            return AutoLevelActionCandidate(
                intent: intent,
                target: AutoLevelActionTarget(action.target)
            )
        }
        return ordinary + gated
    }
}

public struct AutoLevelPolicy: Codable, Equatable, Sendable {
    public let actionCooldown: TimeInterval
    public let postActionTimeout: TimeInterval
    public let uncertainStateGraceDuration: TimeInterval
    public let uncertainStateGraceSnapshots: Int
    /// `nil` leaves this session without a cycle-count limit.
    public let maxCycles: Int?
    /// `nil` leaves this session without a runtime limit. Per-action timeouts still apply.
    public let maxRuntime: TimeInterval?
    /// `nil` leaves this session without an issued-action limit.
    public let maxActions: Int?

    public init(
        actionCooldown: TimeInterval = 0.8,
        postActionTimeout: TimeInterval = 8,
        uncertainStateGraceDuration: TimeInterval = 2,
        uncertainStateGraceSnapshots: Int = 2,
        maxCycles: Int? = nil,
        maxRuntime: TimeInterval? = nil,
        maxActions: Int? = nil
    ) {
        self.actionCooldown = actionCooldown
        self.postActionTimeout = postActionTimeout
        self.uncertainStateGraceDuration = uncertainStateGraceDuration
        self.uncertainStateGraceSnapshots = uncertainStateGraceSnapshots
        self.maxCycles = maxCycles
        self.maxRuntime = maxRuntime
        self.maxActions = maxActions
    }

    fileprivate var isValid: Bool {
        actionCooldown.isFinite
            && actionCooldown >= 0
            && postActionTimeout.isFinite
            && postActionTimeout > 0
            && uncertainStateGraceDuration.isFinite
            && uncertainStateGraceDuration >= 0
            && uncertainStateGraceSnapshots >= 0
            && (maxCycles.map { $0 > 0 } ?? true)
            && (maxRuntime.map { $0.isFinite && $0 > 0 } ?? true)
            && (maxActions.map { $0 > 0 } ?? true)
    }
}

public enum AutoLevelCycleOutcome: String, Codable, Equatable, Sendable {
    case success
    case failure
}

public struct AutoLevelCycleCompletion: Codable, Equatable, Sendable {
    public let count: Int
    public let outcome: AutoLevelCycleOutcome

    public init(count: Int, outcome: AutoLevelCycleOutcome) {
        self.count = count
        self.outcome = outcome
    }
}

public struct AutoLevelActionRequest: Codable, Equatable, Sendable {
    public let requestID: UInt64
    public let intent: AutoLevelActionIntent
    public let target: AutoLevelActionTarget
    public let observedState: GameState
    public let frameFingerprint: String
    public let completedCycles: Int
    /// Non-nil only for a posted repeat-toggle retry. The runner must establish the same
    /// explicit empty-stamp proof again in its fresh confirmation capture before posting.
    public let repeatSelectionRetryPage: MissionSuccessPageIdentity?

    public init(
        requestID: UInt64,
        intent: AutoLevelActionIntent,
        target: AutoLevelActionTarget,
        observedState: GameState,
        frameFingerprint: String,
        completedCycles: Int,
        repeatSelectionRetryPage: MissionSuccessPageIdentity? = nil
    ) {
        self.requestID = requestID
        self.intent = intent
        self.target = target
        self.observedState = observedState
        self.frameFingerprint = frameFingerprint
        self.completedCycles = completedCycles
        self.repeatSelectionRetryPage = repeatSelectionRetryPage
    }
}

public enum AutoLevelWaitReason: Codable, Equatable, Sendable {
    case freshObservationRequired
    case actionCooldown(remaining: TimeInterval)
    case awaitingFrameChange(intent: AutoLevelActionIntent)
    case awaitingStateChange(intent: AutoLevelActionIntent)
    case battleInProgress
    case allAutoAlreadyEnabled
    case battleRecognitionRecovery(remaining: TimeInterval)
    case transientState(kind: AutoLevelUncertainKind, observationCount: Int)
}

public enum AutoLevelUncertainKind: String, Codable, Equatable, Sendable {
    case unknown
    case classificationConflict
    case inventoryFull
    case unsupportedDefeat
    case missingAction
    case ambiguousAction
    case battleMetadataUnknown
}

public enum AutoLevelStopReason: Codable, Equatable, Sendable {
    case invalidPolicy
    case invalidSessionMetadata
    case invalidSnapshot(detail: String)
    case nonMonotonicTimestamp(previous: TimeInterval, current: TimeInterval)
    case windowIdentityChanged(
        expected: AutoLevelWindowIdentity,
        actual: AutoLevelWindowIdentity
    )
    case maximumRuntimeReached(limit: TimeInterval)
    case maximumCyclesReached(limit: Int)
    case maximumActionsReached(limit: Int)
    case inventoryFull
    case classificationConflict
    case uncertainStateExceededGrace(kind: AutoLevelUncertainKind)
    case actionDidNotAdvance(intent: AutoLevelActionIntent)
    case unexpectedTransition(
        intent: AutoLevelActionIntent,
        from: GameState,
        to: GameState
    )
    case retreatConfirmationWasNotRequested
    case recoveryTransactionInterrupted(state: GameState)
    case allAutoBecameInactive(battleSessionID: String?)
}

public enum AutoLevelDecision: Codable, Equatable, Sendable {
    case wait(AutoLevelWaitReason)
    case requestAction(AutoLevelActionRequest)
    case completedCycle(AutoLevelCycleCompletion)
    case stop(AutoLevelStopReason)
}

/// A deterministic policy engine. It performs no capture, OCR, timing, or clicking itself; the
/// caller owns those effects and feeds each new observation back into `consume`.
public struct AutoLevelController: Sendable {
    public let session: AutoLevelSessionMetadata
    public let policy: AutoLevelPolicy

    public private(set) var completedCycles = 0
    public private(set) var actionsIssued = 0

    private var nextRequestID: UInt64 = 1
    private var lastObservedAt: TimeInterval?
    private var lastActionAt: TimeInterval?
    private var resultEpisodeIsActive = false
    /// Once repeat selection was positively observed for the active result episode, a later OCR
    /// miss must never turn the same row back into a selectable action. That row is a toggle in
    /// the game, so retrying it would undo the already-confirmed selection. The latch resets only
    /// after the next battle-family state establishes a new result episode boundary.
    private var repeatSelectionObservedForActiveResult = false
    private var pendingAction: PendingAction?

    /// Capture recovery must not renew an already-posted action's acknowledgement budget.
    /// Ordinary fresh observations still go through `consume`, including its bounded result retry.
    public var pendingActionAcknowledgementDeadline: TimeInterval? {
        pendingAction?.postedAt.map { $0 + policy.postActionTimeout }
    }
    private var uncertainty: UncertaintyStreak?
    private var allAutoEnabledBattleSessions: Set<String> = []
    private var allAutoEnabledWithoutBattleID = false
    /// One-shot authorization for the OCR-only retreat fallback. Geometry-resolved two-row modals
    /// follow the separate user-authorized upper-row rule.
    private var recoveryConfirmationAuthorized = false
    private var terminalReason: AutoLevelStopReason?

    public init(session: AutoLevelSessionMetadata, policy: AutoLevelPolicy = AutoLevelPolicy()) {
        self.session = session
        self.policy = policy

        if !policy.isValid {
            terminalReason = .invalidPolicy
        } else if session.sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !session.startedAt.isFinite
            || session.startedAt < 0
            || session.windowIdentity.processID <= 0
            || session.windowIdentity.windowID == 0
        {
            terminalReason = .invalidSessionMetadata
        }
    }

    /// A delayed OCR result may still prove that an earlier posted action advanced on time.
    /// Callers set `allowNewActions` to false when those captured pixels are too old to authorize
    /// another input. State transitions and cycle accounting retain their actual capture time;
    /// issuing an initial action or a bounded result retry requires a fresh observation.
    public mutating func consume(
        _ snapshot: AutoLevelSnapshot,
        allowNewActions: Bool = true,
        battleRecognitionRecovery: BattleRecognitionRecoveryAssessment? = nil
    ) -> AutoLevelDecision {
        if let terminalReason {
            return .stop(terminalReason)
        }

        if let invalidDetail = invalidSnapshotDetail(snapshot) {
            return stop(.invalidSnapshot(detail: invalidDetail))
        }
        let now = snapshot.runtime.observedAt
        if let lastObservedAt, now < lastObservedAt {
            return stop(.nonMonotonicTimestamp(previous: lastObservedAt, current: now))
        }
        lastObservedAt = now

        guard snapshot.runtime.windowIdentity == session.windowIdentity else {
            return stop(.windowIdentityChanged(
                expected: session.windowIdentity,
                actual: snapshot.runtime.windowIdentity
            ))
        }
        if let maximumRuntime = policy.maxRuntime,
           now - session.startedAt >= maximumRuntime {
            return stop(.maximumRuntimeReached(limit: maximumRuntime))
        }
        if let maximumCycles = policy.maxCycles, completedCycles >= maximumCycles {
            return stop(.maximumCyclesReached(limit: maximumCycles))
        }
        if let maximumActions = policy.maxActions, actionsIssued >= maximumActions {
            return stop(.maximumActionsReached(limit: maximumActions))
        }

        if snapshot.classification.state == .inventoryFull {
            return stop(.inventoryFull)
        }
        if snapshot.classification.state == .unknown,
           snapshot.classification.evidence.contains(where: {
               $0.kind == .conflictingStateMarkers
           })
        {
            return stop(.classificationConflict)
        }

        if let decision = resolvePendingAction(with: snapshot, allowNewActions: allowNewActions) {
            return decision
        }

        if recoveryConfirmationAuthorized,
           snapshot.classification.state != .retreatConfirmation,
           snapshot.classification.state != .wideModalTwoButtons
        {
            return stop(.recoveryTransactionInterrupted(state: snapshot.classification.state))
        }

        if let recovery = battleRecognitionRecovery, recovery.matches(snapshot) {
            uncertainty = nil
            guard recovery.isReady else {
                return .wait(.battleRecognitionRecovery(
                    remaining: max(0, BattleRecognitionRecovery.minimumDuration - recovery.elapsedSeconds)
                ))
            }
            if let lastActionAt {
                let elapsed = now - lastActionAt
                if elapsed < policy.actionCooldown {
                    return .wait(.actionCooldown(remaining: policy.actionCooldown - elapsed))
                }
            }
            let rect = VisualBattleEvidence.measuredRetreatRect
            let target = AutoLevelActionTarget(
                name: GameTargetName.battleRetreat.rawValue,
                sourceText: VisualBattleEvidence.measuredRetreatSentinel,
                rect: rect,
                point: rect.center
            )
            guard target.isValid else {
                return observeUncertainty(.ambiguousAction, at: now)
            }
            return issueActionRequest(
                .requestRetreat, target: target, from: snapshot, at: now,
                allowNewActions: allowNewActions, postAttempt: 1
            )
        }

        if let uncertainKind = uncertainKind(for: snapshot.classification) {
            return observeUncertainty(uncertainKind, at: now)
        }

        let state = snapshot.classification.state
        let cycleOutcome = cycleOutcome(for: state)
        switch state {
        case .missionCompleteRepeatSelected, .missionFailedRepeatSelected:
            repeatSelectionObservedForActiveResult = true
        default:
            break
        }
        if let cycleOutcome {
            if !resultEpisodeIsActive {
                uncertainty = nil
                resultEpisodeIsActive = true
                completedCycles += 1
                return .completedCycle(AutoLevelCycleCompletion(
                    count: completedCycles,
                    outcome: cycleOutcome
                ))
            }
        } else if battleContinuationStates.contains(state) {
            // Loot and adventurer overlays can temporarily hide the same result page. Keep the
            // episode active across those overlays (and any conservative unknown frame), and
            // reset it only once the next battle family is actually observed.
            resultEpisodeIsActive = false
            repeatSelectionObservedForActiveResult = false
        }

        switch state {
        case .battleEncounterPrompt, .battleEventPrompt, .defeatPrompt:
            return request(
                .closeBattlePrompt,
                from: snapshot,
                at: now,
                allowNewActions: allowNewActions
            )

        case .wideModalOneButton:
            return request(.pressWideModalTopButton, from: snapshot, at: now, allowNewActions: allowNewActions)

        case .wideModalTwoButtons:
            let decision = request(.pressWideModalTopButton, from: snapshot, at: now, allowNewActions: allowNewActions)
            if recoveryConfirmationAuthorized,
               case .requestAction = decision
            {
                recoveryConfirmationAuthorized = false
            }
            return decision

        case .battle:
            return handleBattle(snapshot, at: now, allowNewActions: allowNewActions)

        case .missionComplete:
            // Once either result family positively showed SELECTED, no later OCR title jitter
            // in the same episode may turn the repeat toggle back into an action.
            guard !repeatSelectionObservedForActiveResult else {
                return observeUncertainty(.missingAction, at: now)
            }
            return request(.selectMissionRepeat, from: snapshot, at: now, allowNewActions: allowNewActions)

        case .missionCompleteRepeatSelected:
            guard MissionSuccessPageIdentity.resolve(in: snapshot.classification) != nil else {
                return observeUncertainty(.missingAction, at: now)
            }
            return request(.advanceMissionSuccess, from: snapshot, at: now, allowNewActions: allowNewActions)

        case .missionFailed:
            guard !repeatSelectionObservedForActiveResult else {
                return observeUncertainty(.missingAction, at: now)
            }
            return request(.selectMissionRepeat, from: snapshot, at: now, allowNewActions: allowNewActions)

        case .missionFailedRepeatSelected:
            return request(.advanceMissionFailure, from: snapshot, at: now, allowNewActions: allowNewActions)

        case .lootCollectionConfirmation:
            return request(.confirmLootCollection, from: snapshot, at: now, allowNewActions: allowNewActions)

        case .adventurerRecruitment:
            return request(.recruitAdventurer, from: snapshot, at: now, allowNewActions: allowNewActions)

        case .retreatConfirmation:
            guard recoveryConfirmationAuthorized else {
                return stop(.retreatConfirmationWasNotRequested)
            }
            return request(.confirmRetreatWithoutTalisman, from: snapshot, at: now, allowNewActions: allowNewActions)

        case .inventoryFull, .defeat, .unknown:
            // These states were handled by `uncertainKind(for:)` above.
            return observeUncertainty(.unknown, at: now)
        }
    }

    /// Discards an action which the caller has not posted because the confirmation capture
    /// already shows the exact state that selecting mission repeat would have produced. This is
    /// deliberately narrower than normal post-action transition handling: it accepts only the
    /// controller's current, unchanged request and the two equivalent forward result states.
    /// The issued-action count and cooldown remain consumed so a confirmation race cannot be
    /// used to bypass either safety limit.
    public mutating func cancelUnpostedActionAfterForwardResultTransition(
        _ request: AutoLevelActionRequest,
        observedState: GameState
    ) -> Bool {
        guard terminalReason == nil,
              let pendingAction,
              pendingAction.request == request,
              pendingAction.postedAt == nil,
              request.intent == .selectMissionRepeat
        else {
            return false
        }

        let isEquivalentForwardTransition =
            (pendingAction.originState == .missionComplete
                && observedState == .missionCompleteRepeatSelected)
            || (pendingAction.originState == .missionFailed
                && observedState == .missionFailedRepeatSelected)
        guard isEquivalentForwardTransition else {
            return false
        }

        self.pendingAction = nil
        uncertainty = nil
        return true
    }

    /// Discards a stale EXP-page advance when preflight already sees the loot page. Both pages
    /// share an arrow, so the caller must observe and authorize the new page before clicking.
    /// Cancellation preserves the original cycle count, issued-action count, and cooldown.
    public mutating func cancelUnpostedSuccessAdvanceAfterPageTransition(
        _ request: AutoLevelActionRequest,
        observedClassification: GameStateClassification
    ) -> Bool {
        guard terminalReason == nil,
              let pendingAction,
              pendingAction.request == request,
              pendingAction.postedAt == nil,
              request.intent == .advanceMissionSuccess,
              pendingAction.originState == .missionCompleteRepeatSelected,
              pendingAction.originMissionSuccessPage == .experience,
              observedClassification.state == .missionCompleteRepeatSelected,
              MissionSuccessPageIdentity.resolve(in: observedClassification) == .loot,
              !observedClassification.evidence.contains(where: {
                  $0.kind == .invalidObservation
                      || $0.kind == .lowConfidenceMarker
                      || $0.kind == .conflictingStateMarkers
              })
        else {
            return false
        }
        let actions = observedClassification.allowedActions.filter {
            $0.name == .advanceMissionComplete
        }
        guard actions.count == 1, let action = actions.first else { return false }
        let target = AutoLevelActionTarget(action.target)
        guard target.isValid,
              targetIsCompatible(
                  target,
                  with: .advanceMissionSuccess,
                  classification: observedClassification
              )
        else {
            return false
        }

        self.pendingAction = nil
        uncertainty = nil
        return true
    }

    /// Discards an action which has not yet been posted when the confirmation capture reveals a
    /// newly presented geometry-authorized modal. The stale coordinates are never reused; the
    /// caller must feed that capture back through `consume` so the modal receives a fresh request.
    /// The already-issued action count and cooldown remain consumed.
    public mutating func cancelUnpostedActionForObservedModal(
        _ request: AutoLevelActionRequest,
        observedState: GameState
    ) -> Bool {
        guard terminalReason == nil,
              let pendingAction,
              pendingAction.request == request,
              pendingAction.postedAt == nil,
              genericModalStates.contains(observedState)
        else {
            return false
        }

        self.pendingAction = nil
        uncertainty = nil
        return true
    }

    /// Discards an unposted retreat when the caller's final temporal check observes activity.
    /// The caller must resume observations before requesting another action. Keep the issued
    /// action count and cooldown consumed, but discard any recovery confirmation authorization.
    public mutating func cancelUnpostedRetreat(_ request: AutoLevelActionRequest) -> Bool {
        guard terminalReason == nil,
              let pendingAction,
              pendingAction.request == request,
              pendingAction.postedAt == nil,
              request.intent == .requestRetreat
        else {
            return false
        }

        self.pendingAction = nil
        uncertainty = nil
        recoveryConfirmationAuthorized = false
        return true
    }

    /// Discards an unposted action because foreground focus could not be borrowed or kept for
    /// it. The caller resumes observations; a later request is minted only from a newer snapshot
    /// after the cooldown, with the issued-action count consumed like every other cancellation.
    /// A discarded retreat loses its recovery confirmation, exactly like `cancelUnpostedRetreat`.
    /// A discarded retreat confirmation regains its one-shot authorization: issuing it consumed
    /// that authorization, yet no input was posted, so the same sheet may still be confirmed
    /// once from a newer frame. A posted action is never discarded here.
    public mutating func cancelUnpostedActionForForegroundDeferral(
        _ request: AutoLevelActionRequest
    ) -> Bool {
        guard terminalReason == nil,
              let pendingAction,
              pendingAction.request == request,
              pendingAction.postedAt == nil
        else {
            return false
        }

        self.pendingAction = nil
        uncertainty = nil
        switch request.intent {
        case .requestRetreat:
            recoveryConfirmationAuthorized = false
        case .confirmRetreatWithoutTalisman:
            recoveryConfirmationAuthorized = true
        default:
            break
        }
        return true
    }

    /// Starts the acknowledgement timeout only after the caller confirms that the authorized
    /// input was posted. The original request time continues to bound preflight authorization;
    /// this method never creates a new request or expands that input deadline.
    public mutating func markActionPosted(
        _ request: AutoLevelActionRequest,
        at postedAt: TimeInterval
    ) -> Bool {
        guard terminalReason == nil,
              postedAt.isFinite,
              postedAt >= 0,
              var pendingAction,
              pendingAction.request == request,
              pendingAction.postedAt == nil,
              postedAt >= pendingAction.issuedAt,
              postedAt - pendingAction.issuedAt < policy.postActionTimeout,
              policy.maxRuntime.map({ postedAt - session.startedAt < $0 }) ?? true
        else {
            return false
        }

        pendingAction.postedAt = postedAt
        self.pendingAction = pendingAction
        return true
    }

    private mutating func handleBattle(
        _ snapshot: AutoLevelSnapshot,
        at now: TimeInterval,
        allowNewActions: Bool
    ) -> AutoLevelDecision {
        switch snapshot.runtime.battleStatus {
        case .stalledAfterDefeat:
            return request(.requestRetreat, from: snapshot, at: now, allowNewActions: allowNewActions)

        case .unknown:
            return observeUncertainty(.battleMetadataUnknown, at: now)

        case .inProgress:
            break
        }

        let battleID = normalizedBattleSessionID(snapshot.runtime.battleSessionID)
        let wasEnabled = hasEnabledAllAuto(for: battleID)
        switch snapshot.runtime.allAutoStatus {
        case .active:
            markAllAutoEnabled(for: battleID)
            uncertainty = nil
            return .wait(.battleInProgress)

        case .inactive:
            // `全部自動` is a toggle, not an idempotent "enable" button. The live
            // runner relies on the game's configured default and must never try to repair an
            // inactive reading by clicking it.
            return stop(.allAutoBecameInactive(battleSessionID: battleID))

        case .unknown where wasEnabled:
            return .wait(.allAutoAlreadyEnabled)

        case .unknown:
            return observeUncertainty(.battleMetadataUnknown, at: now)
        }
    }

    private mutating func request(
        _ intent: AutoLevelActionIntent,
        from snapshot: AutoLevelSnapshot,
        at now: TimeInterval,
        allowNewActions: Bool,
        postAttempt: Int = 1
    ) -> AutoLevelDecision {
        let matches = snapshot.actionCandidates.filter { $0.intent == intent }
        guard matches.count == 1, let candidate = matches.first else {
            return observeUncertainty(
                matches.isEmpty ? .missingAction : .ambiguousAction,
                at: now
            )
        }
        guard candidate.target.isValid,
              targetIsCompatible(
                  candidate.target,
                  with: intent,
                  classification: snapshot.classification
              )
        else {
            return observeUncertainty(.ambiguousAction, at: now)
        }

        if let lastActionAt {
            let elapsed = now - lastActionAt
            if elapsed < policy.actionCooldown {
                uncertainty = nil
                return .wait(.actionCooldown(remaining: policy.actionCooldown - elapsed))
            }
        }

        return issueActionRequest(
            intent,
            target: candidate.target,
            from: snapshot,
            at: now,
            allowNewActions: allowNewActions,
            postAttempt: postAttempt
        )
    }

    private mutating func issueActionRequest(
        _ intent: AutoLevelActionIntent,
        target: AutoLevelActionTarget,
        from snapshot: AutoLevelSnapshot,
        at now: TimeInterval,
        allowNewActions: Bool,
        postAttempt: Int
    ) -> AutoLevelDecision {
        guard postAttempt > 0 else {
            return stop(.invalidSnapshot(detail: "the action post attempt must be positive"))
        }
        // Do not allocate an ID, spend the action/cooldown budget, replace a pending posted
        // retry, or consume one-shot confirmation authorization from an old captured frame.
        guard allowNewActions else {
            return .wait(.freshObservationRequired)
        }

        if intent == .enableAllAuto {
            markAllAutoEnabled(for: normalizedBattleSessionID(snapshot.runtime.battleSessionID))
        }

        let request = AutoLevelActionRequest(
            requestID: nextRequestID,
            intent: intent,
            target: target,
            observedState: snapshot.classification.state,
            frameFingerprint: snapshot.runtime.frameFingerprint,
            completedCycles: completedCycles,
            repeatSelectionRetryPage: intent == .selectMissionRepeat && postAttempt > 1
                ? MissionRepeatSelectionProof.page(in: snapshot.classification, matching: target)
                : nil
        )
        nextRequestID += 1
        actionsIssued += 1
        lastActionAt = now
        uncertainty = nil
        pendingAction = PendingAction(
            request: request,
            issuedAt: now,
            postedAt: nil,
            originState: snapshot.classification.state,
            originFrameFingerprint: snapshot.runtime.frameFingerprint,
            originMissionSuccessPage: MissionSuccessPageIdentity.resolve(in: snapshot.classification),
            originRepeatSelectionPage: intent == .selectMissionRepeat
                ? MissionRepeatSelectionProof.page(in: snapshot.classification, matching: target)
                : nil,
            postAttempt: postAttempt
        )
        if intent == .confirmRetreatWithoutTalisman {
            // Consume before the side effect. A failed click will time out instead of receiving a
            // second destructive authorization for the same sheet.
            recoveryConfirmationAuthorized = false
        }
        return .requestAction(request)
    }

    private mutating func resolvePendingAction(
        with snapshot: AutoLevelSnapshot,
        allowNewActions: Bool
    ) -> AutoLevelDecision? {
        guard let pendingAction else { return nil }
        let now = snapshot.runtime.observedAt
        let acknowledgementStartedAt = pendingAction.postedAt ?? pendingAction.issuedAt
        guard now >= acknowledgementStartedAt else {
            return stop(.invalidSnapshot(
                detail: "the observation timestamp preceded the posted action"
            ))
        }
        let elapsed = now - acknowledgementStartedAt
        if elapsed >= policy.postActionTimeout {
            // A posted tap's requested continuation acknowledges it whenever it first appears.
            // The same state after the deadline belongs to the bounded same-page retries below,
            // so a drifting dialog cannot bypass their attempt limit; an unposted request keeps
            // its posting deadline, and the retreat recovery transaction keeps its deadline guard.
            if pendingAction.postedAt != nil,
               pendingAction.request.intent != .requestRetreat,
               pendingAction.request.intent != .confirmRetreatWithoutTalisman,
               uncertainKind(for: snapshot.classification) == nil,
               acknowledgeAdvancedPendingAction(
                   pendingAction, with: snapshot, acceptingSameState: false
               )
            {
                return nil
            }
            if let retry = retryTimedOutMissionRepeatSelection(
                pendingAction,
                with: snapshot,
                at: now,
                allowNewActions: allowNewActions
            ) {
                return retry
            }
            if let retry = retryTimedOutMissionSuccessAdvance(
                pendingAction,
                with: snapshot,
                at: now,
                allowNewActions: allowNewActions
            ) {
                return retry
            }
            if let retry = retryTimedOutWideModalPress(
                pendingAction,
                with: snapshot,
                at: now,
                allowNewActions: allowNewActions
            ) {
                return retry
            }
            if let retry = retryTimedOutRetreatStep(
                pendingAction,
                with: snapshot,
                at: now,
                allowNewActions: allowNewActions
            ) {
                return retry
            }
            return stop(.actionDidNotAdvance(intent: pendingAction.request.intent))
        }

        if snapshot.runtime.frameFingerprint == pendingAction.originFrameFingerprint {
            return .wait(.awaitingFrameChange(intent: pendingAction.request.intent))
        }

        if let uncertainKind = uncertainKind(for: snapshot.classification) {
            return observeUncertainty(uncertainKind, at: now)
        }

        if pendingAction.request.intent == .enableAllAuto,
           snapshot.classification.state == .battle
        {
            self.pendingAction = nil
            uncertainty = nil
            return .wait(.allAutoAlreadyEnabled)
        }

        if acknowledgeAdvancedPendingAction(pendingAction, with: snapshot) {
            return nil
        }

        if snapshot.classification.state == pendingAction.originState {
            return .wait(.awaitingStateChange(intent: pendingAction.request.intent))
        }

        return stop(.unexpectedTransition(
            intent: pendingAction.request.intent,
            from: pendingAction.originState,
            to: snapshot.classification.state
        ))
    }

    /// The page an action was expected to produce acknowledges it whenever that page is first
    /// captured. Acknowledgement posts no input, so the acknowledgement timeout does not bound
    /// it: a continuation the mirror shows only after the deadline is still the requested
    /// outcome, and calling it a failed action would stop the run on the correct page.
    /// `acceptingSameState` also lets a changed frame in the origin state count where the
    /// intent allows it, such as one dialog replacing another; EXP -> loot is always accepted.
    private mutating func acknowledgeAdvancedPendingAction(
        _ pendingAction: PendingAction,
        with snapshot: AutoLevelSnapshot,
        acceptingSameState: Bool = true
    ) -> Bool {
        if pendingAction.request.intent == .advanceMissionSuccess,
           snapshot.classification.state == pendingAction.originState,
           let previousPage = pendingAction.originMissionSuccessPage,
           let nextPage = MissionSuccessPageIdentity.resolve(in: snapshot.classification),
           previousPage == .experience,
           nextPage == .loot,
           let nextTarget = uniqueMatchingCandidateTarget(
               for: .advanceMissionSuccess,
               in: snapshot
           ),
           nextTarget.isValid,
           targetIsCompatible(
               nextTarget,
               with: .advanceMissionSuccess,
               classification: snapshot.classification
           )
        {
            // An explicit EXP -> loot transition acknowledges the previous advance and permits
            // fresh authorization for loot's shared arrow. A fingerprint change alone does not
            // acknowledge it; timed-out same-page retries are separate.
            self.pendingAction = nil
            uncertainty = nil
            return true
        }

        guard acceptingSameState || snapshot.classification.state != pendingAction.originState,
              transitionIsAccepted(
                  after: pendingAction.request.intent,
                  from: pendingAction.originState,
                  to: snapshot.classification.state,
                  actionWasPosted: pendingAction.postedAt != nil
              )
        else {
            return false
        }
        if pendingAction.request.intent == .requestRetreat {
            recoveryConfirmationAuthorized = pendingAction.postedAt != nil
                && (snapshot.classification.state == .retreatConfirmation
                    || snapshot.classification.state == .wideModalTwoButtons)
        }
        self.pendingAction = nil
        uncertainty = nil
        return true
    }

    /// A repeat row is a toggle, so retry only with explicit empty-stamp evidence on the same
    /// independently identified page and exact target. Each retry gets fresh input validation;
    /// an observed selection is never eligible, even if later recognition loses its stamp.
    private mutating func retryTimedOutMissionRepeatSelection(
        _ pendingAction: PendingAction,
        with snapshot: AutoLevelSnapshot,
        at now: TimeInterval,
        allowNewActions: Bool
    ) -> AutoLevelDecision? {
        guard pendingAction.postedAt != nil,
              pendingAction.request.intent == .selectMissionRepeat,
              pendingAction.postAttempt < Self.maximumMissionRepeatSelectionPostAttempts,
              !repeatSelectionObservedForActiveResult,
              snapshot.classification.state == pendingAction.originState,
              let originPage = pendingAction.originRepeatSelectionPage,
              let currentTarget = uniqueMatchingCandidateTarget(for: .selectMissionRepeat, in: snapshot),
              currentTarget == pendingAction.request.target,
              MissionRepeatSelectionProof.page(in: snapshot.classification, matching: currentTarget)
                  == originPage
        else { return nil }

        if let lastActionAt, now - lastActionAt < policy.actionCooldown {
            return .wait(.actionCooldown(remaining: policy.actionCooldown - (now - lastActionAt)))
        }
        return issueActionRequest(
            .selectMissionRepeat,
            target: currentTarget,
            from: snapshot,
            at: now,
            allowNewActions: allowNewActions,
            postAttempt: pendingAction.postAttempt + 1
        )
    }

    /// The game's result-page arrow occasionally ignores a posted event even though the locked
    /// mirror remained frontmost. Re-post only while the same independently identified EXP or
    /// loot page and exact target remain visible. A different page sharing the arrow is not a
    /// retry, and toggles/confirmations never inherit this bounded replay allowance.
    private mutating func retryTimedOutMissionSuccessAdvance(
        _ pendingAction: PendingAction,
        with snapshot: AutoLevelSnapshot,
        at now: TimeInterval,
        allowNewActions: Bool
    ) -> AutoLevelDecision? {
        guard pendingAction.postedAt != nil,
              pendingAction.request.intent == .advanceMissionSuccess,
              pendingAction.originState == .missionCompleteRepeatSelected,
              let originPage = pendingAction.originMissionSuccessPage,
              pendingAction.postAttempt < Self.maximumMissionSuccessAdvancePostAttempts,
              snapshot.classification.state == .missionCompleteRepeatSelected,
              MissionSuccessPageIdentity.resolve(in: snapshot.classification) == originPage,
              !snapshot.classification.evidence.contains(where: {
                  $0.kind == .invalidObservation
                      || $0.kind == .lowConfidenceMarker
                      || $0.kind == .conflictingStateMarkers
              }),
              let currentTarget = uniqueMatchingCandidateTarget(
                  for: .advanceMissionSuccess,
                  in: snapshot
              ),
              currentTarget == pendingAction.request.target,
              MissionResultTopActionResolver.isMeasuredTopAdvanceTarget(
                  currentTarget, in: snapshot.classification
              ),
              currentTarget.isValid,
              targetIsCompatible(
                  currentTarget,
                  with: .advanceMissionSuccess,
                  classification: snapshot.classification
              )
        else {
            return nil
        }

        if let lastActionAt {
            let sinceLastAction = now - lastActionAt
            if sinceLastAction < policy.actionCooldown {
                return .wait(.actionCooldown(
                    remaining: policy.actionCooldown - sinceLastAction
                ))
            }
        }

        return issueActionRequest(
            .advanceMissionSuccess,
            target: currentTarget,
            from: snapshot,
            at: now,
            allowNewActions: allowNewActions,
            postAttempt: pendingAction.postAttempt + 1
        )
    }

    /// A dialog button press that the game never received leaves the same dialog on screen; a
    /// mouse movement by the user during the 60 ms between the posted mouse-down and mouse-up
    /// turns the tap into a drag. Dialog buttons have no side effects beyond dismissing or
    /// advancing the dialog, so re-post while the same dialog layout and exact button target
    /// remain the only candidate. Each retry gets fresh input validation; the bound stops a
    /// dialog the game refuses to dismiss.
    private mutating func retryTimedOutWideModalPress(
        _ pendingAction: PendingAction,
        with snapshot: AutoLevelSnapshot,
        at now: TimeInterval,
        allowNewActions: Bool
    ) -> AutoLevelDecision? {
        guard pendingAction.postedAt != nil,
              pendingAction.request.intent == .pressWideModalTopButton,
              pendingAction.postAttempt < Self.maximumWideModalPressPostAttempts,
              genericModalStates.contains(pendingAction.originState),
              snapshot.classification.state == pendingAction.originState,
              uncertainKind(for: snapshot.classification) == nil,
              let currentTarget = uniqueMatchingCandidateTarget(
                  for: .pressWideModalTopButton,
                  in: snapshot
              ),
              currentTarget == pendingAction.request.target,
              currentTarget.isValid
        else { return nil }

        if let lastActionAt, now - lastActionAt < policy.actionCooldown {
            return .wait(.actionCooldown(remaining: policy.actionCooldown - (now - lastActionAt)))
        }
        return issueActionRequest(
            .pressWideModalTopButton,
            target: currentTarget,
            from: snapshot,
            at: now,
            allowNewActions: allowNewActions,
            postAttempt: pendingAction.postAttempt + 1
        )
    }

    /// A retreat request or its confirmation press which the game never received leaves the
    /// same stalled battle or the same confirmation sheet on screen. Nothing advanced, so
    /// re-posting the same target repeats a decision already made rather than making a new
    /// one: the retreat still requires stalled-defeat metadata on the fresh observation, and
    /// the confirmation still requires its sheet. Each retry gets fresh input validation.
    private mutating func retryTimedOutRetreatStep(
        _ pendingAction: PendingAction,
        with snapshot: AutoLevelSnapshot,
        at now: TimeInterval,
        allowNewActions: Bool
    ) -> AutoLevelDecision? {
        let intent = pendingAction.request.intent
        guard pendingAction.postedAt != nil,
              intent == .requestRetreat || intent == .confirmRetreatWithoutTalisman,
              pendingAction.postAttempt < Self.maximumRetreatStepPostAttempts,
              snapshot.classification.state == pendingAction.originState,
              uncertainKind(for: snapshot.classification) == nil,
              let currentTarget = uniqueMatchingCandidateTarget(for: intent, in: snapshot),
              currentTarget == pendingAction.request.target,
              currentTarget.isValid
        else { return nil }
        switch intent {
        case .requestRetreat:
            guard snapshot.classification.state == .battle,
                  snapshot.runtime.battleStatus == .stalledAfterDefeat
            else { return nil }
        case .confirmRetreatWithoutTalisman:
            guard snapshot.classification.state == .retreatConfirmation else { return nil }
        default:
            return nil
        }

        if let lastActionAt, now - lastActionAt < policy.actionCooldown {
            return .wait(.actionCooldown(remaining: policy.actionCooldown - (now - lastActionAt)))
        }
        return issueActionRequest(
            intent,
            target: currentTarget,
            from: snapshot,
            at: now,
            allowNewActions: allowNewActions,
            postAttempt: pendingAction.postAttempt + 1
        )
    }

    private func transitionIsAccepted(
        after intent: AutoLevelActionIntent,
        from: GameState,
        to: GameState,
        actionWasPosted: Bool
    ) -> Bool {
        switch intent {
        case .selectMissionRepeat:
            return (from == .missionComplete && to == .missionCompleteRepeatSelected)
                || (from == .missionFailed && to == .missionFailedRepeatSelected)
                || ((from == .missionComplete || from == .missionFailed)
                    && genericModalStates.contains(to))

        case .advanceMissionSuccess:
            return from == .missionCompleteRepeatSelected
                && continuationStatesAfterSuccess.contains(to)

        case .advanceMissionFailure:
            return from == .missionFailedRepeatSelected
                && continuationStatesAfterFailure.contains(to)

        case .closeBattlePrompt:
            switch from {
            case .battleEncounterPrompt, .battleEventPrompt:
                return (to != from && battleContinuationStates.contains(to))
                    || isMissionResultState(to)
            case .defeatPrompt:
                return to == .missionFailed
            default:
                return false
            }

        case .pressWideModalTopButton:
            return genericModalStates.contains(from)
                && genericModalContinuationStates.contains(to)

        case .confirmLootCollection:
            return lootContinuationStates.contains(to)

        case .recruitAdventurer:
            return to == .missionCompleteRepeatSelected
                || battleContinuationStates.contains(to)

        case .leaveAdventurer:
            return battleContinuationStates.contains(to)

        case .requestRetreat:
            // The battle can finish while a posted retreat is being acknowledged, so the
            // first captured continuation may already be a success or failure result. An unposted
            // request still needs the caller's separate preflight cancellation path.
            return to == .retreatConfirmation
                || to == .defeatPrompt
                || genericModalStates.contains(to)
                || (actionWasPosted && (from == .battle || from == .unknown)
                    && isMissionResultState(to))

        case .confirmRetreatWithoutTalisman:
            return to == .defeatPrompt

        case .enableAllAuto:
            return battleContinuationStates.contains(to) || isMissionResultState(to)
        }
    }

    private func uncertainKind(
        for classification: GameStateClassification
    ) -> AutoLevelUncertainKind? {
        switch classification.state {
        case .unknown:
            return .unknown
        case .defeat:
            return .unsupportedDefeat
        case .inventoryFull:
            return nil
        default:
            return nil
        }
    }

    private mutating func observeUncertainty(
        _ kind: AutoLevelUncertainKind,
        at now: TimeInterval
    ) -> AutoLevelDecision {
        if uncertainty?.kind == kind {
            uncertainty?.observationCount += 1
        } else {
            uncertainty = UncertaintyStreak(
                kind: kind,
                firstSeenAt: now,
                observationCount: 1
            )
        }

        guard let uncertainty else {
            return stop(.uncertainStateExceededGrace(kind: kind))
        }
        let expiredByCount = uncertainty.observationCount > policy.uncertainStateGraceSnapshots
        let expiredByTime = now - uncertainty.firstSeenAt >= policy.uncertainStateGraceDuration
        if expiredByCount || expiredByTime {
            return stop(.uncertainStateExceededGrace(kind: kind))
        }
        return .wait(.transientState(
            kind: kind,
            observationCount: uncertainty.observationCount
        ))
    }

    private func invalidSnapshotDetail(_ snapshot: AutoLevelSnapshot) -> String? {
        let runtime = snapshot.runtime
        if !runtime.observedAt.isFinite || runtime.observedAt < session.startedAt {
            return "observedAt must be finite and no earlier than session start"
        }
        if runtime.frameFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "frameFingerprint must not be empty"
        }
        if let battleSessionID = runtime.battleSessionID,
           battleSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return "battleSessionID must be nil or non-empty"
        }
        return nil
    }

    private func cycleOutcome(for state: GameState) -> AutoLevelCycleOutcome? {
        switch state {
        case .missionComplete, .missionCompleteRepeatSelected:
            return .success
        case .missionFailed, .missionFailedRepeatSelected:
            return .failure
        default:
            return nil
        }
    }

    private func isMissionResultState(_ state: GameState) -> Bool {
        cycleOutcome(for: state) != nil
    }

    private var battleContinuationStates: Set<GameState> {
        [.battleEncounterPrompt, .battleEventPrompt, .battle, .defeatPrompt]
    }

    private var lootContinuationStates: Set<GameState> {
        Set<GameState>([
            .adventurerRecruitment,
            .battleEncounterPrompt,
            .battleEventPrompt,
            .battle,
        ]).union(genericModalStates)
    }

    private var continuationStatesAfterSuccess: Set<GameState> {
        Set<GameState>([
            .lootCollectionConfirmation,
            .adventurerRecruitment,
        ])
            .union(battleContinuationStates)
            .union(genericModalStates)
    }

    private var continuationStatesAfterFailure: Set<GameState> {
        battleContinuationStates.union(genericModalStates)
    }

    private var genericModalStates: Set<GameState> {
        [.wideModalOneButton, .wideModalTwoButtons]
    }

    private var genericModalContinuationStates: Set<GameState> {
        [
            .missionComplete,
            .missionCompleteRepeatSelected,
            .missionFailed,
            .missionFailedRepeatSelected,
            .lootCollectionConfirmation,
            .adventurerRecruitment,
            .defeatPrompt,
            .retreatConfirmation,
            .battleEventPrompt,
            .battleEncounterPrompt,
            .battle,
            .wideModalOneButton,
            .wideModalTwoButtons,
        ]
    }

    private func normalizedBattleSessionID(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func targetIsCompatible(
        _ target: AutoLevelActionTarget,
        with intent: AutoLevelActionIntent,
        classification: GameStateClassification
    ) -> Bool {
        let expectedName: GameTargetName
        switch intent {
        case .closeBattlePrompt:
            expectedName = .battlePromptClose
        case .pressWideModalTopButton:
            expectedName = .wideModalTopButton
        case .enableAllAuto:
            expectedName = .battleAuto
        case .selectMissionRepeat:
            expectedName = .missionRepeatOption
        case .advanceMissionSuccess, .advanceMissionFailure:
            expectedName = .missionCompleteAdvance
        case .confirmLootCollection:
            expectedName = .lootConfirmationYes
        case .recruitAdventurer:
            expectedName = .adventurerRecruit
        case .leaveAdventurer:
            expectedName = .adventurerLeave
        case .requestRetreat:
            expectedName = .battleRetreat
        case .confirmRetreatWithoutTalisman:
            expectedName = .retreatConfirmationYes
        }
        guard target.name == expectedName.rawValue else { return false }
        switch intent {
        case .requestRetreat:
            if target.sourceText == VisualBattleEvidence.measuredRetreatSentinel
                || classification.evidence.contains(where: { $0.battleVisualMatch != nil }) {
                return VisualBattleEvidence.hasTrustedRetreat(in: classification)
                    && target.sourceText == VisualBattleEvidence.measuredRetreatSentinel
                    && target.rect == VisualBattleEvidence.measuredRetreatRect
                    && target.point == VisualBattleEvidence.measuredRetreatRect.center
            }
            return true
        case .advanceMissionSuccess:
            guard classifierAllowedMissionAdvance(
                matching: target,
                in: classification
            ), let page = MissionSuccessPageIdentity.resolve(in: classification) else {
                return false
            }
            return isTopMissionAdvanceTarget(
                target,
                classification: classification,
                permitsMeasuredLootDoubleTwo: page == .loot
                    && hasMeasuredLootDoubleTwoEvidence(
                        matching: target,
                        in: classification
                    ),
                permitsMeasuredLootTopFallback: page == .loot
                    && hasMeasuredLootTopFallbackEvidence(
                        matching: target,
                        in: classification
                    )
            )
        case .advanceMissionFailure:
            guard classifierAllowedMissionAdvance(
                matching: target,
                in: classification
            ) else {
                return false
            }
            return isTopMissionAdvanceTarget(
                target,
                classification: classification,
                permitsMeasuredLootDoubleTwo: false,
                permitsMeasuredLootTopFallback: false
            )
        default:
            return true
        }
    }

    private func isTopMissionAdvanceTarget(
        _ target: AutoLevelActionTarget,
        classification: GameStateClassification,
        permitsMeasuredLootDoubleTwo: Bool,
        permitsMeasuredLootTopFallback: Bool
    ) -> Bool {
        let canonicalSource = target.sourceText
            .precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: "＞", with: ">")
            .replacingOccurrences(of: " ", with: "")
        guard let repeatRect = VisualResultEvidence.trustedRepeatRect(in: classification) else {
            return false
        }
        let verticalSeparation = repeatRect.center.y - target.point.y
        let isMeasuredResultTop = hasMeasuredResultTopEvidence(matching: target, in: classification)
        if isMeasuredResultTop {
            return true
        }
        let isOrdinaryTopArrow = (canonicalSource == ">>" || canonicalSource == "»")
            && target.point.x <= 0.15
            && target.point.x < repeatRect.center.x
            && (0.015...0.10).contains(verticalSeparation)
        if isOrdinaryTopArrow {
            return true
        }
        let isMeasuredDoubleTwo = permitsMeasuredLootDoubleTwo
            && canonicalSource == "22"
            && (0.015...0.040).contains(target.rect.x)
            && (0.030...0.060).contains(target.rect.width)
            && (0.006...0.016).contains(target.rect.height)
            && (0.190...0.220).contains(target.point.y)
            && (0.030...0.060).contains(verticalSeparation)
            && target.point.x < repeatRect.center.x
        if isMeasuredDoubleTwo {
            return true
        }
        return permitsMeasuredLootTopFallback
            && canonicalSource == GameStateClassifier.measuredLootTopAdvanceSentinel
            && target.rect == GameStateClassifier.measuredLootTopAdvanceRect
            && target.point == GameStateClassifier.measuredLootTopAdvanceRect.center
    }

    private func hasMeasuredResultTopEvidence(
        matching target: AutoLevelActionTarget,
        in classification: GameStateClassification
    ) -> Bool {
        guard MissionResultTopActionResolver.isMeasuredTopAdvanceTarget(target, in: classification)
        else {
            return false
        }
        let matches = classification.evidence.filter {
            $0.kind == .missionResultAdvanceMeasuredFallback
                && $0.observation == nil
                && $0.detail == MissionResultTopActionResolver.measuredTopAdvanceSentinel
        }
        return matches.count == 1
    }

    private func hasMeasuredLootDoubleTwoEvidence(
        matching target: AutoLevelActionTarget,
        in classification: GameStateClassification
    ) -> Bool {
        let matches = classification.evidence.compactMap { item -> OCRTextObservation? in
            guard item.kind == .missionCompleteAdvance,
                  let observation = item.observation,
                  compactResultText(observation.text) == "22",
                  observation.confidence >= GameStateClassifier.minimumActionGlyphConfidence,
                  observation.rect == target.rect
            else {
                return nil
            }
            return observation
        }
        return matches.count == 1
    }

    private func hasMeasuredLootTopFallbackEvidence(
        matching target: AutoLevelActionTarget,
        in classification: GameStateClassification
    ) -> Bool {
        guard target.sourceText == GameStateClassifier.measuredLootTopAdvanceSentinel,
              target.rect == GameStateClassifier.measuredLootTopAdvanceRect,
              target.point == GameStateClassifier.measuredLootTopAdvanceRect.center
        else {
            return false
        }
        let matches = classification.evidence.filter {
            $0.kind == .missionCompleteAdvanceMeasuredFallback
                && $0.observation == nil
                && $0.detail == GameStateClassifier.measuredLootTopAdvanceSentinel
        }
        return matches.count == 1
    }

    private func classifierAllowedMissionAdvance(
        matching target: AutoLevelActionTarget,
        in classification: GameStateClassification
    ) -> Bool {
        let matches = classification.allowedActions.filter { action in
            action.name == .advanceMissionComplete
                && action.target.name.rawValue == target.name
                && action.target.sourceText == target.sourceText
                && action.target.rect == target.rect
                && action.target.point == target.point
        }
        return matches.count == 1
    }

    private func uniqueMatchingCandidateTarget(
        for intent: AutoLevelActionIntent,
        in snapshot: AutoLevelSnapshot
    ) -> AutoLevelActionTarget? {
        let matches = snapshot.actionCandidates.filter { $0.intent == intent }
        guard matches.count == 1 else { return nil }
        return matches[0].target
    }

    private func hasEnabledAllAuto(for battleSessionID: String?) -> Bool {
        if let battleSessionID {
            return allAutoEnabledBattleSessions.contains(battleSessionID)
        }
        return allAutoEnabledWithoutBattleID
    }

    private mutating func markAllAutoEnabled(for battleSessionID: String?) {
        if let battleSessionID {
            allAutoEnabledBattleSessions.insert(battleSessionID)
        } else {
            allAutoEnabledWithoutBattleID = true
        }
    }

    private mutating func stop(_ reason: AutoLevelStopReason) -> AutoLevelDecision {
        terminalReason = reason
        return .stop(reason)
    }

    private struct PendingAction: Sendable {
        let request: AutoLevelActionRequest
        let issuedAt: TimeInterval
        var postedAt: TimeInterval?
        let originState: GameState
        let originFrameFingerprint: String
        let originMissionSuccessPage: MissionSuccessPageIdentity?
        let originRepeatSelectionPage: MissionSuccessPageIdentity?
        let postAttempt: Int
    }

    private static let maximumMissionSuccessAdvancePostAttempts = 3
    private static let maximumMissionRepeatSelectionPostAttempts = 3
    private static let maximumWideModalPressPostAttempts = 3
    private static let maximumRetreatStepPostAttempts = 3

    private func compactResultText(_ text: String) -> String {
        let compatible = text.precomposedStringWithCompatibilityMapping
        let scalars = compatible.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private struct UncertaintyStreak: Sendable {
        let kind: AutoLevelUncertainKind
        let firstSeenAt: TimeInterval
        var observationCount: Int
    }
}
