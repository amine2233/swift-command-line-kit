import CommandLineKitCore
import Foundation

/// A runner that spawns nothing: it records the commands and answers from a closure or a queue.
///
/// Its executions apply the same success rule as the default engine, feed the handlers, and
/// are single-use. Commands are recorded when an execution runs, not when it is made.
public actor CommandLineRunnerStub: CommandLineRunner {
    private let respond: (@Sendable (CommandRunner.Command) throws -> CommandResult)?
    private var queue: [CommandResult]

    /// Every command that ran, in order.
    public private(set) var commands: [CommandRunner.Command] = []

    public init(_ respond: @escaping @Sendable (CommandRunner.Command) throws -> CommandResult) {
        self.respond = respond
        self.queue = []
    }

    /// Answers with each result in turn, then with ``CommandResult/success``.
    public init(results: [CommandResult]) {
        self.respond = nil
        self.queue = results
    }

    public nonisolated func makeExecution(
        _ command: CommandRunner.Command,
        outputHandler: (any CommandShellDataHandler)?,
        errorHandler: (any CommandShellDataHandler)?
    ) -> any CommandExecution {
        CommandExecutionStub(
            stub: self,
            command: command,
            outputHandler: outputHandler,
            errorHandler: errorHandler
        )
    }

    fileprivate func answer(_ command: CommandRunner.Command) throws -> CommandResult {
        commands.append(command)
        if let respond { return try respond(command) }

        return queue.isEmpty ? .success : queue.removeFirst()
    }
}

private final class CommandExecutionStub: CommandExecution {
    let command: CommandRunner.Command
    let outputHandler: (any CommandShellDataHandler)?
    let errorHandler: (any CommandShellDataHandler)?

    private let stub: CommandLineRunnerStub
    private let claim = CommandSingleUse()

    init(
        stub: CommandLineRunnerStub,
        command: CommandRunner.Command,
        outputHandler: (any CommandShellDataHandler)?,
        errorHandler: (any CommandShellDataHandler)?
    ) {
        self.stub = stub
        self.command = command
        self.outputHandler = outputHandler
        self.errorHandler = errorHandler
    }

    func run() async throws -> CommandResult {
        guard claim.take() else {
            throw CommandError.launchFailed(executable: command.executable, reason: "already run")
        }

        let answer = try await stub.answer(command)

        var handlerError: (any Error)?
        do {
            try outputHandler?.handleAll(answer.stdout)
        } catch {
            handlerError = error
        }
        do {
            try errorHandler?.handleAll(answer.stderr)
        } catch {
            handlerError = handlerError ?? error
        }

        let result = try CommandResult.evaluate(
            .exited(answer.exitCode),
            stdout: answer.stdout,
            stderr: answer.stderr
        )
        if let handlerError {
            throw CommandError.outputHandling(reason: "\(handlerError)")
        }
        return result
    }
}
