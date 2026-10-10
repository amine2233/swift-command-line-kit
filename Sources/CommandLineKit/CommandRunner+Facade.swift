import CommandLineKitCore
import Foundation

extension CommandRunner {
    /// The runner the static entry points use. Override it for a scope with
    /// `$current.withValue(_:operation:)`.
    ///
    /// It is a task-local value: under `Task.detached`, a `Thread`, a `DispatchQueue`, and inside handlers
    /// called on the default runner's reader threads, it falls back to ``CommandLineRunnerDefault``. Code
    /// that
    /// needs the override there must inject `any CommandLineRunner` instead.
    @TaskLocal public static var current: any CommandLineRunner = CommandLineRunnerDefault()

    /// Runs a command on ``current``.
    public static func run(
        _ command: Command,
        outputHandler: (any CommandShellDataHandler)? = nil,
        errorHandler: (any CommandShellDataHandler)? = nil
    ) async throws -> CommandResult {
        try await current.run(command, outputHandler: outputHandler, errorHandler: errorHandler)
    }

    /// Runs a command on ``current`` and calls `completion` exactly once.
    public static func run(
        _ command: Command,
        outputHandler: (any CommandShellDataHandler)? = nil,
        errorHandler: (any CommandShellDataHandler)? = nil,
        completion: @escaping @Sendable (Result<CommandResult, any Error>) -> Void
    ) {
        Task {
            do {
                try await completion(.success(run(
                    command,
                    outputHandler: outputHandler,
                    errorHandler: errorHandler
                )))
            } catch {
                completion(.failure(error))
            }
        }
    }
}
