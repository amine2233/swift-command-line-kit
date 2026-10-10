import CommandLineKitCore
import Foundation

extension Process {
    /// Runs a command and returns its output, stdout followed by stderr.
    ///
    /// Any exit status counts as success, as before 1.0.0. A process ended by a signal throws
    /// ``ProcessError``. It runs on ``CommandRunner/current``.
    @available(*, deprecated, message: "Use CommandRunner.run(_:) and read result.stdout")
    public static func command(
        _ command: String,
        arguments: [String],
        pwd: URL? = nil
    ) async throws -> String {
        func text(_ result: CommandResult) -> String {
            [result.stdout, result.stderr]
                .map { String(bytes: $0, encoding: .utf8) ?? "" }
                .joined()
        }

        do {
            let result = try await CommandRunner.run(
                CommandRunner.Command(command, arguments: arguments, workingDirectory: pwd)
            )
            return text(result)
        } catch let CommandError.nonZeroExit(result) {
            return text(result)
        } catch let CommandError.uncaughtSignal(signal, result) {
            throw ProcessError(terminationStatus: signal, output: text(result))
        }
    }

    /// Callback variant of ``command(_:arguments:pwd:)``. It calls back exactly once.
    @available(*, deprecated, message: "Use CommandRunner.run(_:completion:)")
    public static func command(
        _ command: String,
        arguments: [String],
        pwd: URL? = nil,
        completion: @Sendable @escaping (Result<String, Error>) -> Void
    ) {
        Task {
            do {
                try await completion(.success(Self.command(command, arguments: arguments, pwd: pwd)))
            } catch {
                completion(.failure(error))
            }
        }
    }
}

public struct ProcessError: Error {
    public var terminationStatus: Int32
    public var output: String
}
