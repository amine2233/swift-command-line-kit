import CommandLineKitCore
import Foundation

/// Logs start, end and duration of every run through a `CommandLogger`. Never output bytes or environment.
public struct CommandMiddlewareLogging: CommandMiddleware {
    private let logger: any CommandLogger

    public init(logger: any CommandLogger) {
        self.logger = logger
    }

    public func handle(
        _ invocation: CommandInvocation,
        next: @Sendable (CommandInvocation) async throws -> CommandResult
    ) async throws -> CommandResult {
        let executable = invocation.command.executable
        let start = Date()
        func duration() -> String {
            "\(Int(Date().timeIntervalSince(start) * 1_000))"
        }

        logger.log(.info, "starting", metadata: ["executable": executable])
        do {
            let result = try await next(invocation)
            logger.log(
                .info,
                "finished",
                metadata: [
                    "executable": executable,
                    "exitCode": "\(result.exitCode)",
                    "durationMs": duration()
                ]
            )
            return result
        } catch {
            logger.log(.error, "failed", metadata: ["executable": executable, "durationMs": duration()])
            throw error
        }
    }
}
