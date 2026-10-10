import CommandLineKitCore
import Foundation

/// The injected side of user input: it creates one ``CommandInputRequest`` per question.
///
/// Depend on `any CommandLineInput` and inject the default, the stub or your own. Only
/// ``makeRequest(_:default:secret:promptHandler:)`` must be implemented. ``prompt(_:default:secret:)``,
/// ``confirm(_:default:)`` and ``choose(_:from:)`` have default implementations built on it, so the parsing
/// rules
/// are written once. An implementation backed by a GUI MAY override ``confirm(_:default:)`` with a native
/// dialog.
public protocol CommandLineInput: Sendable {
    /// Creates a question. Nothing is written or read until ``CommandInputRequest/run()``.
    ///
    /// - Parameters:
    ///   - message: The complete prompt text, shown as is.
    ///   - default: The answer used when stdin is not a terminal.
    ///   - secret: Hide what the user types. An implementation that cannot hide it MUST throw rather than
    /// echo.
    ///   - promptHandler: Where prompt text goes. `nil` means stderr.
    func makeRequest(
        _ message: String,
        default: String?,
        secret: Bool,
        promptHandler: (any CommandShellDataHandler)?
    ) -> any CommandInputRequest

    /// Asks for a line of text. An empty answer gives the default, or an empty string.
    func prompt(_ message: String, default: String?, secret: Bool) async throws -> String

    /// Asks a yes/no question. Accepts `y`, `yes`, `n`, `no` in any case; empty means the default.
    func confirm(_ message: String, default: Bool?) async throws -> Bool

    /// Asks the user to pick one option, by its 1-based number or its exact text.
    func choose<Option: CustomStringConvertible & Sendable>(
        _ message: String,
        from options: [Option]
    ) async throws -> Option
}

/// One question. Single-use: a second ``run()`` throws.
public protocol CommandInputRequest: Sendable {
    /// The complete prompt text.
    var message: String { get }

    /// The answer used when stdin is not a terminal.
    var defaultAnswer: String? { get }

    var isSecret: Bool { get }

    /// Where prompt text goes. `nil` means stderr. Only `handle(_:)` is called: the handler is shared by
    /// every
    /// prompt, so `end()` never is.
    var promptHandler: (any CommandShellDataHandler)? { get }

    /// Asks the question.
    ///
    /// - Returns: The line typed, or `nil` at end of input.
    /// - Throws: ``CommandInputError``.
    func run() async throws -> String?
}

extension CommandLineInput {
    /// Asks without a default, for callers that want the raw line. `nil` means end of input.
    public func readLine(prompt: String, secret: Bool) async throws -> String? {
        try await makeRequest(prompt, default: nil, secret: secret, promptHandler: nil).run()
    }

    /// Asks for a line; an empty answer or end of input gives the default.
    public func prompt(_ message: String, default: String?, secret: Bool) async throws -> String {
        let display = (secret ? nil : `default`).map { "\(message) [\($0)]" } ?? message
        let answer = try await makeRequest(display, default: `default`, secret: secret, promptHandler: nil)
            .run()

        guard let answer else {
            guard let `default` else { throw CommandInputError.unavailable(reason: "end of input") }

            return `default`
        }

        return answer.isEmpty ? (`default` ?? "") : answer
    }

    /// Re-asks up to 3 times, then throws ``CommandInputError/unavailable(reason:)``.
    public func confirm(_ message: String, default: Bool?) async throws -> Bool {
        let hint = switch `default` {
        case true?: "[Y/n]"
        case false?: "[y/N]"
        case nil: "[y/n]"
        }
        let fallback = `default`.map { $0 ? "y" : "n" }

        var display = "\(message) \(hint)"
        for _ in 0 ..< Self.maximumAttempts {
            let answer = try await makeRequest(display, default: fallback, secret: false, promptHandler: nil)
                .run()
            let value = (answer?.isEmpty == false ? answer : fallback)?.lowercased()
            switch value {
            case "y", "yes": return true
            case "n", "no": return false
            case nil: throw CommandInputError.unavailable(reason: "end of input")
            default: display = "Please answer y or n. \(message) \(hint)"
            }
        }
        throw CommandInputError.unavailable(reason: "no valid answer")
    }

    /// Lists the options, re-asks up to 3 times, and throws on an empty list without prompting.
    public func choose<Option: CustomStringConvertible & Sendable>(
        _ message: String,
        from options: [Option]
    ) async throws -> Option {
        guard !options.isEmpty else { throw CommandInputError.unavailable(reason: "no options") }

        let listing = options.enumerated().map { "  \($0.offset + 1)) \($0.element)" }.joined(separator: "\n")
        var display = "\(message)\n\(listing)\nChoice"
        for _ in 0 ..< Self.maximumAttempts {
            guard let answer = try await makeRequest(display, default: nil, secret: false, promptHandler: nil)
                .run()
            else { throw CommandInputError.unavailable(reason: "end of input") }

            if let index = Int(answer), options.indices.contains(index - 1) { return options[index - 1] }
            if let match = options.first(where: { $0.description == answer }) { return match }
            display = "Please enter a number from 1 to \(options.count), or an option's text.\n\(listing)\nChoice"
        }
        throw CommandInputError.unavailable(reason: "no valid answer")
    }

    private static var maximumAttempts: Int {
        3
    }
}
