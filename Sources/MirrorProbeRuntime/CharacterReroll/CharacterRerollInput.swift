import CoreGraphics
import Foundation
import MirrorProbeCore

extension MirrorProbeRuntime {
    static func postCharacterRerollClick(
        target: CharacterRerollTarget,
        observation: CharacterRerollObservation,
        identity: AutoLevelWindowIdentity,
        expectedFrame: CGRect,
        actionDeadline: TimeInterval,
        sessionDeadline: TimeInterval,
        stopURL: URL?
    ) throws -> CharacterRerollClickResult {
        let permittedButtonRect = CharacterRerollDetector.measuredRandomButtonRect
        let permittedButtonPoint = CharacterRerollDetector.measuredRandomButtonPoint
        guard observation.boundaryEvidence == .belowThreshold,
              case .rerollRequired = observation.decision,
              canonicalCharacterRerollText(target.sourceText) == "隨機",
              target.rect.isValid,
              characterRerollRect(target.rect, isContainedIn: permittedButtonRect),
              abs(target.point.x - permittedButtonPoint.x) <= 0.001,
              abs(target.point.y - permittedButtonPoint.y) <= 0.001,
              !isInsideCharacterDecisionOrResetRegion(target.point),
              observation.window.windowID == identity.windowID,
              observation.window.owningApplication?.processID == identity.processID,
              approximatelyEqual(observation.window.frame, expectedFrame, tolerance: 0.5)
        else {
            throw ProbeError.unsafeWindow(
                "the confirmed Random target was outside its only permitted control region"
            )
        }

        let clickPoint = CGPoint(
            x: expectedFrame.minX + expectedFrame.width * target.point.x,
            y: expectedFrame.minY + expectedFrame.height * target.point.y
        )
        let expectedGeometry = automationWindowGeometry(expectedFrame)
        let previousMouseLocation = CGEvent(source: nil)?.location
        var boundaryResult: CharacterRerollClickResult?
        let posted = try postSingleClick(at: clickPoint) {
            let frontmostProcessID = ForegroundApplicationFocus.currentApplication?.processIdentifier
            let windows = windowServerWindows() ?? []
            let currentWindow = windows.first { $0.identity.windowID == identity.windowID }
            let topmostWindow = topmostInputWindow(
                at: clickPoint,
                expectedWindowFrame: expectedFrame,
                expectedProcessID: identity.processID,
                windows: windows
            )
            let snapshot = AutoLevelInputSnapshot(
                windowIdentity: currentWindow?.identity,
                windowGeometry: currentWindow.map { automationWindowGeometry($0.frame) },
                frontmostProcessID: frontmostProcessID,
                topmostWindowIdentity: topmostWindow?.identity
            )
            let rejection = AutoLevelInputSafety.rejection(
                expectedWindowIdentity: identity,
                expectedWindowGeometry: expectedGeometry,
                inputMode: .foreground,
                snapshot: snapshot,
                now: ProcessInfo.processInfo.systemUptime,
                actionDeadline: actionDeadline,
                sessionDeadline: sessionDeadline,
                stopRequested: characterRerollStopRequested(stopURL)
            )
            guard let rejection else {
                return true
            }
            switch rejection {
            case .stopRequested:
                boundaryResult = .stopRequested
                return false
            case .sessionRuntimeExpired:
                boundaryResult = .maximumRuntimeReached
                return false
            case .applicationNotFrontmost:
                boundaryResult = .focusContended
                return false
            case .invalidTiming:
                throw ProbeError.unsafeWindow("the character reroll timing was invalid")
            case .actionAuthorizationExpired:
                throw ProbeError.unsafeWindow(
                    "the character reroll authorization expired before input"
                )
            case .windowUnavailable:
                throw ProbeError.unsafeWindow(
                    "the requested iPhone Mirroring window disappeared before input"
                )
            case .windowIdentityChanged:
                throw ProbeError.unsafeWindow(
                    "the iPhone Mirroring window identity changed before input"
                )
            case .windowGeometryChanged:
                throw ProbeError.unsafeWindow(
                    "the iPhone Mirroring window moved or resized before input"
                )
            case .clickPointObscured:
                throw ProbeError.unsafeWindow(
                    "another window covered the Random button before input"
                )
            }
        }

        guard posted.posted else {
            guard let boundaryResult else {
                throw ProbeError.unsafeWindow(
                    "the final character reroll boundary rejected input"
                )
            }
            return boundaryResult
        }
        if let previousMouseLocation {
            CGWarpMouseCursorPosition(previousMouseLocation)
        }
        return .posted
    }

    static func characterRerollTargetsMatch(
        _ lhs: CharacterRerollTarget,
        _ rhs: CharacterRerollTarget
    ) -> Bool {
        canonicalCharacterRerollText(lhs.sourceText) == "隨機"
            && canonicalCharacterRerollText(rhs.sourceText) == "隨機"
            && abs(lhs.point.x - rhs.point.x) <= 0.01
            && abs(lhs.point.y - rhs.point.y) <= 0.01
            && abs(lhs.rect.width - rhs.rect.width) <= 0.02
            && abs(lhs.rect.height - rhs.rect.height) <= 0.02
    }

    static func characterRerollStableDecisionsMatch(
        _ lhs: CharacterRerollDecision,
        _ rhs: CharacterRerollDecision
    ) -> Bool {
        switch (lhs, rhs) {
        case let (.rerollRequired(leftRoll, _), .rerollRequired(rightRoll, _)):
            return leftRoll == rightRoll
        case let (.thresholdReached(leftRoll), .thresholdReached(rightRoll)):
            // Two independently safe observations of the same quiescent pixels may disagree on
            // individual digit shapes while still agreeing that the configured boundary is met.
            return leftRoll.name == rightRoll.name
        default:
            return false
        }
    }

    static func characterRerollUnambiguousTotal(
        _ observation: CharacterRerollObservation
    ) -> Int? {
        guard !observation.fullFrameWasContaminated,
            !observation.focusedWasContaminated,
            observation.fullFrameTotal != nil
            || observation.credibleFullFrameTotals.isEmpty,
            observation.focusedTotal != nil
                || observation.credibleFocusedTotals.isEmpty
        else {
            return nil
        }
        switch (observation.fullFrameTotal, observation.focusedTotal) {
        case let (fullFrame?, focused?) where fullFrame == focused:
            return fullFrame
        case (_?, _?):
            return nil
        case let (fullFrame?, nil):
            return fullFrame
        case let (nil, focused?):
            return focused
        case (nil, nil):
            return nil
        }
    }

    static func characterRerollObservedTotalSource(
        _ observation: CharacterRerollObservation
    ) -> String? {
        guard !observation.fullFrameWasContaminated,
            !observation.focusedWasContaminated,
            observation.fullFrameTotal != nil
            || observation.credibleFullFrameTotals.isEmpty,
            observation.focusedTotal != nil
                || observation.credibleFocusedTotals.isEmpty
        else {
            return nil
        }
        switch (observation.fullFrameTotal, observation.focusedTotal) {
        case let (fullFrame?, focused?) where fullFrame == focused:
            return "agreement"
        case (_?, _?):
            return nil
        case (_?, nil):
            return "fullFrame"
        case (nil, _?):
            return "focused"
        case (nil, nil):
            return nil
        }
    }

    static func characterRerollBoundaryEvidenceName(
        _ evidence: CharacterTotalBoundaryEvidence
    ) -> String {
        switch evidence {
        case .belowThreshold:
            return "belowThreshold"
        case .thresholdReached:
            return "thresholdReached"
        case .boundaryConflict:
            return "boundaryConflict"
        case .unavailable:
            return "unavailable"
        }
    }

    /// Includes every generated field but excludes the iPhone clock and all tappable controls.
    static let characterRerollResultRegion = CharacterRerollPixelGuard.resultRegion
    /// Four static live captures were byte-identical in this region. Keep a small allowance for
    /// capture conversion noise while still requiring the generated result to be visually still.
    static let characterRerollMaximumQuiescentDifference =
        CharacterRerollPixelGuard.maximumQuiescentDifference
    /// Distinct measured rolls differ by roughly 0.006 mean RGB. This conservative floor proves
    /// the click changed the generated result even if name and total happen to repeat.
    static let characterRerollMinimumChangedDifference = 0.001

    static func characterRerollFramesAreQuiescent(
        _ lhs: RGBAFrame,
        _ rhs: RGBAFrame
    ) throws -> Bool {
        try characterRerollResultDifference(lhs, rhs)
            <= characterRerollMaximumQuiescentDifference
    }

    static func characterRerollInputSurfaceDifferences(
        _ lhs: RGBAFrame,
        _ rhs: RGBAFrame
    ) throws -> CharacterRerollPixelGuardDifferences {
        guard lhs.width == rhs.width,
              lhs.height == rhs.height,
              lhs.bytesPerRow == rhs.bytesPerRow
        else {
            throw ProbeError.unsafeWindow(
                "the character-reroll capture dimensions changed during the final pixel guard"
            )
        }
        return try CharacterRerollPixelGuard.differences(
            lhs.bytes,
            rhs.bytes,
            width: lhs.width,
            height: lhs.height,
            bytesPerRow: lhs.bytesPerRow
        )
    }

    /// Retain only the latest rejected pair per run, so a later stop is diagnosable without
    /// accumulating captures during a long session. This runs only after cancelling input.
    static func writeCharacterRerollPixelGuardDiagnostic(
        before: CharacterRerollObservation,
        rejectedImage: CGImage,
        differences: CharacterRerollPixelGuardDifferences,
        rerollsPosted: Int,
        reportURL: URL?
    ) throws {
        FileHandle.standardError.write(Data(
            "characterPixelGuard: inputSurfaceDifference=\(differences.inputSurface), "
                .appending("resultDifference=\(differences.result), ")
                .appending("maximum=\(CharacterRerollPixelGuard.maximumQuiescentDifference)\n")
                .utf8
        ))
        guard let directory = reportURL?.deletingLastPathComponent() else { return }
        let beforeURL = directory.appendingPathComponent("pixel-guard-before.png")
        let rejectedURL = directory.appendingPathComponent("pixel-guard-rejected.png")
        let beforeSHA256 = try writePNG(before.image, to: beforeURL)
        let rejectedSHA256 = try writePNG(rejectedImage, to: rejectedURL)
        try writeJSON(
            CharacterRerollPixelGuardDiagnostic(
                schemaVersion: 1,
                timestamp: ISO8601DateFormatter().string(from: Date()),
                rerollsPosted: rerollsPosted,
                inputSurfaceDifference: differences.inputSurface,
                resultDifference: differences.result,
                maximumQuiescentDifference: CharacterRerollPixelGuard.maximumQuiescentDifference,
                inputSurfaceRegion: CharacterRerollPixelGuard.inputSurfaceRegion,
                resultRegion: CharacterRerollPixelGuard.resultRegion,
                beforeImagePath: beforeURL.path,
                beforeImageSHA256: beforeSHA256,
                rejectedImagePath: rejectedURL.path,
                rejectedImageSHA256: rejectedSHA256
            ),
            to: directory.appendingPathComponent("pixel-guard.json")
        )
    }

    static func characterRerollResultDifference(
        _ lhs: RGBAFrame,
        _ rhs: RGBAFrame
    ) throws -> Double {
        guard lhs.width == rhs.width,
              lhs.height == rhs.height,
              lhs.bytesPerRow == rhs.bytesPerRow
        else {
            throw ProbeError.unsafeWindow(
                "the character-reroll capture dimensions changed during comparison"
            )
        }
        return try FrameAnalyzer.meanAbsoluteDifferenceRGBA(
            lhs.bytes,
            rhs.bytes,
            width: lhs.width,
            height: lhs.height,
            bytesPerRow: lhs.bytesPerRow,
            region: characterRerollResultRegion
        )
    }

    static func characterRerollRect(
        _ inner: MirrorProbeCore.NormalizedRect,
        isContainedIn outer: MirrorProbeCore.NormalizedRect
    ) -> Bool {
        inner.isValid
            && outer.isValid
            && inner.x >= outer.x
            && inner.y >= outer.y
            && inner.x + inner.width <= outer.x + outer.width
            && inner.y + inner.height <= outer.y + outer.height
    }

    static func characterRerollTotal(_ decision: CharacterRerollDecision) -> Int? {
        characterRerollRoll(decision)?.total
    }

    static func characterRerollRoll(
        _ decision: CharacterRerollDecision
    ) -> CharacterRoll? {
        switch decision {
        case let .rerollRequired(roll, _), let .thresholdReached(roll):
            return roll
        case .unsafe:
            return nil
        }
    }

    static func canonicalCharacterRerollText(_ text: String) -> String {
        let compatible = text.precomposedStringWithCompatibilityMapping.uppercased()
        let scalars = compatible.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }
        return String(String.UnicodeScalarView(scalars))
            .replacingOccurrences(of: "：", with: ":")
    }

    static func characterRerollStopRequested(_ stopURL: URL?) -> Bool {
        applicationStopRequest.isRequested(stopFileURL: stopURL)
    }

    static func isInsideCharacterDecisionOrResetRegion(
        _ point: MirrorProbeCore.NormalizedPoint
    ) -> Bool {
        (0.32...0.68).contains(point.x)
            && (0.62...0.73).contains(point.y)
    }
}
