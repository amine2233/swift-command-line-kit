import CommandLineKitCore
import Foundation

/// Executable checks of what every `CommandLineRunner` promises. Run them against your own runner.
///
/// It throws instead of using `#expect`, so it works under Swift Testing and XCTest alike.
public enum CommandLineRunnerContract {
    public enum Scenario: Sendable, CaseIterable {
        case successWithStderr
        case silentFailure
        case largeOutput
        case emptyOutput
        case singleUse
        case standardInputData
        case standardInputStream

        var needsStandardInput: Bool {
            self == .standardInputData || self == .standardInputStream
        }

        /// What the scenario feeds to the child; the command must echo it back, like `cat`.
        var standardInput: CommandInput {
            switch self {
            case .standardInputData: .data(CommandLineRunnerContract.standardInputPayload)
            case .standardInputStream:
                .stream(AsyncStream { continuation in
                    let payload = CommandLineRunnerContract.standardInputPayload
                    let half = payload.count / 2
                    continuation.yield(payload.prefix(half))
                    continuation.yield(payload.dropFirst(half))
                    continuation.finish()
                })
            default: .nullDevice
            }
        }

        /// The scenario as a POSIX `sh` command, for runners that can run `sh`.
        public var posixShellCommand: CommandRunner.Command {
            let size = CommandLineRunnerContract.largeSize
            let script = switch self {
            case .successWithStderr: "printf out; printf err >&2; exit 0"
            case .silentFailure: "exit 3"
            case .largeOutput: "head -c \(size) /dev/zero >&2; head -c \(size) /dev/zero"
            case .emptyOutput, .singleUse: "exit 0"
            case .standardInputData, .standardInputStream: "cat"
            }
            return CommandRunner.Command("sh", arguments: ["-c", script])
        }
    }

    public struct Violation: Error, CustomStringConvertible {
        public let description: String
    }

    /// What the standard-input scenarios write and expect back.
    public static let standardInputPayload = Data(repeating: 0x61, count: 200_000)

    /// The size of each stream in the `largeOutput` scenario, in bytes.
    public static let largeSize = 2 * 1_024 * 1_024

    /// - Parameters:
    ///   - runner: The runner to check.
    ///   - standardInput: Also check that `.data` and `.stream` input reach the child.
    ///   - command: Maps a scenario to a command your runner understands. Defaults to `sh -c`.
    public static func verify(
        _ runner: any CommandLineRunner,
        standardInput: Bool = false,
        command: @Sendable (Scenario) -> CommandRunner.Command = { $0.posixShellCommand }
    ) async throws {
        for scenario in Scenario.allCases where standardInput || !scenario.needsStandardInput {
            do {
                var mapped = command(scenario)
                mapped.standardInput = scenario.standardInput
                try await check(scenario, runner: runner, command: mapped)
            } catch let violation as Violation {
                throw Violation(description: "\(scenario): \(violation.description)")
            }
        }
    }

    private struct Outcome {
        var result: CommandResult?
        var failure: CommandError?

        /// What the handlers must have received: the result, or the one inside a failure.
        var captured: CommandResult? {
            if let result { return result }

            switch failure {
            case let .nonZeroExit(result)?, let .uncaughtSignal(_, result)?: return result
            default: return nil
            }
        }
    }

    private static func check(
        _ scenario: Scenario,
        runner: any CommandLineRunner,
        command: CommandRunner.Command
    ) async throws {
        let out = RecordingHandler()
        let err = RecordingHandler()
        let execution = runner.makeExecution(command, outputHandler: out, errorHandler: err)

        var outcome = Outcome()
        do {
            outcome.result = try await execution.run()
        } catch let error as CommandError {
            outcome.failure = error
        }
        try await assertOutcome(of: scenario, outcome, execution: execution)

        try out.verifyContract(named: "outputHandler", expecting: outcome.captured?.stdout)
        try err.verifyContract(named: "errorHandler", expecting: outcome.captured?.stderr)
    }

    private static func assertOutcome(
        of scenario: Scenario,
        _ outcome: Outcome,
        execution: any CommandExecution
    ) async throws {
        switch scenario {
        case .successWithStderr: try assertSuccessKeepsStderr(outcome)
        case .silentFailure: try assertSilentFailure(outcome)
        case .largeOutput: try assertLargeOutput(outcome)
        case .emptyOutput: try assertEmptyOutput(outcome)
        case .standardInputData, .standardInputStream:
            guard outcome.result?.stdout == standardInputPayload else {
                throw Violation(description: "standard input must reach the child unchanged")
            }
        case .singleUse:
            guard await secondRunThrows(execution) else {
                throw Violation(description: "a second run() must throw")
            }
        }
    }

    private static func assertSuccessKeepsStderr(_ outcome: Outcome) throws {
        guard let result = outcome.result, result.exitCode == 0 else {
            throw Violation(description: "exit 0 must succeed, got \(String(describing: outcome.failure))")
        }
        guard !result.stdout.isEmpty, !result.stderr.isEmpty else {
            throw Violation(description: "stdout and stderr must both be returned on success")
        }
    }

    private static func assertSilentFailure(_ outcome: Outcome) throws {
        guard case let .nonZeroExit(failed)? = outcome.failure, failed.exitCode == 3 else {
            let got = String(describing: outcome.failure)
            throw Violation(description: "exit 3 with no stderr must throw nonZeroExit(3), got \(got)")
        }
    }

    private static func assertLargeOutput(_ outcome: Outcome) throws {
        guard let result = outcome.result, result.stdout.count == largeSize,
              result.stderr.count == largeSize else {
            throw Violation(description: "2 MiB on both streams must be returned in full")
        }
    }

    private static func assertEmptyOutput(_ outcome: Outcome) throws {
        guard let result = outcome.result, result.stdout.isEmpty, result.stderr.isEmpty else {
            throw Violation(description: "no output must give empty results")
        }
    }

    private static func secondRunThrows(_ execution: any CommandExecution) async -> Bool {
        do {
            _ = try await execution.run()
            return false
        } catch {
            return true
        }
    }
}

/// Records calls and checks the handler contract: serial, non-empty chunks, `end()` exactly once.
private final class RecordingHandler: CommandShellDataHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var inFlight = 0
    private var overlapped = false
    private var sawEmptyChunk = false
    private var ends = 0

    var data: Data {
        lock.lock()
        defer { lock.unlock() }

        return buffer
    }

    func handle(_ data: Data) throws {
        lock.lock()
        inFlight += 1
        if inFlight > 1 { overlapped = true }
        if data.isEmpty { sawEmptyChunk = true }
        buffer.append(data)
        inFlight -= 1
        lock.unlock()
    }

    func end() {
        lock.lock()
        ends += 1
        lock.unlock()
    }

    func verifyContract(named name: String, expecting expected: Data?) throws {
        lock.lock()
        defer { lock.unlock() }

        guard !overlapped
        else { throw CommandLineRunnerContract.Violation(description: "\(name) calls must be serial") }
        guard !sawEmptyChunk
        else {
            throw CommandLineRunnerContract.Violation(description: "\(name) must never get empty data")
        }
        guard ends == 1
        else {
            throw CommandLineRunnerContract
                .Violation(description: "\(name).end() must be called exactly once, was \(ends)")
        }

        if let expected, expected != buffer {
            throw CommandLineRunnerContract
                .Violation(description: "\(name) must receive every byte of the result")
        }
    }
}
