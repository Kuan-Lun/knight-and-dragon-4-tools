import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
@testable import MirrorProbeCore

@Suite("Battle visual controls from native captures")
struct VisualBattleDetectorTests {
    @Test("Two footer glyphs identify battle and retreat permits temporal monitoring",
          arguments: [
            "active-battle-control-grid", "active-battle-low-retreat-grid",
            "visual-battle-pause-low-confidence", "visual-battle-low-auto",
            "visual-battle-five-zero-hp", "visual-battle-native-2x", "battle-no-modal",
            "visual-battle-progress-before", "visual-battle-progress-after",
          ])
    func nativeBattle(resource: String) throws {
        let image = try load(resource)
        let result = try classify(image)
        #expect(result.state == .battle)
        #expect(result.allowedActions.isEmpty)
        #expect(VisualBattleEvidence.hasConsistentVisualEvidence(in: result))
        #expect(VisualBattleEvidence.hasRunningBattleEvidence(in: result))
        #expect(VisualBattleEvidence.hasTrustedRetreat(in: result))
        #expect(result.evidence.count == 4)
        #expect(result.evidence.allSatisfy { $0.observation == nil && $0.visualMatch == nil })
        let matches = result.evidence.compactMap(\.battleVisualMatch)
        #expect(Set(matches.map { $0.marker.rawValue })
            == Set(VisualBattleMarker.allCases.map(\.rawValue)))
        #expect(matches.allSatisfy { $0.similarity >= VisualBattleMatch.minimumSimilarity })
        let action = try #require(result.policyGatedActions.first)
        #expect(result.policyGatedActions.count == 1)
        #expect(action.name == .openBattleRetreatConfirmation)
        #expect(action.requirement == .temporalDefeatRecovery)
        #expect(action.target.name == .battleRetreat)
        #expect(action.target.rect == VisualBattleEvidence.measuredRetreatRect)
        #expect(action.target.sourceText == VisualBattleEvidence.measuredRetreatSentinel)
        let snapshot = AutoLevelSnapshot(
            classification: result,
            runtime: .init(observedAt: 1,
                           windowIdentity: .init(processID: 91507, windowID: 65194),
                           frameFingerprint: image.fingerprint)
        )
        // A gated target is a candidate; only the controller's temporal state can issue it.
        #expect(snapshot.actionCandidates.map(\.intent) == [.requestRetreat])
    }

    @Test("Dimmed battle controls, modals and nonbattle pages never authorize a battle retreat",
          arguments: [
            "battle-event-one-button", "battle-intro-one-button", "battle-prompt-one-button-alt",
            "retreat-two-buttons", "defeat-one-button", "loot-two-buttons",
            "mission-repeat-selected-srlected", "returned-party-manual-stop",
          ])
    func nativeNegatives(resource: String) throws {
        let result = try classify(load(resource))
        #expect(result.state == .unknown)
        #expect(result.allowedActions.isEmpty)
        #expect(result.policyGatedActions.isEmpty)
        #expect(!VisualBattleEvidence.hasConsistentVisualEvidence(in: result))
    }

    @Test("Obscuring either required footer control fails closed", arguments: VisualBattleEvidence.identityMarkers)
    func requiredGlyphOcclusion(marker: VisualBattleMarker) throws {
        var image = try load("visual-battle-native-2x")
        // Modify only the in-memory test buffer. Original capture files remain byte-identical.
        for region in VisualBattleMatch.regions(for: marker) {
            for y in Int(floor(region.y * Double(image.height)))..<Int(ceil((region.y + region.height) * Double(image.height))) {
                for x in Int(floor(region.x * Double(image.width)))..<Int(ceil((region.x + region.width) * Double(image.width))) {
                    let offset = y * image.bytesPerRow + x * 4
                    image.bytes[offset] = 0
                    image.bytes[offset + 1] = 0
                    image.bytes[offset + 2] = 0
                }
            }
        }
        let result = try classify(image)
        #expect(result.state == .unknown)
        #expect(result.allowedActions.isEmpty && result.policyGatedActions.isEmpty)
    }

    @Test("An obscured pause preserves retreat evidence while a missing retreat removes monitoring proof",
          arguments: [VisualBattleMarker.pauseControl, .retreatControl])
    func optionalControlOcclusion(marker: VisualBattleMarker) throws {
        var image = try load("visual-battle-native-2x")
        for region in VisualBattleMatch.regions(for: marker) {
            replaceRegion(region, in: &image, scale: 0)
        }
        let result = try classify(image)
        #expect(result.state == .battle)
        #expect(VisualBattleEvidence.hasConsistentVisualEvidence(in: result))
        #expect(VisualBattleEvidence.hasRunningBattleEvidence(in: result) == (marker != .retreatControl))
        #expect(VisualBattleEvidence.hasTrustedRetreat(in: result) == (marker != .retreatControl))
        #expect(result.allowedActions.isEmpty)
        #expect(result.policyGatedActions.count == (marker == .pauseControl ? 1 : 0))
    }

    @Test("Skill brightness and the changing header are irrelevant to battle identity and evidence")
    func excludedRegionsDoNotAffectEvidence() throws {
        let original = try load("visual-battle-native-2x")
        let expected = try classify(original)
        for region in [
            NormalizedRect(x: 0.39, y: 0.866, width: 0.16, height: 0.027),
            NormalizedRect(x: 0.025, y: 0.095, width: 0.95, height: 0.041),
        ] {
            var changed = original
            replaceRegion(region, in: &changed, scale: 0.25)
            #expect(try classify(changed) == expected)
        }
    }

    @Test("Serialized visual evidence rejects missing, repeated, weak, displaced or mixed anchors")
    func evidenceCannotBeSubstituted() throws {
        let valid = try classify(load("visual-battle-native-2x"))
        let first = try #require(valid.evidence.first)
        let original = try #require(first.battleVisualMatch)
        func classification(_ evidence: [GameStateEvidence]) -> GameStateClassification {
            .init(state: .battle, evidence: evidence, allowedActions: [],
                  policyGatedActions: valid.policyGatedActions)
        }
        #expect(!VisualBattleEvidence.hasConsistentVisualEvidence(in: classification(Array(valid.evidence.dropFirst()))))
        #expect(!VisualBattleEvidence.hasConsistentVisualEvidence(in: classification(Array(repeating: first, count: 4))))
        for (similarity, region) in [
            (VisualBattleMatch.minimumSimilarity.nextDown, original.region),
            (Double.nan, original.region), (Double.infinity, original.region),
            (1.01, original.region),
            (1, NormalizedRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1)),
        ] {
            let replacement = GameStateEvidence(
                kind: .battleMarker, observation: nil, detail: "invalid test match",
                battleVisualMatch: .init(marker: original.marker, region: region, similarity: similarity)
            )
            #expect(!VisualBattleEvidence.hasConsistentVisualEvidence(in:
                classification([replacement] + valid.evidence.dropFirst())))
        }
        let mixed = GameStateEvidence(
            kind: .battleMarker,
            observation: .init(text: "not visual evidence", rect: original.region, confidence: 1),
            detail: first.detail, battleVisualMatch: original
        )
        #expect(!VisualBattleEvidence.hasConsistentVisualEvidence(in:
            classification([mixed] + valid.evidence.dropFirst())))
        let adverse = GameStateEvidence(kind: .conflictingStateMarkers, observation: nil, detail: "conflict")
        #expect(!VisualBattleEvidence.hasConsistentVisualEvidence(in: classification(valid.evidence + [adverse])))
    }

    private func classify(_ image: Image) throws -> GameStateClassification {
        try VisualBattleDetector.classifyRGBA(image.bytes, width: image.width,
                                              height: image.height, bytesPerRow: image.bytesPerRow)
    }

    private func replaceRegion(_ region: NormalizedRect, in image: inout Image, scale: Double) {
        for y in Int(floor(region.y * Double(image.height)))..<Int(ceil((region.y + region.height) * Double(image.height))) {
            for x in Int(floor(region.x * Double(image.width)))..<Int(ceil((region.x + region.width) * Double(image.width))) {
                let offset = y * image.bytesPerRow + x * 4
                for channel in 0..<3 {
                    image.bytes[offset + channel] = UInt8(Double(image.bytes[offset + channel]) * scale)
                }
            }
        }
    }

    private func load(_ resource: String) throws -> Image {
        let manifestURL = try #require(Bundle.module.url(forResource: "visual-battle-corpus", withExtension: "json"))
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        let fixture = try #require(manifest.fixtures.first { $0.resource == resource })
        let url = try #require(Bundle.module.url(forResource: resource, withExtension: "png"))
        let data = try Data(contentsOf: url)
        #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == fixture.pngSHA256)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == fixture.width && image.height == fixture.height)
        let bytesPerRow = image.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * image.height)
        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let address = buffer.baseAddress,
                  let context = CGContext(
                    data: address, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                        | CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard rendered else { throw FixtureError.cannotRender }
        return Image(bytes: bytes, width: image.width, height: image.height,
                     bytesPerRow: bytesPerRow, fingerprint: fixture.pngSHA256)
    }

    private struct Manifest: Decodable { let fixtures: [Fixture] }
    private struct Fixture: Decodable {
        let resource: String
        let width: Int
        let height: Int
        let pngSHA256: String
    }
    private struct Image {
        var bytes: [UInt8]
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let fingerprint: String
    }
    private enum FixtureError: Error { case cannotRender }
}
