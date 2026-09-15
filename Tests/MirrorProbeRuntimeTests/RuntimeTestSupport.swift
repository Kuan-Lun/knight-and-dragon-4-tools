import CoreGraphics
import Foundation
import Testing
@testable import MirrorProbeRuntime

struct RuntimeTestDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirror-probe-runtime-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

func runtimeTestImage() throws -> CGImage {
    let context = try #require(CGContext(
        data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 32 * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
    return try #require(context.makeImage())
}

func runtimeTestReport(directory: URL) -> AutomationRunReport {
    AutomationRunReport(
        schemaVersion: 5, recognitionMode: "visualRegions", sessionID: "runtime-test",
        status: "running", startedAt: "2026-09-15T00:00:00Z", endedAt: nil,
        window: WindowReport(
            windowID: 10, processID: 20, applicationName: "Fixture",
            bundleIdentifier: "test.fixture", title: "Fixture", x: 0, y: 0,
            width: 406, height: 890, onScreen: true, active: true
        ),
        talismanPolicy: "unrestricted", inputMode: .foreground, captureLevel: .error,
        limits: .init(maximumCycles: nil, maximumMinutes: nil, maximumActions: nil,
                      pollIntervalSeconds: 1.5),
        outputDirectory: directory.path, stopFile: directory.appendingPathComponent("STOP").path,
        completedCycles: 2, actionsPosted: 4, finalReason: nil,
        diagnosticScreenshots: [], diagnosticPersistenceErrors: [], events: []
    )
}
