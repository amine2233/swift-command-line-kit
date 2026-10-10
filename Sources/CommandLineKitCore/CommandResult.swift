import Foundation

/// How a process ended.
public enum CommandTermination: Sendable, Equatable {
    case exited(Int32)
    case signaled(Int32)

    public var isSuccess: Bool {
        self == .exited(0)
    }
}

/// What a successful run produced.
public struct CommandResult: Sendable, Equatable {
    /// The exit status; the signal number when the process was signalled.
    public let exitCode: Int32

    public let stdout: Data

    public let stderr: Data

    public init(exitCode: Int32, stdout: Data = Data(), stderr: Data = Data()) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    /// Exit status 0 with no output.
    public static let success = CommandResult(exitCode: 0)

    /// The one success rule every runner applies: exit status 0 is success, whatever stderr holds.
    ///
    /// - Throws: ``CommandError/nonZeroExit(_:)`` or ``CommandError/uncaughtSignal(_:_:)``.
    public static func evaluate(
        _ termination: CommandTermination,
        stdout: Data,
        stderr: Data
    ) throws -> CommandResult {
        switch termination {
        case .exited(0):
            return CommandResult(exitCode: 0, stdout: stdout, stderr: stderr)
        case let .exited(code):
            throw CommandError.nonZeroExit(CommandResult(exitCode: code, stdout: stdout, stderr: stderr))
        case let .signaled(signal):
            throw CommandError.uncaughtSignal(
                signal,
                CommandResult(exitCode: signal, stdout: stdout, stderr: stderr)
            )
        }
    }
}
