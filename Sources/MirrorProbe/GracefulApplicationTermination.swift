import AppKit
import Foundation
import MirrorProbeRuntime

/// AppKit must not exit in the middle of a run when it receives a normal Quit AppleEvent.
/// The command keeps running until a safe stop checkpoint saves its final report; main then
/// exits with the command's original exit code. No task cancellation bypasses that cleanup.
@MainActor
final class GracefulApplicationTerminationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if MirrorProbeRuntime.requestApplicationQuit() {
            FileHandle.standardError.write(Data(
                "applicationQuitRequested: waiting for the command to stop safely and finalize its report\n"
                    .utf8
            ))
        }
        return .terminateLater
    }
}
