import CommandLineKitCore
import Foundation

public enum CommandPipelineError: Error, Sendable, LocalizedError {
    /// The last failing stage, once every started stage has exited (like `set -o pipefail`).
    case stageFailed(index: Int, underlying: CommandError, completed: [[CommandResult]])
    case emptyPipeline
    case unsupported(reason: String)

    public var errorDescription: String? {
        switch self {
        case let .stageFailed(index, underlying, _):
            "Pipeline stage \(index) failed. \(underlying.errorDescription ?? "\(underlying)")"
        case .emptyPipeline:
            "A pipeline needs at least one command."
        case let .unsupported(reason):
            "Unsupported pipeline: \(reason)"
        }
    }
}

public struct CommandPipelineResult: Sendable {
    /// One array per stage, one result per command (several for a merge).
    public let stages: [[CommandResult]]

    public var last: CommandResult {
        stages.last?.last ?? .success
    }
}

/// `a | b | c`: each stage's stdout becomes the next stage's ``CommandRunner/Command/standardInput``.
///
/// The runner must honour `standardInput` (`.data` for `.buffered`, `.stream` for `.streaming`).
public struct CommandPipeline: Sendable {
    public enum Stage: Sendable {
        case command(CommandRunner.Command)
        /// Commands run one after the other and their stdout is concatenated, like `(a; b)`. First stage
        /// only.
        case merge([CommandRunner.Command])
    }

    public enum Mode: Sendable {
        /// Stages run in order; memory is bounded by the largest stage output.
        case buffered
        /// All stages run at once. The stream between stages is unbounded, so a slow stage buffers its input.
        case streaming
    }

    public enum Failure: Sendable {
        /// Any failing stage fails the run; the last one is reported.
        case pipefail
        /// Only the final stage decides.
        case lastStage
    }

    public let stages: [Stage]
    public let mode: Mode
    public let failure: Failure

    public init(_ stages: Stage..., mode: Mode = .buffered, failure: Failure = .pipefail) {
        self.init(stages: stages, mode: mode, failure: failure)
    }

    public init(stages: [Stage], mode: Mode = .buffered, failure: Failure = .pipefail) {
        self.stages = stages
        self.mode = mode
        self.failure = failure
    }

    /// Every stage's stderr goes to `errorHandler` (serially, then `end()` once); only the last stage's
    /// stdout goes to `outputHandler`.
    ///
    /// - Throws: ``CommandPipelineError``. A launch failure stops a buffered pipeline; an exit failure does
    /// not.
    public func run(
        on runner: any CommandLineRunner,
        outputHandler: (any CommandShellDataHandler)? = nil,
        errorHandler: (any CommandShellDataHandler)? = nil
    ) async throws -> CommandPipelineResult {
        try validate()
        defer {
            outputHandler?.end()
            errorHandler?.end()
        }

        let stderr = CommandShellDataHandlerTee(forwardingTo: errorHandler, forwardsEnd: false)
        let outcomes = switch mode {
        case .buffered: try await runBuffered(on: runner, output: outputHandler, error: stderr)
        case .streaming: await runStreaming(on: runner, output: outputHandler, error: stderr)
        }
        if let failed = failingStage(in: outcomes) {
            throw CommandPipelineError.stageFailed(
                index: failed.index,
                underlying: failed.error,
                completed: outcomes.map(\.results)
            )
        }
        return CommandPipelineResult(stages: outcomes.map(\.results))
    }

    private func validate() throws {
        guard !stages.isEmpty else { throw CommandPipelineError.emptyPipeline }

        for (index, stage) in stages.enumerated() {
            guard case let .merge(commands) = stage else { continue }
            guard !commands.isEmpty else { throw CommandPipelineError.emptyPipeline }
            guard index == 0 else {
                throw CommandPipelineError.unsupported(reason: "a merge can only be the first stage")
            }
        }
    }

    private func runBuffered(
        on runner: any CommandLineRunner,
        output: (any CommandShellDataHandler)?,
        error: any CommandShellDataHandler
    ) async throws -> [StageOutcome] {
        var outcomes: [StageOutcome] = []
        var input = CommandInput.nullDevice
        for (index, stage) in stages.enumerated() {
            let isLast = index == stages.count - 1
            let outcome = await Self.run(
                stage,
                input: input,
                on: runner,
                output: CommandShellDataHandlerTee(forwardingTo: isLast ? output : nil, forwardsEnd: false),
                error: error
            )
            if let launchError = outcome.launchError {
                throw CommandPipelineError.stageFailed(
                    index: index,
                    underlying: launchError,
                    completed: outcomes.map(\.results)
                )
            }
            outcomes.append(outcome)
            input = .data(outcome.results.reduce(into: Data()) { $0.append($1.stdout) })
        }
        return outcomes
    }

    private func runStreaming(
        on runner: any CommandLineRunner,
        output: (any CommandShellDataHandler)?,
        error: any CommandShellDataHandler
    ) async -> [StageOutcome] {
        let links = (1 ..< stages.count).map { _ in AsyncStream.makeStream(of: Data.self) }
        let stages = stages
        return await withTaskGroup(of: (Int, StageOutcome).self) { group in
            for (index, stage) in stages.enumerated() {
                let upstream = index > 0 ? links[index - 1].stream : nil
                let downstream = index < links.count ? links[index].continuation : nil
                let forwardedOutput = index == stages.count - 1 ? output : nil
                group.addTask {
                    defer { downstream?.finish() }
                    let tee = CommandShellDataHandlerTee(
                        forwardingTo: forwardedOutput,
                        forwardsEnd: false,
                        observe: { downstream?.yield($0) }
                    )
                    let outcome = await Self.run(
                        stage,
                        input: upstream.map(CommandInput.stream) ?? .nullDevice,
                        on: runner,
                        output: tee,
                        error: error
                    )
                    return (index, outcome)
                }
            }
            var outcomes = [StageOutcome?](repeating: nil, count: stages.count)
            for await (index, outcome) in group {
                outcomes[index] = outcome
            }
            return outcomes.compactMap { $0 }
        }
    }

    private static func run(
        _ stage: Stage,
        input: CommandInput,
        on runner: any CommandLineRunner,
        output: any CommandShellDataHandler,
        error: any CommandShellDataHandler
    ) async -> StageOutcome {
        let commands: [CommandRunner.Command] = switch stage {
        case let .command(command): [command]
        case let .merge(members): members
        }

        var outcome = StageOutcome()
        for (position, original) in commands.enumerated() {
            var command = original
            if position == 0, case .command = stage { command.standardInput = input }
            do {
                try await outcome.results.append(runner.run(
                    command,
                    outputHandler: output,
                    errorHandler: error
                ))
            } catch let commandError as CommandError {
                outcome.record(commandError)
                return outcome
            } catch {
                outcome.record(.launchFailed(executable: command.executable, reason: "\(error)"))
                return outcome
            }
        }
        return outcome
    }

    private func failingStage(in outcomes: [StageOutcome]) -> (index: Int, error: CommandError)? {
        let candidates = outcomes.indices.compactMap { index -> (index: Int, error: CommandError)? in
            guard let error = outcomes[index].failure else { return nil }

            if case .uncaughtSignal(13, _) = error, index + 1 < outcomes.count,
               outcomes[index + 1].failure == nil {
                return nil
            }
            return (index, error)
        }
        switch failure {
        case .pipefail: return candidates.last
        case .lastStage: return candidates.last { $0.index == outcomes.count - 1 }
        }
    }
}

private struct StageOutcome: Sendable {
    var results: [CommandResult] = []
    var failure: CommandError?
    var launchError: CommandError?

    mutating func record(_ error: CommandError) {
        failure = error
        switch error {
        case let .nonZeroExit(result), let .uncaughtSignal(_, result): results.append(result)
        case .executableNotFound, .launchFailed: launchError = error
        case .outputHandling: break
        }
    }
}

public func | (lhs: CommandRunner.Command, rhs: CommandRunner.Command) -> CommandPipeline {
    CommandPipeline(.command(lhs), .command(rhs))
}

public func | (lhs: CommandPipeline, rhs: CommandRunner.Command) -> CommandPipeline {
    CommandPipeline(stages: lhs.stages + [.command(rhs)], mode: lhs.mode, failure: lhs.failure)
}
