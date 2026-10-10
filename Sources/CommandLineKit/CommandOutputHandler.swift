import CommandLineKitCore
import Foundation

/// The command output
public protocol CommandOutputHandler: Sendable {
    /// The Output Type
    associatedtype OutputType

    /// The handle output
    /// - Parameter data: The data
    /// - Returns: The output type
    func handleOutput(_ data: Data) throws -> OutputType
}

/// A command output handler that converts `Data` into a `String`.
///
/// This handler decodes the provided data as UTF-8 and trims any leading or trailing newlines.
///
/// Usage:
/// ```
/// let handler = CommandOutputHandlerString()
/// let outputString = handler.handleOutput(data)
/// ```
///
/// - Returns: A `String` representation of the data.
public struct CommandOutputHandlerString: CommandOutputHandler {
    public init() {}

    /// Converts the given `Data` into a `String` and trims any newlines.
    ///
    /// - Parameter data: The data to be processed.
    /// - Returns: A `String` representation of the data with no leading/trailing newlines.
    public func handleOutput(_ data: Data) -> String {
        guard let valueString = String(data: data, encoding: .utf8) else { return "" }

        return valueString
            .trimmingCharacters(in: .newlines)
    }
}

/// A command output handler that returns the raw `Data` without any modification.
///
/// Usage:
/// ```
/// let handler = CommandOutputHandlerData()
/// let outputData = handler.handleOutput(data)
/// ```
///
/// - Returns: The unmodified `Data`.
public struct CommandOutputHandlerData: CommandOutputHandler {
    public init() {}

    /// Returns the raw `Data` as is.
    ///
    /// - Parameter data: The data to be processed.
    /// - Returns: The raw `Data`.
    public func handleOutput(_ data: Data) -> Data {
        data
    }
}

/// A command output handler that decodes `Data` into a `Codable` type.
///
/// This handler attempts to decode the provided data using a `JSONDecoder`.
/// If the decoding fails, it throws `CommandError.outputHandling`.
///
/// Usage:
/// ```
/// let handler = CommandOutputHandlerCodable<MyModel>(type: MyModel.self)
/// let outputModel = try handler.handleOutput(data)
/// ```
///
/// - Parameters:
///   - type: The `Codable` type to decode.
///   - jsonDecoder: A `JSONDecoder` to decode the data. Defaults to a standard `JSONDecoder`.
///
/// - Returns: The decoded model of type `T`.
/// - Throws: `CommandError.outputHandling` if decoding fails.
public struct CommandOutputHandlerCodable<T: Decodable & Sendable>: CommandOutputHandler {
    public let type: T.Type
    public let jsonDecoder: JSONDecoder

    /// Initializes a new handler for decoding a `Codable` type.
    ///
    /// - Parameters:
    ///   - type: The `Codable` type to decode.
    ///   - jsonDecoder: A custom `JSONDecoder` to use for decoding. Defaults to `JSONDecoder()`.
    public init(type: T.Type, jsonDecoder: JSONDecoder = JSONDecoder()) {
        self.type = type
        self.jsonDecoder = jsonDecoder
    }

    /// Decodes the given `Data` into the specified `Codable` type.
    ///
    /// - Parameter data: The data to be processed.
    /// - Returns: The decoded model of type `T`.
    /// - Throws: `CommandError.outputHandling` if the decoding process fails.
    public func handleOutput(_ data: Data) throws -> T {
        do {
            return try jsonDecoder.decode(type, from: data)
        } catch {
            throw CommandError.outputHandling(reason: "\(error)")
        }
    }
}

/// A command output handler that splits `Data` into an array of `String`s based on newlines.
///
/// This handler decodes the data as UTF-8 and splits the string by newlines.
/// Each line is also trimmed to remove any extraneous newline characters.
///
/// Usage:
/// ```
/// let handler = StringArrayOutputHandler()
/// let outputArray = handler.handleOutput(data)
/// ```
///
/// - Returns: An array of strings, each representing a line of the original data.
public struct CommandOutputHandlerStringArray: CommandOutputHandler {
    public init() {}

    /// Converts the given `Data` into an array of `String`s, splitting by newlines.
    ///
    /// - Parameter data: The data to be processed.
    /// - Returns: An array of `String`s, split by newline characters.
    public func handleOutput(_ data: Data) -> [String] {
        guard let valueString = String(data: data, encoding: .utf8) else { return [] }

        return valueString.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .newlines) }
    }
}
