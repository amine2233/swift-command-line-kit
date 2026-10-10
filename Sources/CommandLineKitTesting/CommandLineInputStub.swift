import CommandLineKitCore
import CommandLineKitInput
import Foundation

/// An input that asks nobody: it answers from a script and records every prompt.
///
/// Answers are used in order, one per request. `nil` simulates end of input, and so does running out of
/// answers.
/// The shared parsing rules of `confirm`, `choose` and `prompt` run on top of it, so tests exercise the real
/// logic. Prompts are recorded when a request runs, not when it is made.
public actor CommandLineInputStub: CommandLineInput {
    private var answers: [String?]

    /// The message of every request that ran, in order.
    public private(set) var prompts: [String] = []

    public init(answers: [String?]) {
        self.answers = answers
    }

    public nonisolated func makeRequest(
        _ message: String,
        default: String?,
        secret: Bool,
        promptHandler: (any CommandShellDataHandler)?
    ) -> any CommandInputRequest {
        CommandInputRequestStub(
            stub: self,
            message: message,
            defaultAnswer: `default`,
            isSecret: secret,
            promptHandler: promptHandler
        )
    }

    fileprivate func nextAnswer(for message: String) -> String? {
        prompts.append(message)
        return answers.isEmpty ? nil : answers.removeFirst()
    }
}

private struct CommandInputRequestStub: CommandInputRequest {
    let stub: CommandLineInputStub
    let message: String
    let defaultAnswer: String?
    let isSecret: Bool
    let promptHandler: (any CommandShellDataHandler)?
    private let claim = CommandSingleUse()

    func run() async throws -> String? {
        guard claim.take() else { throw CommandInputError.unavailable(reason: "request already run") }

        try? promptHandler?.handle(Data("\(message)\n".utf8))
        return await stub.nextAnswer(for: message)
    }
}
