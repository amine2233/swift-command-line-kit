import CommandLineKitCore
import Foundation

/// Replaces secrets with `***` in streamed chunks, in the returned result and in a thrown ``CommandError``.
///
/// A secret split across two chunks is still found: the handler holds back the last
/// `longestSecret - 1` bytes until more data or `end()` arrives.
public struct CommandMiddlewareRedaction: CommandMiddleware {
    private let secrets: [Data]

    public init(secrets: [String]) {
        self.secrets = secrets.filter { !$0.isEmpty }.map { Data($0.utf8) }
    }

    public func handle(
        _ invocation: CommandInvocation,
        next: @Sendable (CommandInvocation) async throws -> CommandResult
    ) async throws -> CommandResult {
        guard !secrets.isEmpty else { return try await next(invocation) }

        var redacted = invocation
        redacted.outputHandler = invocation.outputHandler.map { RedactingHandler(base: $0, secrets: secrets) }
        redacted.errorHandler = invocation.errorHandler.map { RedactingHandler(base: $0, secrets: secrets) }
        do {
            return try await cleaned(next(redacted))
        } catch let CommandError.nonZeroExit(result) {
            throw CommandError.nonZeroExit(cleaned(result))
        } catch let CommandError.uncaughtSignal(signal, result) {
            throw CommandError.uncaughtSignal(signal, cleaned(result))
        }
    }

    private func cleaned(_ result: CommandResult) -> CommandResult {
        CommandResult(
            exitCode: result.exitCode,
            stdout: Redaction.apply(secrets, to: result.stdout),
            stderr: Redaction.apply(secrets, to: result.stderr)
        )
    }
}

private enum Redaction {
    static let mask = Data("***".utf8)

    static func apply(_ secrets: [Data], to data: Data) -> Data {
        secrets.reduce(data) { current, secret in
            var output = Data()
            var rest = current[...]
            while let range = rest.range(of: secret) {
                output.append(rest[rest.startIndex ..< range.lowerBound])
                output.append(mask)
                rest = rest[range.upperBound...]
            }
            output.append(rest)
            return output
        }
    }
}

private final class RedactingHandler: CommandShellDataHandler, @unchecked Sendable {
    private let base: any CommandShellDataHandler
    private let secrets: [Data]
    private let window: Int
    private let lock = NSLock()
    private var pending = Data()

    init(base: any CommandShellDataHandler, secrets: [Data]) {
        self.base = base
        self.secrets = secrets
        self.window = (secrets.map(\.count).max() ?? 1) - 1
    }

    func handle(_ data: Data) throws {
        lock.lock()
        pending = Redaction.apply(secrets, to: pending + data)
        let cut = max(0, pending.count - window)
        let ready = Data(pending.prefix(cut))
        pending = Data(pending.dropFirst(cut))
        lock.unlock()

        if !ready.isEmpty { try base.handle(ready) }
    }

    func end() {
        lock.lock()
        let rest = pending
        pending = Data()
        lock.unlock()

        if !rest.isEmpty { try? base.handle(rest) }
        base.end()
    }
}
