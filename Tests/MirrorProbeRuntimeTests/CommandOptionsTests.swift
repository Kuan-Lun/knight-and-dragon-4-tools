import Testing
@testable import MirrorProbeRuntime

@Suite("Production command option validation")
struct CommandOptionsTests {
    @Test("Value options and flags retain literal paths, ordering, and absence")
    func validOptions() throws {
        let arguments = ["--request-permissions", "--output", "/tmp/report with spaces.json"]
        try MirrorProbeRuntime.validateOptions(
            arguments, valueOptions: ["--output"], flagOptions: ["--request-permissions"]
        )
        #expect(MirrorProbeRuntime.option("--output", in: arguments) == "/tmp/report with spaces.json")
        #expect(MirrorProbeRuntime.option("--window-id", in: arguments) == nil)
        #expect(try MirrorProbeRuntime.optionalWindowID([]) == nil)
    }

    @Test("Malformed options are rejected before command execution", arguments: [
        ["positional"], ["--unknown"], ["--output"], ["--output", "--request-permissions"],
        ["--output", "one", "--output", "two"],
        ["--request-permissions", "--request-permissions"],
        ["--request-permissions", "unexpected-value"], ["--output=one"],
    ])
    func malformedOptions(arguments: [String]) {
        #expect(throws: ProbeError.self) {
            try MirrorProbeRuntime.validateOptions(
                arguments, valueOptions: ["--output"], flagOptions: ["--request-permissions"]
            )
        }
    }

    @Test("Window identifiers preserve UInt32 boundaries")
    func windowIDBoundary() throws {
        #expect(try MirrorProbeRuntime.optionalWindowID(["--window-id", "4294967295"]) == UInt32.max)
        for value in ["4294967296", "-1", "1.5", "NaN", ""] {
            #expect(throws: ProbeError.self) {
                try MirrorProbeRuntime.optionalWindowID(["--window-id", value])
            }
        }
    }

    @Test("Integer limits reject overflow, fractions and out-of-range values")
    func integerLimits() throws {
        #expect(try MirrorProbeRuntime.boundedIntegerOption(
            "--max-cycles", in: [], defaultValue: 3, range: 1...Int.max
        ) == 3)
        #expect(try MirrorProbeRuntime.boundedIntegerOption(
            "--max-cycles", in: ["--max-cycles", String(Int.max)], defaultValue: 3, range: 1...Int.max
        ) == Int.max)
        for value in ["0", "-1", "1.1", "9223372036854775808", "inf"] {
            #expect(throws: ProbeError.self) {
                try MirrorProbeRuntime.boundedIntegerOption(
                    "--max-cycles", in: ["--max-cycles", value], defaultValue: 3, range: 1...Int.max
                )
            }
        }
    }

    @Test("Runtime and input coordinates reject non-finite or out-of-range numbers")
    func floatingPointLimits() throws {
        #expect(try MirrorProbeRuntime.boundedDoubleOption(
            "--max-minutes", in: ["--max-minutes", "0.5"], defaultValue: 1, range: 0.1...60
        ) == 0.5)
        for value in ["NaN", "inf", "-inf", "1e999", "-1", "61"] {
            #expect(throws: ProbeError.self) {
                try MirrorProbeRuntime.boundedDoubleOption(
                    "--max-minutes", in: ["--max-minutes", value], defaultValue: 1, range: 0.1...60
                )
            }
        }
        for value in ["NaN", "inf", "-0.1", "1.1", "0", "1"] {
            #expect(throws: ProbeError.self) {
                try MirrorProbeRuntime.requiredNormalizedCoordinate("--x", in: ["--x", value])
            }
        }
        #expect(try MirrorProbeRuntime.requiredNormalizedCoordinate("--x", in: ["--x", "0.02"]) == 0.02)
        #expect(try MirrorProbeRuntime.requiredNormalizedCoordinate("--x", in: ["--x", "0.98"]) == 0.98)
    }

    @Test("Unknown commands fail through the public dispatcher without platform setup")
    func unknownCommand() async {
        await #expect(throws: ProbeError.self) {
            try await MirrorProbeRuntime.run(arguments: ["unknown-command"])
        }
    }
}
