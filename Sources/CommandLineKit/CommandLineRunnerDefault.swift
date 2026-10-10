import CommandLineKitCore
import Foundation

/// The default engine: runs a child process on every platform with one code path.
///
/// Both pipes are drained concurrently, success is decided by the exit status alone, the child's stdin is
/// `/dev/null`, and bare names are resolved through `PATH` and the well-known directories.
public struct CommandLineRunnerDefault: CommandLineRunner {
    private let logger: any CommandLogger

    public init(logger: any CommandLogger = CommandLoggerSilent()) {
        self.logger = logger
    }

    public func makeExecution(
        _ command: CommandRunner.Command,
        outputHandler: (any CommandShellDataHandler)?,
        errorHandler: (any CommandShellDataHandler)?
    ) -> any CommandExecution {
        CommandExecutionDefault(
            command: command,
            outputHandler: outputHandler,
            errorHandler: errorHandler,
            logger: logger
        )
    }
}

final class CommandExecutionDefault: CommandExecution {
    let command: CommandRunner.Command
    let outputHandler: (any CommandShellDataHandler)?
    let errorHandler: (any CommandShellDataHandler)?

    private let logger: any CommandLogger
    private let claim = CommandSingleUse()

    init(
        command: CommandRunner.Command,
        outputHandler: (any CommandShellDataHandler)?,
        errorHandler: (any CommandShellDataHandler)?,
        logger: any CommandLogger
    ) {
        self.command = command
        self.outputHandler = outputHandler
        self.errorHandler = errorHandler
        self.logger = logger
    }

    func run() async throws -> CommandResult {
        guard claim.take() else {
            throw CommandError.launchFailed(executable: command.executable, reason: "already run")
        }

        let spec = ProcessSpec(
            executable: command.executable,
            arguments: command.arguments,
            environment: command.environment,
            workingDirectory: command.workingDirectory,
            standardInput: command.standardInput,
            outputHandler: outputHandler,
            errorHandler: errorHandler
        )

        let clock = ContinuousClockCompat()
        let outcome: ProcessOutcome
        do {
            outcome = try await ProcessRunner.run(spec)
        } catch let error as ProcessRunnerError {
            logger.log(.error, "launch failed", metadata: ["executable": command.executable])
            throw error.commandError
        }

        logger.log(.debug, "resolved", metadata: ["path": outcome.executablePath])
        var metadata = ["executable": command.executable, "durationMs": "\(clock.elapsedMilliseconds)"]
        switch outcome.termination {
        case let .exited(code): metadata["exitCode"] = "\(code)"
        case let .signaled(signal): metadata["signal"] = "\(signal)"
        }
        logger.log(.info, "finished", metadata: metadata)

        let result = try CommandResult.evaluate(
            outcome.termination,
            stdout: outcome.stdout,
            stderr: outcome.stderr
        )
        if let handlerError = outcome.handlerError {
            logger.log(.warning, "stream handler failed", metadata: ["executable": command.executable])
            throw CommandError.outputHandling(reason: "\(handlerError)")
        }
        return result
    }
}

/// Wall-clock duration without `ContinuousClock`, which needs macOS 13.
private struct ContinuousClockCompat {
    private let start = Date()

    var elapsedMilliseconds: Int {
        Int(Date().timeIntervalSince(start) * 1_000)
    }
}
