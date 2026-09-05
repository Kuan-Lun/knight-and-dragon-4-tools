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
            #expect(detection.redPixelRatio > 0.10, Comment(rawValue: resourceName))
        }

        let unselected = try detect("mission-repeat-unselected.png")
        #expect(!unselected.isPresent)
        #expect(unselected.redPixelRatio < 0.005)
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
