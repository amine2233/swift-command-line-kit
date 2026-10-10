import CommandLineKitCore
import Foundation

/// What a link receives and may rewrite.
public struct CommandInvocation: Sendable {
    public var command: CommandRunner.Command
    public var outputHandler: (any CommandShellDataHandler)?
    public var errorHandler: (any CommandShellDataHandler)?

    public init(
        command: CommandRunner.Command,
        outputHandler: (any CommandShellDataHandler)? = nil,
        errorHandler: (any CommandShellDataHandler)? = nil
    ) {
        self.command = command
        self.outputHandler = outputHandler
        self.errorHandler = errorHandler
    }
}

/// One link of a chain: capture, act, forward. Call `next` zero times (short-circuit), once, or more (retry).
public protocol CommandMiddleware: Sendable {
    func handle(
        _ invocation: CommandInvocation,
        next: @Sendable (CommandInvocation) async throws -> CommandResult
    ) async throws -> CommandResult
}

/// Wraps a runner in links. The first link is the outermost. Nothing runs before ``CommandExecution/run()``.
public struct CommandLineRunnerMiddleware: CommandLineRunner {
    private let base: any CommandLineRunner
    private let links: [any CommandMiddleware]

    public init(base: any CommandLineRunner, links: [any CommandMiddleware]) {
        self.base = base
        self.links = links
    }

    public func makeExecution(
        _ command: CommandRunner.Command,
        outputHandler: (any CommandShellDataHandler)?,
        errorHandler: (any CommandShellDataHandler)?
    ) -> any CommandExecution {
        CommandExecutionMiddleware(
            command: command,
            outputHandler: outputHandler,
            errorHandler: errorHandler,
            base: base,
            links: links
        )
    }
}

private final class CommandExecutionMiddleware: CommandExecution {
    let command: CommandRunner.Command
    let outputHandler: (any CommandShellDataHandler)?
    let errorHandler: (any CommandShellDataHandler)?

    private let base: any CommandLineRunner
    private let links: [any CommandMiddleware]
    private let claim = CommandSingleUse()

    init(
        command: CommandRunner.Command,
        outputHandler: (any CommandShellDataHandler)?,
        errorHandler: (any CommandShellDataHandler)?,
        base: any CommandLineRunner,
        links: [any CommandMiddleware]
    ) {
        self.command = command
        self.outputHandler = outputHandler
        self.errorHandler = errorHandler
        self.base = base
        self.links = links
    }

    func run() async throws -> CommandResult {
        guard claim.take() else {
            throw CommandError.launchFailed(executable: command.executable, reason: "already run")
        }

        let base = base
        let terminal: @Sendable (CommandInvocation) async throws -> CommandResult = { invocation in
            try await base.run(
                invocation.command,
                outputHandler: invocation.outputHandler,
                errorHandler: invocation.errorHandler
            )
        }
        let chain = links.reversed().reduce(terminal) { next, link in
            { invocation in try await link.handle(invocation, next: next) }
        }
        return try await chain(
            CommandInvocation(command: command, outputHandler: outputHandler, errorHandler: errorHandler)
        )
    }
}
