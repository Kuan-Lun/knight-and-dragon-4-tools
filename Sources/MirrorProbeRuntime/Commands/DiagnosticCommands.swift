import AppKit
import CoreGraphics
import Foundation
import MirrorProbeCore

extension MirrorProbeRuntime {
    static func doctor(_ arguments: [String]) async throws {
        try validateOptions(
            arguments,
            valueOptions: ["--output"],
            flagOptions: ["--request-permissions"]
        )
        let requestPermissions = arguments.contains("--request-permissions")
        var screenGranted = CGPreflightScreenCaptureAccess()
        var postEventGranted = CGPreflightPostEventAccess()

        if requestPermissions {
            if !screenGranted {
                _ = CGRequestScreenCaptureAccess()
            }
            if !postEventGranted {
                _ = CGRequestPostEventAccess()
            }
            if !screenGranted || !postEventGranted {
                print("Permission requests were sent. Complete the macOS prompts; this probe will wait 30 seconds.")
                try await Task.sleep(for: .seconds(30))
                screenGranted = CGPreflightScreenCaptureAccess()
                postEventGranted = CGPreflightPostEventAccess()
            }
        }

        let windows = screenGranted ? try await mirrorWindows().map(windowReport) : []
        let nextStep: String?
        if !screenGranted || !postEventGranted {
            nextStep = requestPermissions
                ? "Grant missing permissions in System Settings, quit this probe, and run doctor again."
                : "Run doctor --request-permissions."
        } else if windows.isEmpty {
            nextStep = "Open iPhone Mirroring, connect the iPhone, and keep the window visible."
        } else {
            nextStep = nil
        }

        let report = DoctorReport(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            screenCapturePermission: screenGranted ? "granted" : "missing",
            postEventPermission: postEventGranted ? "granted" : "missing",
            windows: windows,
            nextStep: nextStep
        )
        try printJSON(report)

        if let output = option("--output", in: arguments) {
            let outputURL = try outputURL(for: output)
            try writeJSON(report, to: outputURL)
        }
    }

    /// Exercises activation and restoration through the packaged app's real TCC identity.
    /// It never posts mouse/keyboard events or advances the game.
    static func focusCheckCommand(_ arguments: [String]) async throws {
        try validateOptions(
            arguments, valueOptions: ["--window-id", "--output"]
        )
        try ensureScreenCapturePermission()
        try ensurePostEventPermission()
        let window = try await selectMirrorWindow(requestedID: optionalWindowID(arguments))
        guard let processID = window.owningApplication?.processID,
              let target = NSRunningApplication(processIdentifier: processID)
        else {
            throw ProbeError.unsafeWindow("could not resolve iPhone Mirroring for focus check")
        }
        let lock = try AutoLevelWindowRunLock.acquire(
            for: AutoLevelWindowIdentity(processID: processID, windowID: window.windowID)
        )
        defer { lock.release() }
        guard var focusBorrow = ForegroundFocusBorrow(targetProcessID: processID) else {
            throw ProbeError.unsafeWindow("the current focused application is unavailable")
        }
        let previousProcessID = focusBorrow.previousProcessID
        defer { focusBorrow.restore() }
        let activation = ForegroundApplicationActivation.request(
            target, options: [.activateAllWindows], expectedCurrentProcessID: previousProcessID
        )
        try await Task.sleep(for: .milliseconds(350))
        let afterActivation = ForegroundApplicationFocus.currentApplication?.processIdentifier
        let restoration = focusBorrow.restore()
        try await Task.sleep(for: .milliseconds(350))
        let afterRestoration = ForegroundApplicationFocus.currentApplication?.processIdentifier
        let report = FocusCheckReport(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            windowID: window.windowID,
            previousProcessID: previousProcessID,
            targetProcessID: processID,
            activation: activation,
            frontmostProcessIDAfterActivation: afterActivation,
            restoration: restoration,
            frontmostProcessIDAfterRestoration: afterRestoration,
            targetFocusVerified: afterActivation == processID,
            restorationVerified: previousProcessID != processID
                && restoration?.accepted == true
                && afterRestoration == previousProcessID,
            inputEventsPosted: 0
        )
        try printJSON(report)
        if let output = option("--output", in: arguments) {
            try writeJSON(report, to: outputURL(for: output))
        }
        guard previousProcessID != processID else {
            throw ProbeError.unsafeWindow(
                "focus check requires another application to be frontmost before it starts"
            )
        }
        guard activation.accepted, report.targetFocusVerified, report.restorationVerified else {
            throw ProbeError.unsafeWindow("focus check could not verify activation and restoration")
        }
    }

    static func captureCommand(_ arguments: [String]) async throws {
        try validateOptions(
            arguments,
            valueOptions: ["--window-id", "--output", "--report"]
        )
        try ensureScreenCapturePermission()
        let requestedID = try optionalWindowID(arguments)
        let output = option("--output", in: arguments) ?? "captures/mirror-probe.png"
        let window = try await selectMirrorWindow(requestedID: requestedID)
        let image = try await capture(window: window)
        let metrics = try metrics(for: image)
        let imageOutputURL = try outputURL(for: output)
        try writePNG(image, to: imageOutputURL)

        let report = CaptureReport(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            window: windowReport(window),
            outputPath: imageOutputURL.path,
            imageWidth: image.width,
            imageHeight: image.height,
            metrics: metrics
        )
        try printJSON(report)

        if let reportPath = option("--report", in: arguments) {
            try writeJSON(report, to: outputURL(for: reportPath))
        }

        if metrics.isBlank {
            throw ProbeError.unsafeWindow("captured frame is blank, transparent, or nearly black")
        }
    }

    static func clickCommand(_ arguments: [String]) async throws {
        try validateOptions(
            arguments,
            valueOptions: ["--window-id", "--x", "--y", "--confirm", "--output-dir", "--report"]
        )
        try ensureScreenCapturePermission()
        try ensurePostEventPermission()

        guard option("--confirm", in: arguments) == singleClickConfirmation else {
            throw ProbeError.invalidArguments(
                "click requires --confirm \(singleClickConfirmation); exactly one mouse-down/up pair will be sent"
            )
        }
        guard let requestedID = try optionalWindowID(arguments) else {
            throw ProbeError.invalidArguments("click requires --window-id from a successful capture report")
        }
        let normalizedX = try requiredNormalizedCoordinate("--x", in: arguments)
        let normalizedY = try requiredNormalizedCoordinate("--y", in: arguments)
        let outputDirectory = option("--output-dir", in: arguments) ?? "captures/click-test"

        var window = try await selectMirrorWindow(requestedID: requestedID)
        let initialFrame = window.frame
        let beforeImage = try await capture(window: window)
        let beforeMetrics = try metrics(for: beforeImage)
        guard !beforeMetrics.isBlank else {
            throw ProbeError.unsafeWindow("pre-click frame is blank, transparent, or nearly black")
        }

        let directoryURL = try outputURL(for: outputDirectory, isDirectory: true)
        let beforeURL = directoryURL.appendingPathComponent("before.png")
        let afterURL = directoryURL.appendingPathComponent("after.png")
        try writePNG(beforeImage, to: beforeURL)

        guard let app = window.owningApplication,
              let runningApplication = NSRunningApplication(processIdentifier: app.processID)
        else {
            throw ProbeError.unsafeWindow("could not resolve the owning iPhone Mirroring application")
        }

        guard var focusBorrow = ForegroundFocusBorrow(targetProcessID: app.processID) else {
            throw ProbeError.unsafeWindow("the current focused application is unavailable")
        }
        defer { focusBorrow.restore() }
        if ForegroundApplicationFocus.currentApplication?.processIdentifier != app.processID {
            _ = ForegroundApplicationActivation.request(
                runningApplication, options: [.activateAllWindows],
                expectedCurrentProcessID: focusBorrow.previousProcessID
            )
            try await Task.sleep(for: .milliseconds(350))
        }

        window = try await selectMirrorWindow(requestedID: requestedID)
        guard approximatelyEqual(window.frame, initialFrame, tolerance: 0.5) else {
            throw ProbeError.unsafeWindow("the window moved or resized after the pre-click capture")
        }
        guard window.isActive else {
            throw ProbeError.unsafeWindow("the requested iPhone Mirroring window is not active")
        }
        guard ForegroundApplicationFocus.currentApplication?.processIdentifier == app.processID else {
            throw ProbeError.unsafeWindow("iPhone Mirroring could not be made the frontmost application")
        }

        let clickPoint = CGPoint(
            x: window.frame.minX + window.frame.width * normalizedX,
            y: window.frame.minY + window.frame.height * normalizedY
        )
        guard let topmost = topmostInputWindow(
            at: clickPoint,
            expectedWindowFrame: window.frame,
            expectedProcessID: app.processID
        ) else {
            throw ProbeError.unsafeWindow("could not identify the topmost window at the requested click point")
        }
        guard topmost.identity.windowID == requestedID,
              topmost.identity.processID == app.processID
        else {
            throw ProbeError.unsafeWindow(
                "window ID \(topmost.identity.windowID) is above the requested click point"
            )
        }

        let previousMouseLocation = CGEvent(source: nil)?.location
        _ = try postSingleClick(at: clickPoint)
        if let previousMouseLocation {
            CGWarpMouseCursorPosition(previousMouseLocation)
        }
        focusBorrow.restore()

        try await Task.sleep(for: .seconds(1))
        let afterWindow = try await selectMirrorWindow(requestedID: requestedID)
        let afterImage = try await capture(window: afterWindow)
        let afterMetrics = try metrics(for: afterImage)
        try writePNG(afterImage, to: afterURL)

        let difference: Double?
        if beforeImage.width == afterImage.width, beforeImage.height == afterImage.height {
            let beforeFrame = try rgbaFrame(from: beforeImage)
            let afterFrame = try rgbaFrame(from: afterImage)
            difference = try FrameAnalyzer.meanAbsoluteDifferenceRGBA(
                beforeFrame.bytes,
                afterFrame.bytes,
                width: beforeFrame.width,
                height: beforeFrame.height,
                bytesPerRow: beforeFrame.bytesPerRow
            )
        } else {
            difference = nil
        }

        let report = ClickReport(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            window: windowReport(afterWindow),
            normalizedX: normalizedX,
            normalizedY: normalizedY,
            screenX: clickPoint.x,
            screenY: clickPoint.y,
            beforePath: beforeURL.path,
            afterPath: afterURL.path,
            beforeMetrics: beforeMetrics,
            afterMetrics: afterMetrics,
            meanAbsoluteDifference: difference
        )
        try printJSON(report)

        if let reportPath = option("--report", in: arguments) {
            try writeJSON(report, to: outputURL(for: reportPath))
        }
    }
}
