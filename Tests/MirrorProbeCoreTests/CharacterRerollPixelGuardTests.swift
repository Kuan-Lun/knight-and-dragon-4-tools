import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import MirrorProbeCore

@Suite("Character reroll final pixel guard")
struct CharacterRerollPixelGuardTests {
    @Test("The rejected live PNG is Jennie total 67 and its clock overlaps only the former crop")
    func rejectedLiveFrameReplay() throws {
        let fixture = try JSONDecoder().decode(
            LiveFixture.self,
            from: Data(contentsOf: fixtureURL("total-67-pixel-guard-ocr.json"))
        )
        #expect(fixture.image.width == 406)
        #expect(fixture.image.height == 890)
        let observations = fixture.ocr.observations
        let focusedObservations = try JSONDecoder().decode(
            [OCRTextObservation].self,
            from: Data(contentsOf: fixtureURL("total-67-pixel-guard-focused-ocr.json"))
        )
        let focused = CharacterFocusedTotalResolver.resolveEvidence(
            observations: focusedObservations
        )
        #expect(CharacterFullFrameTotalResolver.resolve(observations: observations)
                == .exact(.init(value: 67, digitCount: 2)))
        #expect(focused == .exact(.init(value: 67, digitCount: 2)))
        let decision = CharacterRerollDetector.detect(observations: observations, minimumTotal: 90)
        guard case let .rerollRequired(roll, observedTarget) = decision else {
            Issue.record("The captured low character no longer resolves safely: \(decision)")
            return
        }
        #expect(roll == CharacterRoll(name: "JENNIE", total: 67))
        #expect(observedTarget.point == CharacterRerollDetector.measuredRandomButtonPoint)

        let clock = try #require(observations.first { $0.text == "11:04" })
        let clockBottom = clock.rect.y + clock.rect.height
        #expect(clock.rect.y < 0.08 && clockBottom > 0.08)
        #expect(clockBottom < CharacterRerollPixelGuard.inputSurfaceRegion.y)
        let pageTitle = try #require(observations.first { $0.text == "姓名/種族/信仰" })
        let random = try #require(observations.first { $0.text == "隨機" })
        #expect(pageTitle.rect.y > CharacterRerollPixelGuard.inputSurfaceRegion.y)
        #expect(random.rect.y > CharacterRerollPixelGuard.inputSurfaceRegion.y)

        let source = try #require(CGImageSourceCreateWithURL(
            fixtureURL("total-67-pixel-guard.png") as CFURL, nil
        ))
        let capturedImage = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(capturedImage.width == fixture.image.width)
        #expect(capturedImage.height == fixture.image.height)
        let width = capturedImage.width
        let height = capturedImage.height
        var bytes = image(width: width, height: height)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        let drewImage = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress,
                  let context = CGContext(
                    data: base, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: bitmapInfo
                  )
            else { return false }
            context.draw(capturedImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        #expect(drewImage)
        #expect(CharacterTotalDigitDetector.detectRGBA(
            bytes, width: width, height: height, bytesPerRow: width * 4
        ) == .digitCount(2))
        #expect(CharacterTotalBoundaryEvidenceResolver.resolve(
            fullFrame: CharacterFullFrameTotalResolver.resolve(observations: observations),
            focused: focused,
            renderedDigitDetection: CharacterTotalDigitDetector.detectRGBA(
                bytes, width: width, height: height, bytesPerRow: width * 4
            ),
            minimumTotal: 90
        ) == .belowThreshold)
    }

    @Test("The entire measured status bar is excluded at native and scaled dimensions")
    func excludesStatusBarBottom() throws {
        for scale in [1, 2] {
            let width = 406 * scale
            let height = 890 * scale
            let original = image(width: width, height: height)
            var changed = original
            // The former y=.08 crop began at row 71 and included these status-bar pixels.
            paint(x: 45 * scale, y: 71 * scale, width: 42 * scale, height: 5 * scale,
                  imageWidth: width, bytes: &changed)
            let differences = try CharacterRerollPixelGuard.differences(
                original, changed, width: width, height: height, bytesPerRow: width * 4
            )
            #expect(differences.inputSurface == 0)
            #expect(differences.result == 0)
            #expect(differences.inputSurfaceIsQuiescent)
            let formerDifference = try FrameAnalyzer.meanAbsoluteDifferenceRGBA(
                original, changed, width: width, height: height, bytesPerRow: width * 4,
                region: NormalizedRect(x: 0.01, y: 0.08, width: 0.98, height: 0.65)
            )
            #expect(formerDifference > CharacterRerollPixelGuard.maximumQuiescentDifference)
        }
    }

    @Test("Title, Random, total, Decide, and Reset changes still reject the final guard")
    func retainsEveryInputAnchor() throws {
        for scale in [1, 2] {
            let width = 406 * scale
            let height = 890 * scale
            let original = image(width: width, height: height)
            for (label, x, y) in [
                ("title", 145, 95),
                ("Random", 332, 95),
                ("total", 350, 285),
                ("Decide", 170, 575),
                ("Reset", 170, 615),
            ] {
                var changed = original
                paint(x: x * scale, y: y * scale, width: 25 * scale, height: 12 * scale,
                      imageWidth: width, bytes: &changed)
                let differences = try CharacterRerollPixelGuard.differences(
                    original, changed, width: width, height: height, bytesPerRow: width * 4
                )
                #expect(!differences.inputSurfaceIsQuiescent, Comment(rawValue: label))
                #expect(differences.resultIsQuiescent == (label != "total"),
                        Comment(rawValue: label))
            }
        }
    }

    @Test("Unchanged low result permits only three complete authorization retries")
    func boundsRetries() {
        var recovery = CharacterRerollPixelGuardRecovery()
        for attempt in 1...CharacterRerollPixelGuardRecovery.maximumRetries {
            #expect(evaluate(&recovery) == .retry(attempt: attempt))
        }
        #expect(evaluate(&recovery) == .exhausted)
        #expect(evaluate(&recovery, evidence: .thresholdReached) == .exhausted)
        #expect(evaluate(&recovery) == .exhausted)
    }

    @Test("High, conflicting, and unavailable boundary evidence permanently cancel recovery")
    func unsafeEvidenceIsSticky() {
        for evidence in [
            CharacterTotalBoundaryEvidence.thresholdReached, .boundaryConflict, .unavailable,
        ] {
            var recovery = CharacterRerollPixelGuardRecovery()
            #expect(evaluate(&recovery, evidence: evidence) == .unsafe)
            #expect(evaluate(&recovery) == .unsafe)
        }
    }

    @Test("A changed or unrecognized character cannot be replaced by a later low sample")
    func changedCharacterIsSticky() {
        for observed in [
            lowDecision(name: "OTHER"),
            lowDecision(total: 68),
            .thresholdReached(roll: CharacterRoll(name: "JENNIE", total: 90)),
            .unsafe(reason: .invalidObservation),
        ] {
            var recovery = CharacterRerollPixelGuardRecovery()
            #expect(evaluate(&recovery, observed: observed) == .unsafe)
            #expect(evaluate(&recovery) == .unsafe)
        }
        var recovery = CharacterRerollPixelGuardRecovery()
        #expect(recovery.evaluate(
            authorized: .unsafe(reason: .invalidObservation), observed: lowDecision(),
            boundaryEvidence: .belowThreshold, differences: surfaceOnlyChange
        ) == .unsafe)
        #expect(evaluate(&recovery) == .unsafe)
    }

    @Test("Generated-field pixel movement blocks recovery even when name and total match")
    func changedResultIsSticky() {
        var recovery = CharacterRerollPixelGuardRecovery()
        #expect(evaluate(&recovery, differences: .init(inputSurface: 0.005, result: 0.001))
                == .unsafe)
        #expect(evaluate(&recovery) == .unsafe)
    }

    @Test("Target changes beyond the existing tolerance or invalid coordinates are terminal")
    func changedTargetIsSticky() {
        let original = target
        for changed in [
            CharacterRerollTarget(sourceText: "決定", rect: original.rect, point: original.point),
            CharacterRerollTarget(sourceText: original.sourceText, rect: original.rect,
                                 point: .init(x: original.point.x + 0.011, y: original.point.y)),
            CharacterRerollTarget(sourceText: original.sourceText, rect: original.rect,
                                 point: .init(x: original.point.x, y: original.point.y + 0.011)),
            CharacterRerollTarget(sourceText: original.sourceText,
                                 rect: .init(x: 0.77, y: 0.10, width: 0.20, height: 0.034),
                                 point: original.point),
            CharacterRerollTarget(sourceText: original.sourceText,
                                 rect: .init(x: 0.79, y: 0.10, width: 0.175, height: 0.060),
                                 point: original.point),
            CharacterRerollTarget(sourceText: original.sourceText, rect: original.rect,
                                 point: .init(x: .nan, y: original.point.y)),
            CharacterRerollTarget(sourceText: original.sourceText,
                                 rect: .init(x: .infinity, y: 0.10, width: 0.175, height: 0.034),
                                 point: original.point),
        ] {
            var recovery = CharacterRerollPixelGuardRecovery()
            #expect(evaluate(&recovery, observed: lowDecision(target: changed)) == .unsafe)
            #expect(evaluate(&recovery) == .unsafe)
        }
    }

    @Test("Measured target variation inside the existing tolerance can be reauthorized")
    func permitsBoundedTargetVariation() {
        let changed = CharacterRerollTarget(
            sourceText: target.sourceText,
            rect: .init(x: 0.79, y: 0.10, width: 0.18, height: 0.04),
            point: .init(x: target.point.x + 0.009, y: target.point.y - 0.009)
        )
        var recovery = CharacterRerollPixelGuardRecovery()
        #expect(evaluate(&recovery, observed: lowDecision(target: changed)) == .retry(attempt: 1))
    }

    @Test("Invalid pixel metrics cannot authorize retries or appear quiescent")
    func invalidMetricsAreSticky() {
        for invalid in [Double.nan, .infinity, -.infinity, -0.001] {
            let invalidSurface = CharacterRerollPixelGuardDifferences(inputSurface: invalid, result: 0)
            let invalidResult = CharacterRerollPixelGuardDifferences(inputSurface: 0.005, result: invalid)
            #expect(!invalidSurface.inputSurfaceIsQuiescent)
            #expect(!invalidResult.resultIsQuiescent)
            for differences in [invalidSurface, invalidResult] {
                var recovery = CharacterRerollPixelGuardRecovery()
                #expect(evaluate(&recovery, differences: differences) == .unsafe)
                #expect(evaluate(&recovery) == .unsafe)
            }
        }
    }

    private var target: CharacterRerollTarget {
        .init(sourceText: "隨機", rect: CharacterRerollDetector.measuredRandomButtonRect,
              point: CharacterRerollDetector.measuredRandomButtonPoint)
    }

    private struct LiveFixture: Decodable {
        struct Image: Decodable {
            let width: Int
            let height: Int
        }
        struct OCR: Decodable {
            let observations: [OCRTextObservation]
        }
        let image: Image
        let ocr: OCR
    }

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("DevelopmentFixtures", isDirectory: true)
            .appendingPathComponent("CharacterReroll", isDirectory: true)
            .appendingPathComponent(name)
    }

    private var surfaceOnlyChange: CharacterRerollPixelGuardDifferences {
        .init(inputSurface: 0.005, result: 0)
    }

    private func lowDecision(
        name: String = "JENNIE", total: Int = 67, target: CharacterRerollTarget? = nil
    ) -> CharacterRerollDecision {
        .rerollRequired(roll: .init(name: name, total: total), target: target ?? self.target)
    }

    private func evaluate(
        _ recovery: inout CharacterRerollPixelGuardRecovery,
        observed: CharacterRerollDecision? = nil,
        evidence: CharacterTotalBoundaryEvidence = .belowThreshold,
        differences: CharacterRerollPixelGuardDifferences? = nil
    ) -> CharacterRerollPixelGuardRecoveryDecision {
        recovery.evaluate(authorized: lowDecision(), observed: observed ?? lowDecision(),
                          boundaryEvidence: evidence, differences: differences ?? surfaceOnlyChange)
    }

    private func image(width: Int, height: Int) -> [UInt8] {
        var bytes = Array(repeating: UInt8(0), count: width * height * 4)
        for pixel in 0..<(width * height) { bytes[pixel * 4 + 3] = 255 }
        return bytes
    }

    private func paint(
        x: Int, y: Int, width: Int, height: Int, imageWidth: Int, bytes: inout [UInt8]
    ) {
        for row in y..<(y + height) {
            for column in x..<(x + width) {
                let offset = (row * imageWidth + column) * 4
                for channel in 0..<3 { bytes[offset + channel] = 255 }
            }
        }
    }
}
