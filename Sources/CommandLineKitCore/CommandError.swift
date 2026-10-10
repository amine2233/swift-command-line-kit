import Foundation

/// The errors of running a command.
public enum CommandError: Error, Sendable, LocalizedError {
    /// No executable was found. `searched` lists every directory looked into.
    case executableNotFound(String, searched: [String] = [])

    /// The process could not be started.
    case launchFailed(executable: String, reason: String)

    /// The process exited with a status other than 0.
    case nonZeroExit(CommandResult)

    /// The process was ended by a signal.
    case uncaughtSignal(Int32, CommandResult)

    /// A stream handler or an output decoder failed.
    case outputHandling(reason: String)

    public var errorDescription: String? {
        switch self {
        case let .executableNotFound(name, searched):
            guard !searched.isEmpty else { return "Executable '\(name)' not found." }

            return "Executable '\(name)' not found. Searched: \(searched.joined(separator: ", "))"
        case let .launchFailed(executable, reason):
            return "Cannot launch \(executable): \(reason)"
        case let .nonZeroExit(result):
            return Self.describe("Command exited with status \(result.exitCode)", result)
        case let .uncaughtSignal(signal, result):
            return Self.describe("Command ended by signal \(signal)", result)
        case let .outputHandling(reason):
            return "Output handling failed: \(reason)"
        }
    }

    private static func describe(_ summary: String, _ result: CommandResult) -> String {
        let tail = (String(bytes: result.stderr.suffix(2_048), encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return tail.isEmpty ? summary : "\(summary): \(tail)"
    }
}
