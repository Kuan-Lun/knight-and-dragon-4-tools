import Foundation

/// Runs one command inside an existing application or command-line event loop.
/// Arguments exclude the executable path. Offline commands do not initialize AppKit.
public enum MirrorProbeRuntime {
    public static func run(arguments: [String]) async throws {
        guard let command = arguments.first else {
            printUsage()
            return
        }
        let options = Array(arguments.dropFirst())

        switch command {
        case "help", "--help", "-h":
            printUsage()
        case "doctor":
            await establishAppKitConnection()
            try await doctor(options)
        case "capture":
            await establishAppKitConnection()
            try await captureCommand(options)
        case "focus-check":
            await establishAppKitConnection()
            try await focusCheckCommand(options)
        case "analyze":
            await establishAppKitConnection()
            try await analyzeCommand(options)
        case "analyze-file":
            try analyzeFileCommand(options)
        case "click":
            await establishAppKitConnection()
            try await clickCommand(options)
        case "reroll-character":
            await establishAppKitConnection()
            try await characterRerollCommand(options)
        case "run":
            await establishAppKitConnection()
            try await autoLevelCommand(options)
        default:
            throw ProbeError.invalidArguments("Unknown command '\(command)'. Run mirror-probe help.")
        }
    }


    /// Records a normal application Quit without interrupting final report persistence.
    public static func requestApplicationQuit() -> Bool {
        applicationStopRequest.requestApplicationQuit()
    }
}
