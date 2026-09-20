import Foundation

public enum VisualResultDetectorError: Error, Equatable, Sendable {
    case invalidDimensions
    case insufficientBytes
}

public struct VisualResultDetection: Sendable {
    public let classification: GameStateClassification
    /// A partially matched result stays stop-only; OCR may not fill missing visual anchors.
    public let isResultCandidate: Bool
}

/// Matches only the fixed result title, content header, and repeat label. Dynamic result rows
/// and the phone status bar are excluded. Correlation AND absolute luminance agreement are
/// required, so a dimmed result underneath a modal is not a match.
public enum VisualResultDetector {
    private static let markers: [VisualResultMarker] = [
        .successTitle, .failureTitle, .experienceHeader, .lootHeader, .repeatOption,
    ]

    public static func classifyRGBA(
        _ bytes: [UInt8], width: Int, height: Int, bytesPerRow: Int
    ) throws -> GameStateClassification {
        try detectRGBA(bytes, width: width, height: height, bytesPerRow: bytesPerRow)
            .classification
    }

    public static func detectRGBA(
        _ bytes: [UInt8], width: Int, height: Int, bytesPerRow: Int,
        modalDetection: WideModalButtonDetection? = nil,
        repeatStamp: RepeatSelectedStampDetection? = nil
    ) throws -> VisualResultDetection {
        guard width > 1, height > 1, width <= 10_000, height <= 10_000,
              width * height <= 25_000_000,
              bytesPerRow >= width * 4, bytesPerRow <= Int.max / height
        else { throw VisualResultDetectorError.invalidDimensions }
        guard bytes.count >= bytesPerRow * height else {
            throw VisualResultDetectorError.insufficientBytes
        }
        let modal = try modalDetection ?? WideModalButtonDetector.detectRGBA(
            bytes, width: width, height: height, bytesPerRow: bytesPerRow
        )
        guard modal.layout == .none else {
            return rejected("modalPresent", isResultCandidate: false)
        }
        guard MirrorContentLayout.hasReferenceProportions(width: width, height: height)
        else { return rejected("unsupportedImageGeometry", isResultCandidate: false) }

        var scores = Dictionary(uniqueKeysWithValues: markers.map { marker in
            (marker, bestSimilarity(
                marker, listOffset: 0,
                bytes: bytes, width: width, height: height, bytesPerRow: bytesPerRow
            ))
        })
        func matched(_ marker: VisualResultMarker) -> Bool {
            (scores[marker] ?? -1) >= VisualResultMatch.minimumSimilarity
        }
        let titles = [VisualResultMarker.successTitle, .failureTitle].filter(matched)
        let pages = [VisualResultMarker.experienceHeader, .lootHeader].filter(matched)
        // A scrolled loot list moves the repeat row with the ">>" control and the stamp while
        // the title and header stay put. Search the bounded offsets only once the calibrated
        // position fails under a matched title and header; every result target then follows
        // the offset the row was found at.
        var listOffset = 0.0
        var repeatMatched = matched(.repeatOption)
        if !repeatMatched, titles.count == 1, pages.count == 1 {
            var best = scores[.repeatOption] ?? -1
            for candidate in VisualResultListOffset.candidates {
                let score = bestSimilarity(
                    .repeatOption, listOffset: candidate,
                    bytes: bytes, width: width, height: height, bytesPerRow: bytesPerRow
                )
                if score > best {
                    best = score
                    listOffset = candidate
                }
            }
            scores[.repeatOption] = best
            repeatMatched = listOffset != 0 && best >= VisualResultListOffset.minimumSimilarity
        }
        let isCandidate = !titles.isEmpty || (!pages.isEmpty && repeatMatched)
        let scoreDetail = markers.map {
            "\($0.rawValue)=\(String(format: "%.5f", scores[$0] ?? -1))"
        }.joined(separator: ", ") + ", repeatListOffset=\(String(format: "%.5f", listOffset))"
        guard titles.count == 1, pages.count == 1, repeatMatched,
              let title = titles.first, let page = pages.first
        else { return rejected("incompleteOrAmbiguousMarkers, \(scoreDetail)", isResultCandidate: isCandidate) }

        let stamp = try repeatStamp.flatMap { $0.listOffset == listOffset ? $0 : nil }
            ?? RepeatSelectedStampDetector.detectRGBA(
                bytes, width: width, height: height, bytesPerRow: bytesPerRow,
                listOffset: listOffset
            )
        guard stamp.isValid, stamp.isPresent || stamp.isClearlyAbsent else {
            return rejected(
                "ambiguousSelectionStamp, redPixelCount=\(stamp.redPixelCount), "
                    + "sampledPixelCount=\(stamp.sampledPixelCount), redPixelRatio=\(stamp.redPixelRatio), "
                    + scoreDetail,
                isResultCandidate: true
            )
        }
        let success = title == .successTitle
        let state: GameState = success
            ? (stamp.isPresent ? .missionCompleteRepeatSelected : .missionComplete)
            : (stamp.isPresent ? .missionFailedRepeatSelected : .missionFailed)
        func makeEvidence(_ marker: VisualResultMarker, kind: GameEvidenceKind) -> GameStateEvidence {
            let offset = marker == .repeatOption ? listOffset : 0
            let match = VisualResultMatch(
                marker: marker, region: VisualResultMatch.region(for: marker, listOffset: offset),
                similarity: scores[marker] ?? -1, listOffset: offset
            )
            return GameStateEvidence(
                kind: kind, observation: nil,
                detail: "source=resultVisualV1, marker=\(marker.rawValue), "
                    + "similarity=\(match.similarity), minimumSimilarity=\(VisualResultMatch.minimumSimilarity)"
                    + (offset == 0 ? "" : ", listOffset=\(offset)"),
                visualMatch: match
            )
        }
        let evidence = [
            makeEvidence(title, kind: success ? .missionCompleteTitle : .missionFailedTitle),
            makeEvidence(page, kind: page == .experienceHeader ? .missionExperiencePage : .missionLootPage),
            makeEvidence(.repeatOption, kind: .missionRepeatOption),
            GameStateEvidence(
                kind: stamp.isPresent ? .repeatSelectedMarker : .repeatUnselectedMarker,
                observation: nil,
                detail: stamp.isPresent
                    ? RepeatSelectedStampDetector.evidenceSentinel + "; redPixelRatio=\(stamp.redPixelRatio)"
                    : RepeatSelectedStampDetector.absentEvidenceSentinel
            ),
        ]
        let repeatRect = VisualResultMatch.region(for: .repeatOption, listOffset: listOffset)
        let classification = GameStateClassification(
            state: state, evidence: evidence,
            allowedActions: stamp.isPresent ? [] : [AllowedGameAction(
                name: .selectMissionRepeat,
                target: NamedGameTarget(
                    name: .missionRepeatOption,
                    sourceText: VisualResultEvidence.measuredRepeatOptionSentinel,
                    rect: repeatRect, point: repeatRect.center
                )
            )]
        )
        return VisualResultDetection(
            classification: stamp.isPresent
                ? MissionResultTopActionResolver.resolve(classification: classification)
                : classification,
            isResultCandidate: true
        )
    }

    private static func rejected(_ detail: String, isResultCandidate: Bool) -> VisualResultDetection {
        VisualResultDetection(
            classification: GameStateClassification(
                state: .unknown,
                evidence: [.init(kind: .lowConfidenceMarker, observation: nil,
                                 detail: "resultVisualRejected: \(detail)")],
                allowedActions: []
            ),
            isResultCandidate: isResultCandidate
        )
    }

    private static func bestSimilarity(
        _ marker: VisualResultMarker, listOffset: Double,
        bytes: [UInt8], width: Int, height: Int, bytesPerRow: Int
    ) -> Double {
        VisualRegionMatcher.bestSimilarity(
            region: VisualResultMatch.region(for: marker, listOffset: listOffset),
            templates: VisualResultTemplates.samples[marker] ?? [],
            sampleWidth: VisualResultTemplates.sampleWidth, sampleHeight: VisualResultTemplates.sampleHeight,
            bytes: bytes, width: width, height: height, bytesPerRow: bytesPerRow
        )
    }
}
