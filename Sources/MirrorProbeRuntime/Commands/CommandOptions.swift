import Foundation

extension MirrorProbeRuntime {
    static func option(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    static func validateOptions(
        _ arguments: [String],
        valueOptions: Set<String>,
        flagOptions: Set<String> = []
    ) throws {
        var seen = Set<String>()
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("--") else {
                throw ProbeError.invalidArguments("Unexpected positional argument '\(argument)'")
            }
            guard !seen.contains(argument) else {
                throw ProbeError.invalidArguments("Option '\(argument)' may only be supplied once")
            }
            seen.insert(argument)

            if flagOptions.contains(argument) {
                index += 1
                continue
            }
            guard valueOptions.contains(argument) else {
                throw ProbeError.invalidArguments("Unknown option '\(argument)'")
            }
            guard index + 1 < arguments.count,
                  !arguments[index + 1].hasPrefix("--")
            else {
                throw ProbeError.invalidArguments("Option '\(argument)' requires a value")
            }
            index += 2
        }
    }

    static func optionalWindowID(_ arguments: [String]) throws -> UInt32? {
        guard let value = option("--window-id", in: arguments) else {
            return nil
        }
        guard let parsed = UInt32(value) else {
            throw ProbeError.invalidArguments("--window-id must be an unsigned integer")
        }
        return parsed
    }

    static func boundedIntegerOption(
        _ name: String,
        in arguments: [String],
        defaultValue: Int,
        range: ClosedRange<Int>
    ) throws -> Int {
        guard let value = option(name, in: arguments) else {
            return defaultValue
        }
        guard let parsed = Int(value), range.contains(parsed) else {
            throw ProbeError.invalidArguments(
                "\(name) must be an integer from \(range.lowerBound) through \(range.upperBound)"
            )
        }
        return parsed
    }

    static func boundedDoubleOption(
        _ name: String,
        in arguments: [String],
        defaultValue: Double,
        range: ClosedRange<Double>
    ) throws -> Double {
        guard let value = option(name, in: arguments) else {
            return defaultValue
        }
        guard let parsed = Double(value), parsed.isFinite, range.contains(parsed) else {
            throw ProbeError.invalidArguments(
                "\(name) must be a number from \(range.lowerBound) through \(range.upperBound)"
            )
        }
        return parsed
    }

    static func requiredNormalizedCoordinate(
        _ name: String,
        in arguments: [String]
    ) throws -> Double {
        guard let value = option(name, in: arguments),
              let parsed = Double(value),
              parsed.isFinite,
              parsed >= 0.02,
              parsed <= 0.98
        else {
            throw ProbeError.invalidArguments("\(name) must be a number from 0.02 through 0.98")
        }
        return parsed
    }
}
