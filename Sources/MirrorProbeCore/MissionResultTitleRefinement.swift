import Foundation

/// Re-reads one intact but weak result title without weakening the ordinary classifier's floor.
/// The caller supplies focused OCR from the same image and retains its original full-frame OCR.
public enum MissionResultTitleRefinement {
    /// The measured title OCR region, in full-frame coordinates with a top-left origin.
    public static let region = NormalizedRect(x: 0.25, y: 0.07, width: 0.50, height: 0.08)

    public static func needsRefinement(
        observations: [OCRTextObservation],
        classification: GameStateClassification,
        repeatSelectedStampDetection: RepeatSelectedStampDetection?
    ) -> Bool {
        candidateIndex(
            observations: observations,
            classification: classification,
            repeatSelectedStampDetection: repeatSelectedStampDetection
        ) != nil
    }

    public static func refinedClassification(
        observations: [OCRTextObservation],
        classification: GameStateClassification,
        repeatSelectedStampDetection: RepeatSelectedStampDetection?,
        focusedObservations: [OCRTextObservation]
    ) -> GameStateClassification? {
        guard let index = candidateIndex(
            observations: observations,
            classification: classification,
            repeatSelectedStampDetection: repeatSelectedStampDetection
        ),
            focusedObservations.count == 1,
            let focused = focusedObservations.first,
            isValid(focused),
            canonicalText(focused.text) == canonicalText(observations[index].text),
            focused.confidence >= GameStateClassifier.minimumMarkerConfidence,
            isMeasuredTitleRegion(focused.rect)
        else {
            return nil
        }

        let original = observations[index]
        guard abs(focused.rect.center.x - original.rect.center.x) <= 0.02,
              abs(focused.rect.center.y - original.rect.center.y) <= 0.02,
              abs(focused.rect.width - original.rect.width) <= 0.04,
              abs(focused.rect.height - original.rect.height) <= 0.04
        else {
            return nil
        }

        // Only this actual high-confidence observation replaces its same-image counterpart.
        // Every other original observation survives, including safety conflicts which the weak
        // title could have masked in the first classifier pass.
        var refinedObservations = observations
        refinedObservations[index] = focused
        let reclassified = GameStateClassifier.classify(
            observations: refinedObservations,
            repeatSelectedStampDetection: repeatSelectedStampDetection
        )
        guard reclassified.state == .missionCompleteRepeatSelected,
              MissionSuccessPageIdentity.resolve(in: reclassified) != nil
        else {
            return nil
        }
        let resolved = MissionResultTopActionResolver.resolve(classification: reclassified)
        guard resolved.allowedActions.count == 1,
              resolved.allowedActions.first?.name == .advanceMissionComplete,
              resolved.policyGatedActions.isEmpty
        else {
            return nil
        }

        return GameStateClassification(
            state: resolved.state,
            evidence: resolved.evidence.map { evidence in
                guard evidence.kind == .missionCompleteTitle else { return evidence }
                return GameStateEvidence(
                    kind: evidence.kind,
                    observation: evidence.observation,
                    detail: evidence.detail + "; source=focusedResultTitle"
                        + "; originalConfidence=\(original.confidence)"
                        + "; regionOfInterest=(x=\(region.x), y=\(region.y),"
                        + " width=\(region.width), height=\(region.height))"
                )
            },
            allowedActions: resolved.allowedActions,
            policyGatedActions: resolved.policyGatedActions
        )
    }

    private static func candidateIndex(
        observations: [OCRTextObservation],
        classification: GameStateClassification,
        repeatSelectedStampDetection: RepeatSelectedStampDetection?
    ) -> Int? {
        guard classification.state == .unknown,
              classification.allowedActions.isEmpty,
              classification.policyGatedActions.isEmpty,
              classification.evidence.count == 1,
              let evidence = classification.evidence.first,
              evidence.kind == .lowConfidenceMarker,
              repeatSelectedStampDetection?.isPresent == true,
              observations.allSatisfy(isValid),
              !observations.contains(where: {
                  let text = canonicalText($0.text)
                  return text == "是" || text == "否"
                      || text == "購買" || text == "出售"
              })
        else {
            return nil
        }

        // Count weak and misplaced copies too: they must not disappear from uniqueness checks.
        let titles = observations.indices.filter {
            let text = canonicalText(observations[$0].text)
            return text == "任務完成" || text == "任務完成!"
        }
        guard titles.count == 1, let index = titles.first else { return nil }
        let title = observations[index]
        guard canonicalText(title.text) == "任務完成!",
              title.confidence >= 0.50,
              title.confidence < GameStateClassifier.minimumMarkerConfidence,
              isMeasuredTitleRegion(title.rect),
              evidence.observation == title
        else {
            return nil
        }

        let repeats = observations.filter { canonicalText($0.text) == "重複進行此任務" }
        guard repeats.count == 1,
              let repeatOption = repeats.first,
              repeatOption.confidence >= GameStateClassifier.minimumMarkerConfidence,
              (0.10...0.25).contains(repeatOption.rect.center.x),
              (0.22...0.27).contains(repeatOption.rect.center.y),
              contains(
                  repeatOption.rect,
                  in: NormalizedRect(x: 0, y: 0.21, width: 0.35, height: 0.07)
              )
        else {
            return nil
        }

        let pages = observations.filter {
            let text = canonicalText($0.text)
            return text == "獲得經驗值" || text == "獲得拾得物"
        }
        guard pages.count == 1,
              let page = pages.first,
              page.confidence >= GameStateClassifier.minimumMarkerConfidence,
              (0.70...1).contains(page.rect.center.x),
              (0.12...0.20).contains(page.rect.center.y)
        else {
            return nil
        }
        return index
    }

    private static func isMeasuredTitleRegion(_ rect: NormalizedRect) -> Bool {
        contains(rect, in: region)
            && (0.40...0.60).contains(rect.center.x)
            && (0.09...0.14).contains(rect.center.y)
    }

    private static func contains(_ rect: NormalizedRect, in region: NormalizedRect) -> Bool {
        rect.x >= region.x && rect.y >= region.y
            && rect.x + rect.width <= region.x + region.width
            && rect.y + rect.height <= region.y + region.height
    }

    private static func isValid(_ observation: OCRTextObservation) -> Bool {
        observation.rect.isValid
            && observation.confidence.isFinite
            && (0...1).contains(observation.confidence)
            && !canonicalText(observation.text).isEmpty
    }

    private static func canonicalText(_ text: String) -> String {
        let compatible = text.precomposedStringWithCompatibilityMapping
        let scalars = compatible.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }
        return String(String.UnicodeScalarView(scalars))
    }
}
