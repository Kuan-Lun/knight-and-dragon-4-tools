import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Read-only evidence for a click that reached the right application but may not have reached
/// its focused window. Unknown results never authorize, reject, or otherwise change an input.
enum AutomationWindowFocusDiagnostic {
    static func log(processID: Int32, point: CGPoint, expectedFrame: CGRect) {
        var reader = Reader(processID: processID, point: point, expectedFrame: expectedFrame)
        reader.sample()
        reader.report.elapsedMilliseconds = Int(
            (ProcessInfo.processInfo.systemUptime - reader.startedAt) * 1_000
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(reader.report),
              let json = String(data: data, encoding: .utf8)
        else {
            FileHandle.standardError.write(Data("windowFocusBeforePost: encodingFailed\n".utf8))
            return
        }
        FileHandle.standardError.write(Data("windowFocusBeforePost: \(json)\n".utf8))
    }

    private struct Report: Encodable {
        let expectedProcessID: Int32
        var focusedWindowState = "unknown"
        var hitWindowState = "unknown"
        var focusedWindowMatchesHitWindow = "unknown"
        var focusedFrameMatchesExpected = "unknown"
        var hitFrameMatchesExpected = "unknown"
        var focusedWindowProcessID: Int32?
        var hitElementProcessID: Int32?
        var hitWindowProcessID: Int32?
        var focusedFrame: [String: Double]?
        var hitFrame: [String: Double]?
        var expectedFrame: [String: Double]?
        var axErrors: [String: Int32] = [:]
        var unknownReasons: [String: String] = [:]
        var queries = 0
        var elapsedMilliseconds = 0
    }

    private struct Reader {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let processID: Int32
        let point: CGPoint
        let expectedFrame: CGRect
        var report: Report

        init(processID: Int32, point: CGPoint, expectedFrame: CGRect) {
            self.processID = processID
            self.point = point
            self.expectedFrame = expectedFrame
            report = Report(expectedProcessID: processID)
            if Self.isFinite(expectedFrame) {
                report.expectedFrame = Self.fields(expectedFrame)
            }
        }

        mutating func sample() {
            guard processID > 0, point.x.isFinite, point.y.isFinite,
                  Self.isFinite(expectedFrame), !expectedFrame.isEmpty
            else {
                report.unknownReasons["input"] = "invalidPIDOrGeometry"
                return
            }
            guard NSRunningApplication(processIdentifier: processID)?.bundleIdentifier
                    == "com.apple.ScreenContinuity"
            else {
                report.unknownReasons["application"] = "notTheMirrorApplication"
                return
            }
            guard AXIsProcessTrusted() else {
                report.unknownReasons["accessibility"] = "notTrusted"
                return
            }

            // The system-wide hit test returns only an element identity here. Never read its
            // role, parent window, or geometry until its PID matches the locked mirror PID.
            let systemWide = AXUIElementCreateSystemWide()
            var hit: AXUIElement?
            if prepare(systemWide, operation: "hit", fullTimeoutRequired: true) {
                report.queries += 1
                let error = AXUIElementCopyElementAtPosition(
                    systemWide, Float(point.x), Float(point.y), &hit
                )
                report.axErrors["hit"] = error.rawValue
                if error != .success { hit = nil }
            }
            if let hit {
                report.hitElementProcessID = pid(hit, operation: "hitPID")
            }

            let app = AXUIElementCreateApplication(processID)
            let focusedValue = attribute(
                app, name: kAXFocusedWindowAttribute as CFString, operation: "focusedWindow"
            )
            let focused = element(focusedValue, operation: "focusedWindow")
            var verifiedFocused: AXUIElement?
            if let focused {
                report.focusedWindowProcessID = pid(focused, operation: "focusedPID")
                if report.focusedWindowProcessID == processID {
                    verifiedFocused = focused
                    report.focusedWindowState = "available"
                    let frame = geometry(focused, operation: "focusedGeometry")
                    report.focusedFrame = frame.map(Self.fields)
                    report.focusedFrameMatchesExpected = match(frame)
                } else {
                    report.unknownReasons["focusedWindow"] = "PIDMismatchOrUnavailable"
                }
            }

            guard let hit, report.hitElementProcessID == processID else {
                report.unknownReasons["hitWindow"] = "hitPIDMismatchOrUnavailable"
                return
            }
            var hitWindow: AXUIElement?
            if let verifiedFocused, CFEqual(hit, verifiedFocused) {
                hitWindow = hit
            } else {
                let containerValues = attributes(
                    hit, names: [kAXRoleAttribute as CFString, kAXWindowAttribute as CFString],
                    operation: "hitContainer"
                )
                if containerValues[kAXRoleAttribute as String] as? String == kAXWindowRole as String {
                    hitWindow = hit
                } else {
                    hitWindow = element(
                        containerValues[kAXWindowAttribute as String], operation: "hitWindow"
                    )
                }
            }
            guard let hitWindow else { return }
            report.hitWindowProcessID = CFEqual(hitWindow, hit)
                ? report.hitElementProcessID : pid(hitWindow, operation: "hitWindowPID")
            guard report.hitWindowProcessID == processID else {
                report.unknownReasons["hitWindow"] = "PIDMismatchOrUnavailable"
                return
            }
            report.hitWindowState = "available"
            let sameWindow = verifiedFocused.map { CFEqual($0, hitWindow) }
            report.focusedWindowMatchesHitWindow = sameWindow.map { String($0) } ?? "unknown"
            if sameWindow == true {
                report.hitFrame = report.focusedFrame
                report.hitFrameMatchesExpected = report.focusedFrameMatchesExpected
            } else {
                let frame = geometry(hitWindow, operation: "hitGeometry")
                report.hitFrame = frame.map(Self.fields)
                report.hitFrameMatchesExpected = match(frame)
            }
        }

        // At most 0.25 seconds per messaging call, with a one-second overall query budget.
        // The system-wide timeout is the same 0.25 seconds already used by our focus reader;
        // never lower that process-wide default to the diagnostic's remaining budget.
        mutating func prepare(
            _ element: AXUIElement, operation: String, fullTimeoutRequired: Bool = false
        ) -> Bool {
            let remaining = startedAt + 1 - ProcessInfo.processInfo.systemUptime
            guard remaining > 0, !fullTimeoutRequired || remaining >= 0.25 else {
                report.unknownReasons[operation] = "diagnosticBudgetExpired"
                return false
            }
            let error = AXUIElementSetMessagingTimeout(element, Float(min(0.25, remaining)))
            if error != .success {
                report.axErrors[operation + ".timeout"] = error.rawValue
                return false
            }
            return true
        }

        mutating func pid(_ element: AXUIElement, operation: String) -> Int32? {
            guard prepare(element, operation: operation) else { return nil }
            var value: pid_t = 0
            report.queries += 1
            let error = AXUIElementGetPid(element, &value)
            report.axErrors[operation] = error.rawValue
            return error == .success && value > 0 ? value : nil
        }

        mutating func attribute(
            _ element: AXUIElement, name: CFString, operation: String
        ) -> CFTypeRef? {
            guard prepare(element, operation: operation) else { return nil }
            var value: CFTypeRef?
            report.queries += 1
            let error = AXUIElementCopyAttributeValue(element, name, &value)
            report.axErrors[operation] = error.rawValue
            return error == .success ? value : nil
        }

        mutating func attributes(
            _ element: AXUIElement, names: [CFString], operation: String
        ) -> [String: CFTypeRef] {
            guard prepare(element, operation: operation) else { return [:] }
            var values: CFArray?
            report.queries += 1
            let error = AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &values)
            report.axErrors[operation] = error.rawValue
            guard error == .success else { return [:] }
            guard let values else {
                report.unknownReasons[operation] = "missingOrInvalidAttributeValues"
                return [:]
            }
            let items = values as [AnyObject]
            if items.count != names.count {
                report.unknownReasons[operation] = "attributeValueCountMismatch"
            }
            var result: [String: CFTypeRef] = [:]
            for (name, item) in zip(names, items) {
                let key = operation + "." + (name as String)
                if CFGetTypeID(item) == CFNullGetTypeID() {
                    report.unknownReasons[key] = "noValue"
                } else if CFGetTypeID(item) == AXValueGetTypeID(),
                          AXValueGetType(unsafeDowncast(item, to: AXValue.self)) == .axError {
                    var attributeError = AXError.failure
                    if AXValueGetValue(unsafeDowncast(item, to: AXValue.self), .axError, &attributeError) {
                        report.axErrors[key] = attributeError.rawValue
                    } else {
                        report.unknownReasons[key] = "invalidAXErrorValue"
                    }
                } else {
                    result[name as String] = item
                }
            }
            return result
        }

        mutating func element(_ value: CFTypeRef?, operation: String) -> AXUIElement? {
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
                if report.unknownReasons[operation] == nil {
                    report.unknownReasons[operation] = "missingOrInvalidElement"
                }
                return nil
            }
            return unsafeDowncast(value, to: AXUIElement.self)
        }

        mutating func geometry(_ element: AXUIElement, operation: String) -> CGRect? {
            let values = attributes(
                element, names: [kAXPositionAttribute as CFString, kAXSizeAttribute as CFString],
                operation: operation
            )
            guard let position = values[kAXPositionAttribute as String],
                  let size = values[kAXSizeAttribute as String],
                  CFGetTypeID(position) == AXValueGetTypeID(),
                  CFGetTypeID(size) == AXValueGetTypeID()
            else {
                report.unknownReasons[operation] = "missingOrInvalidGeometryValue"
                return nil
            }
            let positionValue = unsafeDowncast(position, to: AXValue.self)
            let sizeValue = unsafeDowncast(size, to: AXValue.self)
            var point = CGPoint.zero
            var dimensions = CGSize.zero
            guard AXValueGetType(positionValue) == .cgPoint,
                  AXValueGetType(sizeValue) == .cgSize,
                  AXValueGetValue(positionValue, .cgPoint, &point),
                  AXValueGetValue(sizeValue, .cgSize, &dimensions)
            else {
                report.unknownReasons[operation] = "invalidGeometryValue"
                return nil
            }
            let frame = CGRect(origin: point, size: dimensions)
            guard Self.isFinite(frame), !frame.isEmpty else {
                report.unknownReasons[operation] = "invalidGeometry"
                return nil
            }
            return frame
        }

        func match(_ frame: CGRect?) -> String {
            guard let frame else { return "unknown" }
            return String(abs(frame.minX - expectedFrame.minX) <= 0.5
                && abs(frame.minY - expectedFrame.minY) <= 0.5
                && abs(frame.width - expectedFrame.width) <= 0.5
                && abs(frame.height - expectedFrame.height) <= 0.5)
        }

        static func isFinite(_ frame: CGRect) -> Bool {
            [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height].allSatisfy(\.isFinite)
        }

        static func fields(_ frame: CGRect) -> [String: Double] {
            ["x": Double(frame.minX), "y": Double(frame.minY),
             "width": Double(frame.width), "height": Double(frame.height)]
        }
    }
}
