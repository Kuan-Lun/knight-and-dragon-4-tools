import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import MirrorProbeCore

@Suite("WideModalButtonDetector")
struct WideModalButtonDetectorTests {
    @Test("Live two-button modal fixtures expose two ordered rows")
    func twoButtonLiveFixtures() throws {
        for resourceName in [
            "loot-two-buttons.png",
            "retreat-two-buttons.png",
            "adventurer-two-buttons.png",
            "adventurer-two-buttons-colin.png",
        ] {
            let result = try detect(resourceName)
            #expect(result.layout == .twoButtons, Comment(rawValue: resourceName))
            #expect(result.buttons.count == 2, Comment(rawValue: resourceName))
            #expect(result.buttons[0].rect.center.y < result.buttons[1].rect.center.y)
            #expect(result.buttons.allSatisfy { $0.rect.isValid })

            let resolved = WideModalActionResolver.resolve(
                classification: GameStateClassification(
                    state: .adventurerRecruitment,
                    evidence: [],
                    allowedActions: []
                ),
                detection: result
            )
            #expect(resolved.state == .wideModalTwoButtons, Comment(rawValue: resourceName))
            #expect(
                resolved.allowedActions.map(\.name) == [.pressWideModalTopButton],
                Comment(rawValue: resourceName)
            )
            #expect(
                resolved.allowedActions.first?.target.rect == result.buttons[0].rect,
                Comment(rawValue: resourceName)
            )
        }
    }

    @Test("Live one-button modal fixtures expose only their foreground row")
    func oneButtonLiveFixtures() throws {
        for resourceName in [
            "battle-intro-one-button.png",
            "battle-event-one-button.png",
            "defeat-one-button.png",
            "battle-prompt-one-button-alt.png",
            "mission-skill-acquired-one-button.png",
            "returned-party-manual-stop.png",
        ] {
            let result = try detect(resourceName)
            #expect(result.layout == .oneButton, Comment(rawValue: resourceName))
            #expect(result.buttons.count == 1, Comment(rawValue: resourceName))
            #expect(result.buttons[0].rect.isValid)
        }
    }

    @Test("Battle and result pages do not produce modal buttons")
    func negativeLiveFixtures() throws {
        for resourceName in [
            "battle-no-modal.png",
            "active-battle-control-grid.png",
            "active-battle-low-retreat-grid.png",
            "mission-result-no-modal.png",
        ] {
            let result = try detect(resourceName)
            #expect(result.layout == .none, Comment(rawValue: resourceName))
            #expect(result.buttons.isEmpty, Comment(rawValue: resourceName))
            #expect(result.dialogRect == nil)
        }
    }

    @Test("Invalid dimensions and short buffers are rejected")
    func invalidBuffer() {
        #expect(throws: WideModalButtonDetectorError.invalidDimensions) {
            try WideModalButtonDetector.detectRGBA([], width: 0, height: 1, bytesPerRow: 0)
        }
        #expect(throws: WideModalButtonDetectorError.invalidDimensions) {
            try WideModalButtonDetector.detectRGBA(
                [UInt8](repeating: 0, count: 16),
                width: 2,
                height: 2,
                bytesPerRow: 8
            )
        }
        #expect(throws: WideModalButtonDetectorError.insufficientBytes) {
            try WideModalButtonDetector.detectRGBA(
                [UInt8](repeating: 0, count: 79),
                width: 10,
                height: 2,
                bytesPerRow: 40
            )
        }
    }

    private func detect(_ resourceName: String) throws -> WideModalButtonDetection {
        let image = try loadPNG(resourceName)
        return try WideModalButtonDetector.detectRGBA(
            image.bytes,
            width: image.width,
            height: image.height,
            bytesPerRow: image.bytesPerRow
        )
    }

    private func loadPNG(_ resourceName: String) throws -> LoadedRGBA {
        guard let url = Bundle.module.url(forResource: resourceName, withExtension: nil) else {
            throw TestImageError.missingResource(resourceName)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw TestImageError.cannotDecode(url.path)
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
        guard rendered else { throw TestImageError.cannotRender(url.path) }
        return LoadedRGBA(bytes: bytes, width: width, height: height, bytesPerRow: bytesPerRow)
    }
}

private struct LoadedRGBA {
    let bytes: [UInt8]
    let width: Int
    let height: Int
    let bytesPerRow: Int
}

private enum TestImageError: Error {
    case missingResource(String)
    case cannotDecode(String)
    case cannotRender(String)
}
