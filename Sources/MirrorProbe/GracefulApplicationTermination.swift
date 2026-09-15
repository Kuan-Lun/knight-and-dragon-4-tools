import AppKit
import Foundation
import MirrorProbeCore

/// AppKit must not exit in the middle of a run when it receives a normal Quit AppleEvent.
/// The command keeps running until a safe stop checkpoint saves its final report; main then
/// exits with the command's original exit code. No task cancellation bypasses that cleanup.
@MainActor
final class GracefulApplicationTerminationDelegate: NSObject, NSApplicationDelegate {
    private let stopRequest: AutomationStopRequest

    init(stopRequest: AutomationStopRequest) {
        self.stopRequest = stopRequest
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if stopRequest.requestApplicationQuit() {
            FileHandle.standardError.write(Data(
                "applicationQuitRequested: waiting for the command to stop safely and finalize its report\n"
                    .utf8
            ))
        }
        return .terminateLater
    }
}
