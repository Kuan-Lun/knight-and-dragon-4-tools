import Foundation
import MirrorProbeCore

let mirrorBundleIdentifier = "com.apple.ScreenContinuity"
let singleClickConfirmation = "SINGLE_CLICK"
let autoLevelConfirmation = "AUTO_LEVEL"
let legacyAutoLevelConfirmation = "AUTO_LEVEL_NO_TALISMAN"
let characterRerollConfirmation = "CHARACTER_REROLL"
let analysisProfileName = "zh-Hant-v1"
let analysisSchemaVersion = 2
let automationSchemaVersion = 5
let characterRerollSchemaVersion = 3
let maximumPNGByteCount = 50 * 1_024 * 1_024
let applicationStopRequest = AutomationStopRequest()

enum ProbeError: LocalizedError {
    case invalidArguments(String)
    case screenCapturePermissionRequired
    case postEventPermissionRequired
    case noMirrorWindow
    case ambiguousMirrorWindows([UInt32])
    case requestedWindowNotFound(UInt32)
    case unsafeWindow(String)
    case captureFailed(String)
    case imageLoadFailed(String)
    case textRecognitionFailed(String)
    case pngEncodingFailed
    case frameConversionFailed

    var errorDescription: String? {
        switch self {
        case let .invalidArguments(message):
            return message
        case .screenCapturePermissionRequired:
            return "Screen Recording permission is required. Grant it in System Settings, then run the command again."
        case .postEventPermissionRequired:
            return "Accessibility/Post Event permission is required. Grant it in System Settings, then run the command again."
        case .noMirrorWindow:
            return "No on-screen iPhone Mirroring window was found. Keep iPhone Mirroring open and unminimized in the current Space; other windows may cover it."
        case let .ambiguousMirrorWindows(ids):
            return "More than one eligible iPhone Mirroring window was found (IDs: \(ids)). Pass --window-id explicitly."
        case let .requestedWindowNotFound(id):
            return "The requested iPhone Mirroring window ID \(id) is no longer available."
        case let .unsafeWindow(reason):
            return "Safety check refused the action: \(reason)"
        case let .captureFailed(message):
            return "ScreenCaptureKit failed: \(message)"
        case let .imageLoadFailed(message):
            return "Could not load the input image: \(message)"
        case let .textRecognitionFailed(message):
            return "Vision text recognition failed: \(message)"
        case .pngEncodingFailed:
            return "Could not encode the captured image as PNG."
        case .frameConversionFailed:
            return "Could not convert the captured image to RGBA pixels."
        }
    }
}
