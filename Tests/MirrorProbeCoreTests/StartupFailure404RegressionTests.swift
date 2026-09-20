import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
@testable import MirrorProbeCore

@Suite("Captured 404x874 failure-result startup regression")
struct StartupFailure404RegressionTests {
    // Byte-identical final.png from auto-level-20260916-030418.5d1gmr, which stopped
    // unknown before counting a cycle or posting input. All variants below are synthetic.
    private let fingerprint = "dca2172b97116663eb99c37dbe59c27fba26c3c9e75d47cea7f81457c6135c3c"
    private let identity = AutoLevelWindowIdentity(processID: 91507, windowID: 65194)

    @Test("The original capture identifies failure, EXP, and an unselected repeat row without OCR")
    func originalCaptureHasTrustedVisualResultEvidence() throws {
        let frame = try fixture()
        let classification = try classify(frame)
        #expect(classification.state == .missionFailed)
        #expect(MissionSuccessPageIdentity.resolve(in: classification) == .experience)
        #expect(VisualResultEvidence.hasConsistentVisualEvidence(in: classification))
        #expect(classification.evidence.allSatisfy { $0.observation == nil })
        #expect(classification.policyGatedActions.isEmpty)
        #expect(classification.allowedActions.map(\.name) == [.selectMissionRepeat])

        let matches = classification.evidence.compactMap(VisualResultEvidence.validatedMatch)
        #expect(matches.count == 3)
        #expect(Set(matches.map { $0.marker.rawValue }) == [
            "failureTitle", "experienceHeader", "repeatOption",
        ])
        #expect(matches.allSatisfy { $0.similarity >= VisualResultMatch.minimumSimilarity })
        let unselected = classification.evidence.filter { $0.kind == .repeatUnselectedMarker }
        #expect(unselected.count == 1)
        #expect(unselected.first?.detail == RepeatSelectedStampDetector.absentEvidenceSentinel)
        #expect(!classification.evidence.contains { $0.kind == .repeatSelectedMarker })

        let target = AutoLevelActionTarget(try #require(classification.allowedActions.first).target)
        #expect(target.sourceText == VisualResultEvidence.measuredRepeatOptionSentinel)
        #expect(MissionRepeatSelectionProof.page(in: classification, matching: target) == .experience)
        assertTargetInsideCapturedRepeatRow(target, frame: frame)
    }

    @Test("Startup counts one failed cycle and requests the visible repeat row without posting input")
    func startupCountsFailureThenRequestsRepeat() throws {
        let frame = try fixture()
        let classification = try classify(frame)
        let observation = snapshot(classification, at: 1)
        var controller = makeController()

        #expect(controller.consume(observation) == .completedCycle(.init(count: 1, outcome: .failure)))
        #expect(controller.completedCycles == 1)
        #expect(controller.actionsIssued == 0)
        let decision = controller.consume(observation)
        guard case let .requestAction(request) = decision else {
            Issue.record("Expected startup repeat request, received \(decision)")
            throw FixtureError.expectedAction
        }
        #expect(request.intent == .selectMissionRepeat)
        #expect(request.observedState == .missionFailed)
        #expect(request.frameFingerprint == fingerprint)
        #expect(request.completedCycles == 1)
        #expect(request.repeatSelectionRetryPage == nil)
        #expect(observation.actionCandidates == [.init(intent: request.intent, target: request.target)])
        assertTargetInsideCapturedRepeatRow(request.target, frame: frame)
        #expect(controller.completedCycles == 1)
        #expect(controller.actionsIssued == 1)
        // This is a pure controller decision. No runtime, event posting, or posted-action
        // acknowledgement is invoked by the regression replay.
        #expect(controller.pendingActionAcknowledgementDeadline == nil)
    }

    @Test("Dimming this captured result cannot authorize startup actions",
          arguments: [0.85, 0.65, 0.35])
    func dimmedOriginalIsRejected(factor: Double) throws {
        var frame = try fixture()
        for offset in stride(from: 0, to: frame.bytes.count, by: 4) {
            for channel in 0..<3 {
                frame.bytes[offset + channel] = UInt8(Double(frame.bytes[offset + channel]) * factor)
            }
        }
        assertUnknownWithoutActions(try classify(frame))
    }

    @Test("Covering the original failure title, EXP header, or repeat label removes every action",
          arguments: [VisualResultMarker.failureTitle, .experienceHeader, .repeatOption])
    func coveredRequiredMarkerIsRejected(marker: VisualResultMarker) throws {
        var frame = try fixture()
        // Pixel bounds measured from this screenshot, independent of detector search ROIs.
        // Each mask fully covers one label while retaining both other result labels.
        let bounds: (x: Range<Int>, y: Range<Int>)
        switch marker {
        case .failureTitle: bounds = (150..<261, 85..<121)
        case .experienceHeader: bounds = (306..<398, 124..<151)
        case .repeatOption: bounds = (8..<132, 200..<229)
        default: throw FixtureError.unexpectedMarker
        }
        for y in bounds.y {
            for x in bounds.x {
                let offset = y * frame.bytesPerRow + x * 4
                frame.bytes[offset] = 0
                frame.bytes[offset + 1] = 0
                frame.bytes[offset + 2] = 0
                frame.bytes[offset + 3] = 255
            }
        }
        assertUnknownWithoutActions(try classify(frame))
    }

    @Test("Removing any measured anchor invalidates the original capture's repeat proof",
          arguments: [GameEvidenceKind.missionFailedTitle, .missionExperiencePage,
                      .missionRepeatOption, .repeatUnselectedMarker])
    func missingEvidenceInvalidatesRepeatProof(missing: GameEvidenceKind) throws {
        let original = try classify(fixture())
        #expect(original.state == .missionFailed)
        #expect(original.allowedActions.map(\.name) == [.selectMissionRepeat])
        let incomplete = GameStateClassification(
            state: original.state,
            evidence: original.evidence.filter { $0.kind != missing },
            allowedActions: original.allowedActions
        )
        #expect(!VisualResultEvidence.hasConsistentVisualEvidence(in: incomplete))
        #expect(MissionSuccessPageIdentity.resolve(in: incomplete) == nil)
        #expect(VisualResultEvidence.trustedRepeatRect(in: incomplete) == nil)
        let target = AutoLevelActionTarget(try #require(original.allowedActions.first).target)
        #expect(MissionRepeatSelectionProof.page(in: incomplete, matching: target) == nil)
    }

    private func assertTargetInsideCapturedRepeatRow(_ target: AutoLevelActionTarget, frame: Frame) {
        #expect(target.isValid)
        // The visible repeat label occupies the left row at y=207...221 in final.png.
        // Check the clickable center against the label and its surrounding row pixels,
        // rather than checking it only against the same production constant that created it.
        #expect((10.0...128.0).contains(target.point.x * Double(frame.width)))
        #expect((202.0...227.0).contains(target.point.y * Double(frame.height)))
    }

    private func assertUnknownWithoutActions(_ classification: GameStateClassification) {
        #expect(classification.state == .unknown)
        #expect(classification.allowedActions.isEmpty)
        #expect(classification.policyGatedActions.isEmpty)
        #expect(!VisualResultEvidence.hasConsistentVisualEvidence(in: classification))
        #expect(MissionSuccessPageIdentity.resolve(in: classification) == nil)
        #expect(snapshot(classification, at: 1).actionCandidates.isEmpty)
        var controller = makeController()
        #expect(controller.consume(snapshot(classification, at: 1))
            == .wait(.transientState(kind: .unknown, observationCount: 1)))
        #expect(controller.consume(snapshot(classification, at: 16))
            == .stop(.uncertainStateExceededGrace(kind: .unknown)))
        #expect(controller.actionsIssued == 0)
        #expect(controller.completedCycles == 0)
    }

    private func makeController() -> AutoLevelController {
        .init(session: .init(sessionID: "startup-failure-404x874", startedAt: 0,
                            windowIdentity: identity),
              policy: .init(uncertainStateGraceDuration: 15, uncertainStateGraceSnapshots: 8))
    }

    private func snapshot(_ classification: GameStateClassification, at time: TimeInterval)
        -> AutoLevelSnapshot
    {
        .init(classification: classification,
              runtime: .init(observedAt: time, windowIdentity: identity, frameFingerprint: fingerprint))
    }

    private func classify(_ frame: Frame) throws -> GameStateClassification {
        try AutoLevelVisualClassifier.classifyRGBA(
            frame.bytes, width: frame.width, height: frame.height, bytesPerRow: frame.bytesPerRow
        )
    }

    private func fixture() throws -> Frame {
        let url = try #require(Bundle.module.url(
            forResource: "visual-result-failure-404x874", withExtension: "png"
        ))
        let data = try Data(contentsOf: url)
        #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == fingerprint)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 404 && image.height == 874)
        var frame = Frame(bytes: [UInt8](repeating: 0, count: image.width * image.height * 4),
                          width: image.width, height: image.height)
        let width = frame.width, height = frame.height, bytesPerRow = frame.bytesPerRow
        let rendered = frame.bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        #expect(rendered)
        guard rendered else { throw FixtureError.cannotRender }
        return frame
    }

    private struct Frame {
        var bytes: [UInt8]
        let width: Int
        let height: Int
        var bytesPerRow: Int { width * 4 }
    }

    private enum FixtureError: Error { case cannotRender, expectedAction, unexpectedMarker }
}
