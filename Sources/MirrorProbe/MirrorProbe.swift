import AppKit
import Foundation
import MirrorProbeRuntime

@main
private struct MirrorProbe {
    @MainActor
    static func main() {
        // NSWorkspace/NSRunningApplication cache changing properties until the main event
        // loop processes AppKit updates. Initializing NSApplication alone left foreground
        // observations stale in the packaged command, even after successful AX activation.
        let appKitCommands: Set<String> = [
            "doctor", "focus-check", "capture", "analyze", "click", "reroll-character", "run",
        ]
        let needsAppKit = appKitCommands.contains(CommandLine.arguments.dropFirst().first ?? "")
        let keepAlivePort = Port()
        RunLoop.main.add(keepAlivePort, forMode: .common)
        Task {
            do {
                try await MirrorProbeRuntime.run(arguments: Array(CommandLine.arguments.dropFirst()))
                Foundation.exit(0)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                FileHandle.standardError.write(Data("error: \(message)\n".utf8))
                Foundation.exit(1)
            }
        }
        if needsAppKit {
            let application = NSApplication.shared
            let terminationDelegate = GracefulApplicationTerminationDelegate()
            application.delegate = terminationDelegate
            // NSApplication's delegate is weak; keep it alive throughout the event loop.
            withExtendedLifetime(terminationDelegate) {
                application.run()
            }
        } else {
            // Help and offline analysis must not establish a WindowServer connection.
            RunLoop.main.run()
        }
    }
}
