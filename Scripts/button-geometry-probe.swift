#!/usr/bin/env swift

// Read-only prototype for detecting Knight & Dragon IV modal buttons without OCR.
// It only decodes existing PNG files; it does not capture, focus, or click anything.

import CoreGraphics
import Foundation
import ImageIO

private struct RGB {
    let r: Int
    let g: Int
    let b: Int

    func distance(to other: RGB) -> Double {
        let dr = Double(r - other.r)
        let dg = Double(g - other.g)
        let db = Double(b - other.b)
        return sqrt(dr * dr + dg * dg + db * db)
    }
}

private struct ProbeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private struct RGBAImage {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(path: String) throws {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw ProbeError("cannot decode PNG: \(path)") }

        let decodedWidth = image.width
        let decodedHeight = image.height
        let bytesPerRow = decodedWidth * 4
        var storage = [UInt8](repeating: 0, count: bytesPerRow * decodedHeight)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        let rendered = storage.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let address = rawBuffer.baseAddress,
                  let context = CGContext(
                    data: address,
                    width: decodedWidth,
                    height: decodedHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: bitmapInfo
                  )
            else { return false }
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: decodedWidth, height: decodedHeight)
            )
            return true
        }
        guard rendered else { throw ProbeError("cannot render PNG: \(path)") }
        width = decodedWidth
        height = decodedHeight
        bytes = storage
    }

    func pixel(x: Int, y: Int) -> RGB {
        let offset = (y * width + x) * 4
        return RGB(r: Int(bytes[offset]), g: Int(bytes[offset + 1]), b: Int(bytes[offset + 2]))
    }

    func rowEdgeIntervals(y: Int, threshold: Double = 20) -> [ClosedRange<Int>] {
        guard y > 0, y < height else { return [] }
        var ranges: [ClosedRange<Int>] = []
        var start: Int?
        for x in 0..<width {
            let edge = pixel(x: x, y: y).distance(to: pixel(x: x, y: y - 1))
            if edge >= threshold, start == nil {
                start = x
            } else if edge < threshold, let rangeStart = start {
                if x - rangeStart >= max(3, Int(round(Double(width) * 0.02))) {
                    ranges.append(rangeStart...(x - 1))
                }
                start = nil
            }
        }
        if let rangeStart = start,
           width - rangeStart >= max(3, Int(round(Double(width) * 0.02))) {
            ranges.append(rangeStart...(width - 1))
        }
        return ranges
    }
}

private struct PixelBand {
    let first: Int
    let last: Int
    var center: Double { (Double(first) + Double(last)) / 2 }
}

private struct NormalizedRectangle {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    var centerX: Double { x + width / 2 }
    var centerY: Double { y + height / 2 }
}

private enum ModalLayout: String {
    case none
    case oneButton
    case twoButtons
    case returnedPartyManualStop
    case unsupportedButtonCount
}

private struct GeometryResult {
    let buttons: [NormalizedRectangle]
    let dialog: NormalizedRectangle?
    let layout: ModalLayout
}

private func mergedBands(rows: [Int], maximumGap: Int) -> [PixelBand] {
    guard let first = rows.first else { return [] }
    var result: [PixelBand] = []
    var bandStart = first
    var previous = first
    for row in rows.dropFirst() {
        if row <= previous + maximumGap {
            previous = row
        } else {
            result.append(PixelBand(first: bandStart, last: previous))
            bandStart = row
            previous = row
        }
    }
    result.append(PixelBand(first: bandStart, last: previous))
    return result
}

private func isButtonWidthEdge(_ range: ClosedRange<Int>, imageWidth: Int) -> Bool {
    let left = Double(range.lowerBound) / Double(imageWidth)
    let right = Double(range.upperBound) / Double(imageWidth)
    let width = Double(range.count) / Double(imageWidth)
    return (0.105...0.114).contains(left)
        && (0.883...0.893).contains(right)
        && (0.770...0.790).contains(width)
}

private func sideEdgeCoverage(image: RGBAImage, top: Double, bottom: Double) -> Double {
    let inset = max(1, Int(round(Double(image.height) * 0.003)))
    let firstY = Int(ceil(top)) + inset
    let lastY = Int(floor(bottom)) - inset
    guard firstY <= lastY else { return 0 }
    let leftRange = Int(floor(Double(image.width) * 0.102))...Int(ceil(Double(image.width) * 0.130))
    let rightRange = Int(floor(Double(image.width) * 0.870))...Int(ceil(Double(image.width) * 0.900))
    var bothSides = 0
    var rowCount = 0
    for y in firstY...lastY {
        let leftEdge = leftRange.map { x in
            image.pixel(x: x, y: y).distance(to: image.pixel(x: x - 1, y: y))
        }.max() ?? 0
        let rightEdge = rightRange.map { x in
            image.pixel(x: x, y: y).distance(to: image.pixel(x: x - 1, y: y))
        }.max() ?? 0
        if leftEdge >= 20, rightEdge >= 20 { bothSides += 1 }
        rowCount += 1
    }
    return rowCount == 0 ? 0 : Double(bothSides) / Double(rowCount)
}

// The defeat popup overlays the retreat confirmation. Its horizontal frame crosses the
// apparent lower rectangle, proving that the visible background "No" is not a foreground row.
private func hasForegroundFrameInside(image: RGBAImage, top: Double, bottom: Double) -> Bool {
    let inset = max(1, Int(round(Double(image.height) * 0.004)))
    let firstY = Int(ceil(top)) + inset
    let lastY = Int(floor(bottom)) - inset
    guard firstY <= lastY else { return false }
    for y in firstY...lastY {
        for range in image.rowEdgeIntervals(y: y) {
            let left = Double(range.lowerBound) / Double(image.width)
            let right = Double(range.upperBound) / Double(image.width)
            let width = Double(range.count) / Double(image.width)
            if (0.135...0.250).contains(left),
               (0.785...0.865).contains(right),
               (0.540...0.730).contains(width) {
                return true
            }
        }
    }
    return false
}

private func isDialogEdgeRow(image: RGBAImage, y: Int) -> Bool {
    let firstX = Int(round(Double(image.width) * 0.081))
    let lastX = Int(round(Double(image.width) * 0.916))
    let leftWing = Int(round(Double(image.width) * 0.073))...Int(round(Double(image.width) * 0.111))
    let rightWing = Int(round(Double(image.width) * 0.889))...Int(round(Double(image.width) * 0.924))
    var strong = 0
    for x in firstX...lastX where
        image.pixel(x: x, y: y).distance(to: image.pixel(x: x, y: y - 1)) >= 20 {
        strong += 1
    }
    let leftCount = leftWing.filter { x in
        image.pixel(x: x, y: y).distance(to: image.pixel(x: x, y: y - 1)) >= 20
    }.count
    let rightCount = rightWing.filter { x in
        image.pixel(x: x, y: y).distance(to: image.pixel(x: x, y: y - 1)) >= 20
    }.count
    return Double(strong) / Double(lastX - firstX + 1) >= 0.78
        && leftCount >= 6 && rightCount >= 6
}

private func inferDialog(
    image: RGBAImage,
    buttons: [NormalizedRectangle],
    buttonEdges: [PixelBand]
) -> NormalizedRectangle? {
    guard let firstButton = buttons.first, let lastButton = buttons.last else { return nil }
    let firstTop = firstButton.y * Double(image.height)
    let lastBottom = (lastButton.y + lastButton.height) * Double(image.height)
    let frameStart = max(1, Int(Double(image.height) * 0.18))
    let frameEnd = min(image.height, Int(Double(image.height) * 0.75))
    let frameRows = (frameStart..<frameEnd).filter {
        isDialogEdgeRow(image: image, y: $0)
    }
    let frameBands = mergedBands(
        rows: frameRows,
        maximumGap: max(1, Int(round(Double(image.height) * 0.003)))
    ).filter { frameBand in
        !buttonEdges.contains { buttonBand in
            frameBand.first <= buttonBand.last + 1 && frameBand.last + 1 >= buttonBand.first
        }
    }
    let clearance = Double(image.height) * 0.005
    guard let top = frameBands.last(where: { $0.center < firstTop - clearance }),
          let bottom = frameBands.first(where: { $0.center > lastBottom + clearance })
    else { return nil }
    return NormalizedRectangle(
        x: 0.081,
        y: top.center / Double(image.height),
        width: 0.835,
        height: (bottom.center - top.center) / Double(image.height)
    )
}

private func detectGeometry(in image: RGBAImage) -> GeometryResult {
    let scanStart = max(1, Int(Double(image.height) * 0.30))
    let scanEnd = min(image.height - 1, Int(Double(image.height) * 0.72))
    let rows = (scanStart...scanEnd).filter { y in
        image.rowEdgeIntervals(y: y).contains {
            isButtonWidthEdge($0, imageWidth: image.width)
        }
    }
    let edges = mergedBands(
        rows: rows,
        maximumGap: max(1, Int(round(Double(image.height) * 0.003)))
    )
    var buttons: [NormalizedRectangle] = []
    for index in 0..<max(0, edges.count - 1) {
        let top = edges[index].center
        let bottom = edges[index + 1].center
        let height = (bottom - top) / Double(image.height)
        guard (0.032...0.049).contains(height),
              sideEdgeCoverage(image: image, top: top, bottom: bottom) >= 0.90,
              !hasForegroundFrameInside(image: image, top: top, bottom: bottom)
        else { continue }
        buttons.append(NormalizedRectangle(
            x: 0.108,
            y: top / Double(image.height),
            width: 0.783,
            height: height
        ))
    }

    let dialog = inferDialog(image: image, buttons: buttons, buttonEdges: edges)
    let layout: ModalLayout
    if buttons.isEmpty {
        layout = .none
    } else if buttons.count == 2 {
        layout = .twoButtons
    } else if buttons.count == 1 {
        layout = .oneButton
    } else {
        layout = .unsupportedButtonCount
    }
    return GeometryResult(buttons: buttons, dialog: dialog, layout: layout)
}

private struct Fixture {
    let path: String
    let buttons: Int
    let layout: ModalLayout?
}

private let expectedCorpusSampleCount = 168
private let corpusRelativePath = "DevelopmentFixtures/ButtonGeometryCorpus"

private func fixtureCorpus(root: URL) throws -> [Fixture] {
    let explicit = [
        Fixture(path: "captures/0.3.8-loot-modal-current.png", buttons: 2, layout: .twoButtons),
        Fixture(path: "captures/cleanup-retreat-confirmation.png", buttons: 2, layout: .twoButtons),
        Fixture(path: "captures/live-before-leave.png", buttons: 2, layout: .twoButtons),
        Fixture(path: "captures/live-battle-intro-close/before.png", buttons: 1, layout: .oneButton),
        Fixture(path: "captures/cleanup-defeat-prompt.png", buttons: 1, layout: .oneButton),
        Fixture(path: "captures/three-cycle-default-auto-20260903-224200/final.png",
                buttons: 1, layout: .oneButton),
        Fixture(path: "captures/live-battle-auto/before.png", buttons: 0, layout: ModalLayout.none),
        Fixture(path: "captures/three-cycle-0.3.6-20260904-022534/frames/"
                + "action-0005-advanceMissionSuccess-after.png", buttons: 0, layout: ModalLayout.none),
        Fixture(path: "captures/live-recruit-leave/before.png", buttons: 2, layout: .twoButtons),
        Fixture(path: "captures/natural-defeat-retreat-confirm-yes-authorized/before.png",
                buttons: 2, layout: .twoButtons),
        Fixture(path: "captures/live-repeat3-retreat-confirm-yes-authorized/before.png",
                buttons: 2, layout: .twoButtons),
        Fixture(path: "captures/live-retreat-cancel/before.png", buttons: 2, layout: .twoButtons),
        Fixture(path: "captures/live-defeat-prompt-close/before.png", buttons: 1, layout: .oneButton),
        Fixture(path: "captures/natural-defeat-prompt-close/before.png", buttons: 1, layout: .oneButton),
        Fixture(path: "captures/live-battle-event-close/before.png", buttons: 1, layout: .oneButton),
        Fixture(path: "captures/auto-level-20260904-035046.G5TL46/final.png",
                buttons: 1, layout: .oneButton),
        Fixture(path: "captures/natural-defeat-current-0.3.5.png", buttons: 0, layout: ModalLayout.none),
        Fixture(path: "captures/natural-defeat-observe-01.png", buttons: 1, layout: .oneButton),
        Fixture(path: "captures/live-repeat2-exp-next/before.png", buttons: 0, layout: ModalLayout.none),
        Fixture(path: "captures/live-repeat2-loot-next/before.png", buttons: 0, layout: ModalLayout.none),
        Fixture(path: "captures/live-failure-select-repeat/before.png", buttons: 0, layout: ModalLayout.none),
    ]
    let capturesURL = root.appendingPathComponent("captures", isDirectory: true)
    guard let enumerator = FileManager.default.enumerator(
        at: capturesURL,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    ) else { throw ProbeError("cannot enumerate fixture corpus: \(capturesURL.path)") }
    var fixtures = Dictionary(uniqueKeysWithValues: explicit.map { ($0.path, $0) })
    while let url = enumerator.nextObject() as? URL {
        guard url.pathExtension.lowercased() == "png" else { continue }
        let relative = "captures/" + url.path.replacingOccurrences(
            of: capturesURL.path + "/",
            with: ""
        )
        let expected: Int?
        if relative.contains("confirmLootCollection-before.png") {
            expected = 2
        } else if relative.contains("closeBattlePrompt-before.png") {
            expected = 1
        } else if relative.contains("advanceMissionSuccess-before.png")
                    || relative.contains("advanceMissionFailure-before.png")
                    || relative.contains("selectMissionRepeat-before.png")
                    || relative.contains("enableAllAuto-before.png") {
            expected = 0
        } else {
            expected = nil
        }
        if let expected, fixtures[relative] == nil {
            fixtures[relative] = Fixture(
                path: relative,
                buttons: expected,
                layout: expected == 0 ? ModalLayout.none : nil
            )
        }
    }
    let sortedFixtures = fixtures.values.sorted { $0.path < $1.path }
    guard sortedFixtures.count == expectedCorpusSampleCount else {
        throw ProbeError(
            "expected \(expectedCorpusSampleCount) button-geometry fixtures in "
                + "\(root.path), found \(sortedFixtures.count)"
        )
    }
    return sortedFixtures
}

private func printResult(path: String, result: GeometryResult) {
    print("\(path): buttons=\(result.buttons.count) layout=\(result.layout.rawValue)")
    for (index, button) in result.buttons.enumerated() {
        print(String(
            format: "  [%d] rect=(%.4f,%.4f,%.4f,%.4f) center=(%.4f,%.4f)",
            index + 1, button.x, button.y, button.width, button.height,
            button.centerX, button.centerY
        ))
    }
    if let dialog = result.dialog {
        print(String(format: "  dialog=(%.4f,%.4f,%.4f,%.4f)",
                     dialog.x, dialog.y, dialog.width, dialog.height))
    }
}

private func runCorpus(root: URL) throws -> Bool {
    let fixtures = try fixtureCorpus(root: root)
    var exact = 0
    var detectedButtons = 0
    var expectedButtons = 0
    var zeroExact = 0
    var zeroCount = 0
    var layoutExact = 0
    var layoutCount = 0
    for fixture in fixtures {
        let path = root.appendingPathComponent(fixture.path).path
        guard FileManager.default.fileExists(atPath: path) else {
            throw ProbeError("missing button-geometry fixture: \(path)")
        }
        let result = detectGeometry(in: try RGBAImage(path: path))
        let countOK = result.buttons.count == fixture.buttons
        let layoutOK = fixture.layout.map { result.layout == $0 } ?? true
        print("\(countOK && layoutOK ? "PASS" : "FAIL") expected=\(fixture.buttons) "
              + "actual=\(result.buttons.count) layout=\(result.layout.rawValue) \(fixture.path)")
        if countOK { exact += 1 }
        detectedButtons += result.buttons.count
        expectedButtons += fixture.buttons
        if fixture.buttons == 0 {
            zeroCount += 1
            if result.buttons.isEmpty { zeroExact += 1 }
        }
        if let expectedLayout = fixture.layout {
            layoutCount += 1
            if result.layout == expectedLayout { layoutExact += 1 }
        }
    }
    print("\ncorpus samples=\(fixtures.count)")
    print("exact button-count=\(exact)/\(fixtures.count)")
    print("detected buttons=\(detectedButtons), expected buttons=\(expectedButtons)")
    print("zero-button false-positive-free=\(zeroExact)/\(zeroCount)")
    print("explicit layout checks=\(layoutExact)/\(layoutCount)")
    return exact == fixtures.count && layoutExact == layoutCount
}

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    if arguments == ["--corpus"] {
        let corpusRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(corpusRelativePath, isDirectory: true)
        exit(try runCorpus(root: corpusRoot) ? 0 : 1)
    }
    guard !arguments.isEmpty else {
        throw ProbeError("usage: button-geometry-probe.swift --corpus | IMAGE ...")
    }
    for path in arguments {
        printResult(path: path, result: detectGeometry(in: try RGBAImage(path: path)))
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(2)
}
