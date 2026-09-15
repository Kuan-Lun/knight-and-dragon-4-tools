import Foundation

/// Positive evidence that a repeat toggle can safely be retried after an ignored click.
/// Missing SELECTED OCR alone is insufficient: the calibrated stamp region must be empty,
/// and the title, content page, repeat row and classifier action must all agree.
public enum MissionRepeatSelectionProof {
    public static func page(
        in classification: GameStateClassification,
        matching target: AutoLevelActionTarget
    ) -> MissionSuccessPageIdentity? {
        let titleKind: GameEvidenceKind
        switch classification.state {
        case .missionComplete:
            titleKind = .missionCompleteTitle
        case .missionFailed:
            titleKind = .missionFailedTitle
        default:
            return nil
        }
        guard classification.policyGatedActions.isEmpty,
              !classification.evidence.contains(where: {
                  $0.kind == .repeatSelectedMarker || $0.kind == .invalidObservation
                      || $0.kind == .lowConfidenceMarker || $0.kind == .conflictingStateMarkers
              }),
              let page = MissionSuccessPageIdentity.resolve(in: classification)
        else { return nil }

        let absent = classification.evidence.filter { $0.kind == .repeatUnselectedMarker }
        let repeats = classification.evidence.filter { $0.kind == .missionRepeatOption }
        guard absent.count == 1,
              absent[0].observation == nil,
              absent[0].visualMatch == nil,
              absent[0].detail == RepeatSelectedStampDetector.absentEvidenceSentinel,
              VisualResultEvidence.trustedTitle(in: classification, expectedKind: titleKind),
              repeats.count == 1,
              let rowRect = VisualResultEvidence.trustedRepeatRect(in: classification),
              (0.225...0.255).contains(rowRect.center.y),
              rowRect.x + rowRect.width <= RepeatSelectedStampDetector.measuredRegion.x,
              rowRect.width >= 0.20, rowRect.height <= 0.05,
              target.isValid,
              target.name == GameTargetName.missionRepeatOption.rawValue,
              target.sourceText == (repeats[0].visualMatch == nil
                  ? repeats[0].observation?.text : VisualResultEvidence.measuredRepeatOptionSentinel),
              target.rect == rowRect, target.point == rowRect.center,
              classification.allowedActions.count == 1,
              let action = classification.allowedActions.first,
              action.name == .selectMissionRepeat,
              AutoLevelActionTarget(action.target) == target
        else { return nil }
        return page
    }
}
