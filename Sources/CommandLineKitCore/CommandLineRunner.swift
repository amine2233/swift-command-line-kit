import Foundation

/// The injected engine: it creates one ``CommandExecution`` per run.
///
/// Depend on `any CommandLineRunner` and inject the default engine, the test stub or your own.
public protocol CommandLineRunner: Sendable {
    /// Creates the execution of one command. Nothing is launched until ``CommandExecution/run()``.
    func makeExecution(
        _ command: CommandRunner.Command,
        outputHandler: (any CommandShellDataHandler)?,
        errorHandler: (any CommandShellDataHandler)?
    ) -> any CommandExecution
}

extension CommandLineRunner {
    /// Creates an execution and runs it.
    public func run(
        _ command: CommandRunner.Command,
        outputHandler: (any CommandShellDataHandler)? = nil,
        errorHandler: (any CommandShellDataHandler)? = nil
    ) async throws -> CommandResult {
        try await makeExecution(command, outputHandler: outputHandler, errorHandler: errorHandler).run()
    }
}

/// One run of one command. Single-use: a second ``run()`` throws.
public protocol CommandExecution: Sendable {
    var command: CommandRunner.Command { get }
    var outputHandler: (any CommandShellDataHandler)? { get }
    var errorHandler: (any CommandShellDataHandler)? { get }

    /// Runs the command.
    ///
    /// - Throws: ``CommandError``. Success is exit status 0, whatever stderr holds.
    func run() async throws -> CommandResult
}
