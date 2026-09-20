import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import MirrorProbeCore

@Suite("Repeat-selected stamp detector")
struct RepeatSelectedStampDetectorTests {
    @Test("Live result images distinguish the fixed red stamp without reading its word")
    func liveSelectedAndUnselectedImages() throws {
        for resourceName in [
            "mission-result-no-modal.png",
            "mission-repeat-selected-srlected.png",
        ] {
            let detection = try detect(resourceName)
            #expect(detection.isPresent, Comment(rawValue: resourceName))
            #expect(!detection.isClearlyAbsent, Comment(rawValue: resourceName))
            #expect(detection.redPixelRatio > 0.10, Comment(rawValue: resourceName))
        }

        let unselected = try detect("mission-repeat-unselected.png")
        #expect(!unselected.isPresent)
        #expect(unselected.isClearlyAbsent)
        #expect(unselected.redPixelRatio < 0.005)
    }

    @Test("The live unselected loot page excludes the first item row from stamp evidence")
    func liveUnselectedLootExcludesItemText() throws {
        let detection = try detect("visual-result-live-unselected-loot.png")
        #expect(detection.redPixelCount == 0)
        #expect(detection.isClearlyAbsent)
        #expect(!detection.isPresent)
    }

    @Test("Red dynamic item rows below the repeat control cannot count as selection ink",
          arguments: [1, 2])
    func dynamicItemInkIsExcluded(scale: Int) throws {
        let width = 406 * scale, height = 890 * scale
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in Int(ceil(0.26 * Double(height)))..<Int(ceil(0.28 * Double(height))) {
            for x in Int(0.33 * Double(width))..<Int(ceil(0.70 * Double(width))) {
                let offset = (y * width + x) * 4
                bytes.replaceSubrange(offset..<(offset + 4), with: [180, 85, 75, 255])
            }
        }
        let detection = try RepeatSelectedStampDetector.detectRGBA(
            bytes, width: width, height: height, bytesPerRow: width * 4
        )
        #expect(detection.redPixelCount == 0)
        #expect(detection.isClearlyAbsent)
        #expect(!detection.isPresent)
    }

    @Test("A scrolled list moves the stamp area by the recorded offset", arguments: [1, 2])
    func stampAreaFollowsListOffset(scale: Int) throws {
        let width = 406 * scale, height = 890 * scale
        let offset = -0.03
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        // Ink exactly where the stamp sits on a list scrolled up by the offset.
        let region = RepeatSelectedStampDetector.measuredRegion(listOffset: offset)
        for y in Int(ceil(region.y * Double(height)))..<Int(floor((region.y + region.height) * Double(height))) {
            for x in Int(ceil(region.x * Double(width)))..<Int(floor((region.x + region.width) * Double(width))) {
                let index = (y * width + x) * 4
                bytes.replaceSubrange(index..<(index + 4), with: [200, 40, 40, 255])
            }
        }
        let shifted = try RepeatSelectedStampDetector.detectRGBA(
            bytes, width: width, height: height, bytesPerRow: width * 4, listOffset: offset
        )
        #expect(shifted.isValid && shifted.isPresent && shifted.listOffset == offset)
        #expect(shifted.region == region)
        let fixed = try RepeatSelectedStampDetector.detectRGBA(
            bytes, width: width, height: height, bytesPerRow: width * 4
        )
        #expect(fixed.isValid && fixed.listOffset == 0)
        #expect(fixed.region == RepeatSelectedStampDetector.measuredRegion)
        #expect(fixed.redPixelRatio < shifted.redPixelRatio)
        #expect(throws: RepeatSelectedStampDetectorError.invalidListOffset) {
            try RepeatSelectedStampDetector.detectRGBA(
                bytes, width: width, height: height, bytesPerRow: width * 4, listOffset: -0.05
            )
        }
        // A detection cannot claim a region that does not belong to its offset.
        #expect(!RepeatSelectedStampDetection(
            region: region, redPixelCount: 1, sampledPixelCount: 10, listOffset: 0
        ).isValid)
        #expect(!RepeatSelectedStampDetection(
            region: RepeatSelectedStampDetector.measuredRegion, redPixelCount: 1,
            sampledPixelCount: 10, listOffset: offset
        ).isValid)
    }

    @Test("Brown separator shades cannot become selection ink as capture colors fluctuate")
    func brownSeparatorHueIsExcluded() throws {
        // All these pixels were counted by the old red-channel cutoff in the 00:56 preflight.
        for color in [
            [152, 134, 118, 255],
            [164, 146, 131, 255],
            [156, 137, 121, 255],
            [126, 106, 88, 255],
            [147, 127, 112, 255],
            [144, 126, 111, 255],
            [161, 142, 126, 255],
            [133, 114, 94, 255],
            [143, 125, 110, 255],
        ] as [[UInt8]] {
            let detection = try syntheticDetection(background: color)
            #expect(detection.redPixelCount == 0)
            #expect(detection.isClearlyAbsent)
            #expect(!detection.isPresent)
        }
    }

    @Test("Red ink survives background blending while a partial stamp remains ambiguous")
    func redInkHuePreservesFadedAndPartialStamps() throws {
        for color in [
            [180, 85, 75, 255],
            [180, 157, 150, 255],
        ] as [[UInt8]] {
            let selected = try syntheticDetection(ink: color, inkPixelCount: 20)
            #expect(selected.redPixelCount == 20)
            #expect(selected.isPresent)
            #expect(!selected.isClearlyAbsent)

            let partial = try syntheticDetection(ink: color, inkPixelCount: 3)
            #expect(partial.redPixelCount == 3)
            #expect(!partial.isPresent)
            #expect(!partial.isClearlyAbsent)
        }
    }

    @Test("Clear absence uses a separate noise allowance and rejects partial stamp pixels")
    func absenceUsesStrictSeparateThreshold() {
        for count in [0, 1] {
            let detection = pixelDetection(redPixelCount: count)
            #expect(detection.isClearlyAbsent)
            #expect(!detection.isPresent)
        }
        for count in [2, 39] {
            let detection = pixelDetection(redPixelCount: count)
            #expect(!detection.isClearlyAbsent)
            #expect(!detection.isPresent)
            for selectedText in [nil, "SELECTED"] as [String?] {
                let result = GameStateClassifier.classify(
                    observations: liveResultObservations(selectedText: selectedText),
                    repeatSelectedStampDetection: detection
                )
                #expect(result.state == .unknown)
                #expect(result.allowedActions.isEmpty)
                #expect(!result.evidence.contains { $0.kind == .repeatUnselectedMarker })
                #expect(result.evidence.contains { $0.kind == .lowConfidenceMarker })
                #expect(!result.evidence.contains { $0.kind == .conflictingStateMarkers })
            }
        }
        #expect(pixelDetection(redPixelCount: 40).isPresent)
        #expect(!pixelDetection(redPixelCount: -1).isClearlyAbsent)
        #expect(!RepeatSelectedStampDetection(
            region: RepeatSelectedStampDetector.measuredRegion,
            redPixelCount: 0,
            sampledPixelCount: 0
        ).isClearlyAbsent)
    }

    @Test("Unselected success and failure pages retain trusted page identity and pixel proof")
    func clearAbsenceRequiresPageScaffold() throws {
        let detection = try detect("mission-repeat-unselected.png")
        for (title, state) in [
            ("任務完成！", GameState.missionComplete),
            ("任務失敗", GameState.missionFailed),
        ] {
            for (page, identity) in [
                ("獲得經驗值", MissionSuccessPageIdentity.experience),
                ("獲得拾得物", MissionSuccessPageIdentity.loot),
            ] {
                var observations = liveResultObservations(selectedText: nil)
                observations[0] = observation(title, observations[0].rect, confidence: 1)
                observations[1] = observation(page, observations[1].rect, confidence: 1)
                let result = GameStateClassifier.classify(
                    observations: observations,
                    repeatSelectedStampDetection: detection
                )
                #expect(result.state == state)
                #expect(result.allowedActions.map(\.name) == [.selectMissionRepeat])
                #expect(MissionSuccessPageIdentity.resolve(in: result) == identity)
                let proof = result.evidence.filter { $0.kind == .repeatUnselectedMarker }
                #expect(proof.count == 1)
                #expect(proof.first?.observation == nil)
                #expect(proof.first?.detail == RepeatSelectedStampDetector.absentEvidenceSentinel)
                #expect(!result.evidence.contains { $0.kind == .repeatSelectedMarker })
            }
        }
    }

    @Test("Unselected proof is absent without pixels or a unique trusted result scaffold")
    func incompleteScaffoldCannotProveAbsence() throws {
        let detection = try detect("mission-repeat-unselected.png")
        let base = liveResultObservations(selectedText: nil)
        let noPixels = GameStateClassifier.classify(observations: base)
        #expect(!noPixels.evidence.contains { $0.kind == .repeatUnselectedMarker })

        var lowConfidence = base
        lowConfidence[1] = observation("獲得經驗值", base[1].rect, confidence: 0.59)
        var misplaced = base
        misplaced[1] = observation("獲得經驗值", rect(0.10, 0.60, 0.20, 0.02), confidence: 1)
        for observations in [
            base.filter { $0.text != "獲得經驗值" },
            base + [base[1]],
            lowConfidence,
            misplaced,
            base.filter { $0.text != "重複進行此任務" },
            base + [base[3]],
        ] {
            let result = GameStateClassifier.classify(
                observations: observations,
                repeatSelectedStampDetection: detection
            )
            #expect(!result.evidence.contains { $0.kind == .repeatUnselectedMarker })
        }
    }

    @Test("The exact SRLECTED frame resolves to selected and only the upper continuation")
    func liveSRLECTEDFrameIntegration() throws {
        let detection = try detect("mission-repeat-selected-srlected.png")
        for selectedText in ["SRLECTED", nil] as [String?] {
            let observations = liveResultObservations(selectedText: selectedText)
            let classified = GameStateClassifier.classify(
                observations: observations,
                repeatSelectedStampDetection: detection
            )
            let resolved = MissionResultTopActionResolver.resolve(classification: classified)

            #expect(classified.state == .missionCompleteRepeatSelected)
            #expect(classified.evidence.filter { $0.kind == .repeatSelectedMarker }.count == 1)
            #expect(!classified.evidence.contains { $0.kind == .repeatUnselectedMarker })
            #expect(
                classified.evidence.first { $0.kind == .repeatSelectedMarker }?.observation == nil
            )
            #expect(resolved.allowedActions.map(\.name) == [.advanceMissionComplete])
            #expect(
                resolved.allowedActions.first?.target.rect
                    == MissionResultTopActionResolver.measuredTopAdvanceRect
            )
        }
    }

    @Test("An empty measured stamp region wins safely over hallucinated SELECTED OCR")
    func absentPixelsRejectSelectedOCR() throws {
        let detection = try detect("mission-repeat-unselected.png")
        for confidence in [0.30, 0.29] {
            let result = GameStateClassifier.classify(
                observations: liveResultObservations(
                    selectedText: "SELECTED",
                    selectedConfidence: confidence
                ),
                repeatSelectedStampDetection: detection
            )

            #expect(result.state == .unknown)
            #expect(result.allowedActions.isEmpty)
            #expect(result.evidence.contains {
                $0.kind == .conflictingStateMarkers || $0.kind == .lowConfidenceMarker
            })
        }
    }

    @Test("Red pixels cannot promote a non-result screen")
    func redPixelsRequireResultScaffold() throws {
        let detection = try detect("mission-repeat-selected-srlected.png")
        let autoRect = rect(0.23, 0.86, 0.14, 0.03)
        let result = GameStateClassifier.classify(
            observations: [
                observation(
                    "西部森林 跨河橋 -第1場戰鬥-",
                    rect(0.20, 0.05, 0.60, 0.04),
                    confidence: 1
                ),
                observation("戰利品 0", rect(0.70, 0.10, 0.20, 0.04), confidence: 1),
                observation("全部自動", autoRect, confidence: 1),
            ],
            repeatSelectedStampDetection: detection
        )

        #expect(result.state == .battle)
        #expect(result.allowedActions.map(\.name) == [.enableAutoBattle])
        #expect(!result.evidence.contains { $0.kind == .repeatSelectedMarker })
    }

    @Test("Invalid dimensions and short buffers are rejected")
    func invalidBuffer() {
        #expect(throws: RepeatSelectedStampDetectorError.invalidDimensions) {
            try RepeatSelectedStampDetector.detectRGBA(
                [],
                width: 0,
                height: 1,
                bytesPerRow: 0
            )
        }
        #expect(throws: RepeatSelectedStampDetectorError.insufficientBytes) {
            try RepeatSelectedStampDetector.detectRGBA(
                [UInt8](repeating: 0, count: 79),
                width: 10,
                height: 2,
                bytesPerRow: 40
            )
        }
    }

    private func liveResultObservations(
        selectedText: String?,
        selectedConfidence: Double = 0.3000000119
    ) -> [OCRTextObservation] {
        var observations = [
            observation(
                "任務完成！",
                rect(0.3888822077, 0.1050546263, 0.2123833642, 0.0235986142),
                confidence: 1
            ),
            observation(
                "獲得經驗值",
                rect(0.7782544879, 0.1459268601, 0.1922595019, 0.0205058301),
                confidence: 1
            ),
            observation(
                ">>",
                rect(0.0246305439, 0.1977528088, 0.0443349754, 0.0112359551),
                confidence: 0.30
            ),
            observation(
                "重複進行此任務",
                rect(0.0246305439, 0.2359550561, 0.2857142857, 0.0202247191),
                confidence: 1
            ),
        ]
        if let selectedText {
            observations.append(observation(
                selectedText,
                rect(0.3654538467, 0.2210404554, 0.2651170815, 0.0389866561),
                confidence: selectedConfidence
            ))
        }
        return observations
    }

    private func observation(
        _ text: String,
        _ rect: NormalizedRect,
        confidence: Double
    ) -> OCRTextObservation {
        OCRTextObservation(text: text, rect: rect, confidence: confidence)
    }

    private func rect(
        _ x: Double,
        _ y: Double,
        _ width: Double,
        _ height: Double
    ) -> NormalizedRect {
        NormalizedRect(x: x, y: y, width: width, height: height)
    }

    private func detect(_ resourceName: String) throws -> RepeatSelectedStampDetection {
        let image = try loadPNG(resourceName)
        return try RepeatSelectedStampDetector.detectRGBA(
            image.bytes,
            width: image.width,
            height: image.height,
            bytesPerRow: image.bytesPerRow
        )
    }

    private func pixelDetection(redPixelCount: Int) -> RepeatSelectedStampDetection {
        RepeatSelectedStampDetection(
            region: RepeatSelectedStampDetector.measuredRegion,
            redPixelCount: redPixelCount,
            sampledPixelCount: 1_000
        )
    }

    private func syntheticDetection(
        background: [UInt8] = [126, 106, 88, 255],
        ink: [UInt8] = [180, 85, 75, 255],
        inkPixelCount: Int = 0
    ) throws -> RepeatSelectedStampDetection {
        let width = 100
        let height = 100
        var bytes = Array(repeating: background, count: width * height).flatMap { $0 }
        // A short row inside the measured region permits both selected and partial coverage.
        for x in 40..<(40 + inkPixelCount) {
            let offset = (22 * width + x) * 4
            bytes.replaceSubrange(offset..<(offset + 4), with: ink)
        }
        return try RepeatSelectedStampDetector.detectRGBA(
            bytes,
            width: width,
            height: height,
            bytesPerRow: width * 4
        )
    }

    private func loadPNG(_ resourceName: String) throws -> StampLoadedRGBA {
        guard let url = Bundle.module.url(forResource: resourceName, withExtension: nil) else {
            throw StampTestImageError.missingResource(resourceName)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw StampTestImageError.cannotDecode(url.path)
        }

        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let address = buffer.baseAddress,
                  let context = CGContext(
                    data: address,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: bitmapInfo
                  )
            else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { throw StampTestImageError.cannotRender(url.path) }
        return StampLoadedRGBA(
            bytes: bytes,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow
        )
    }
}

private struct StampLoadedRGBA {
    let bytes: [UInt8]
    let width: Int
    let height: Int
    let bytesPerRow: Int
}

private enum StampTestImageError: Error {
    case missingResource(String)
    case cannotDecode(String)
    case cannotRender(String)
}
