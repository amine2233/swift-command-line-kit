import CommandLineKitCore
import Foundation

/// The default input: prompts on stderr and reads stdin when it is a terminal.
///
/// - Prompts go to stderr, so stdout stays clean for data.
/// - When stdin is not a terminal it never reads: it returns the default when one is given, and otherwise
/// throws
///   ``CommandInputError/unavailable(reason:)``. A CI job's inherited stdin may stay open forever.
/// - Reading happens on a dedicated thread, never on the cooperative pool.
/// - Secret input is not echoed. If echo cannot be disabled, nothing is read.
public struct CommandLineInputDefault: CommandLineInput {
    private let logger: any CommandLogger
    private let descriptor: Int32

    public init(logger: any CommandLogger = CommandLoggerSilent()) {
        self.init(logger: logger, descriptor: STDIN_FILENO)
    }

    init(logger: any CommandLogger = CommandLoggerSilent(), descriptor: Int32) {
        self.logger = logger
        self.descriptor = descriptor
    }

    public func makeRequest(
        _ message: String,
        default: String?,
        secret: Bool,
        promptHandler: (any CommandShellDataHandler)?
    ) -> any CommandInputRequest {
        CommandInputRequestDefault(
            message: message,
            defaultAnswer: `default`,
            isSecret: secret,
            promptHandler: promptHandler,
            logger: logger,
            descriptor: descriptor
        )
    }
}

struct CommandInputRequestDefault: CommandInputRequest {
    let message: String
    let defaultAnswer: String?
    let isSecret: Bool
    let promptHandler: (any CommandShellDataHandler)?
    let logger: any CommandLogger
    let descriptor: Int32
    private let claim = CommandSingleUse()

    func run() async throws -> String? {
        guard claim.take() else { throw CommandInputError.unavailable(reason: "request already run") }
        guard Terminal.isTerminal(descriptor) else {
            logger.log(.debug, "stdin is not a terminal")
            guard !isSecret, let defaultAnswer else {
                throw CommandInputError.unavailable(reason: "stdin is not a terminal")
            }

            try Terminal.write("\(message)\n", to: promptHandler)
            return defaultAnswer
        }

        let line = try await readOffThePool()
        if line == nil { logger.log(.debug, "end of input") }
        return line
    }

    private func readOffThePool() async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            let thread = Thread {
                continuation.resume(with: Result { try Terminal.ask(self) })
            }
            thread.start()
        }
    }
}
