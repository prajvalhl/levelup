import Foundation

public struct LaunchArguments {
    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case malformed(String)
        case missingValue(String)
        case emptyValue(String)
        case flagHasValue(String)
        case duplicate(String)

        public var description: String {
            switch self {
            case let .malformed(argument): return "Malformed argument: \(argument)"
            case let .missingValue(option): return "Missing value for \(option)"
            case let .emptyValue(option): return "Empty value for \(option)"
            case let .flagHasValue(flag): return "Flag does not accept a value: \(flag)"
            case let .duplicate(option): return "Duplicate argument: \(option)"
            }
        }
    }

    public let values: [String: String]
    public let flags: Set<String>

    public init(_ arguments: [String], flags knownFlags: Set<String>) throws {
        var values: [String: String] = [:]
        var flags = Set<String>()
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("--"), argument.count > 2 else {
                throw ParseError.malformed(argument)
            }

            if let separator = argument.firstIndex(of: "=") {
                let option = String(argument[..<separator])
                let value = String(argument[argument.index(after: separator)...])
                guard option.count > 2 else { throw ParseError.malformed(argument) }
                if knownFlags.contains(option) { throw ParseError.flagHasValue(option) }
                guard !value.isEmpty else { throw ParseError.emptyValue(option) }
                guard values[option] == nil else { throw ParseError.duplicate(option) }
                values[option] = value
                index += 1
                continue
            }

            if knownFlags.contains(argument) {
                guard !flags.contains(argument) else { throw ParseError.duplicate(argument) }
                flags.insert(argument)
                index += 1
                continue
            }

            guard index + 1 < arguments.count,
                  !arguments[index + 1].hasPrefix("--") else {
                throw ParseError.missingValue(argument)
            }
            let value = arguments[index + 1]
            guard !value.isEmpty else { throw ParseError.emptyValue(argument) }
            guard values[argument] == nil else { throw ParseError.duplicate(argument) }
            values[argument] = value
            index += 2
        }

        self.values = values
        self.flags = flags
    }

    public subscript(_ option: String) -> String? { values[option] }
    public func contains(_ flag: String) -> Bool { flags.contains(flag) }
}
