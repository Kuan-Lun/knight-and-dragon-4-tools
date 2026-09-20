import Foundation
import MirrorProbeCore

struct WindowReport: Codable {
    let windowID: UInt32
    let processID: Int32
    let applicationName: String
    let bundleIdentifier: String
    let title: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let onScreen: Bool
    let active: Bool
}

struct CaptureReport: Codable {
    let timestamp: String
    let window: WindowReport
    let outputPath: String
    let imageWidth: Int
    let imageHeight: Int
    let metrics: FrameMetrics
    let contentLayout: ContentLayoutReport?
}

struct DoctorReport: Codable {
    let timestamp: String
    let screenCapturePermission: String
    let postEventPermission: String
    let windows: [WindowReport]
    let nextStep: String?
}

struct FocusCheckReport: Codable {
    let timestamp: String
    let windowID: UInt32
    let previousProcessID: Int32?
    let targetProcessID: Int32
    let activation: ForegroundActivationRequest
    let frontmostProcessIDAfterActivation: Int32?
    let restoration: ForegroundActivationRequest?
    let frontmostProcessIDAfterRestoration: Int32?
    let targetFocusVerified: Bool
    let restorationVerified: Bool
    let inputEventsPosted: Int
}

struct ClickReport: Codable {
    let timestamp: String
    let window: WindowReport
    let normalizedX: Double
    let normalizedY: Double
    let screenX: Double
    let screenY: Double
    let beforePath: String
    let afterPath: String
    let beforeMetrics: FrameMetrics
    let afterMetrics: FrameMetrics
    let meanAbsoluteDifference: Double?
}
