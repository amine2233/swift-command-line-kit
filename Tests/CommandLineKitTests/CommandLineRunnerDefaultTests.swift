import CommandLineKitCore
import CommandLineKitTesting
import Foundation
import Testing
@testable import CommandLineKit

private func sh(_ script: String) -> CommandRunner.Command {
    CommandRunner.Command("sh", arguments: ["-c", script])
}

@Suite(.timeLimit(.minutes(1)))
struct CommandLineRunnerDefaultTests {
    let runner = CommandLineRunnerDefault()

    @Test
    func passesTheContract() async throws {
        try await CommandLineRunnerContract.verify(runner, standardInput: true)
    }

    @Test
    func successKeepsStderr() async throws {
        let result = try await runner.run(sh("printf out; printf warn >&2"))

        #expect(result.exitCode == 0)
        #expect(result.stdout == Data("out".utf8))
        #expect(result.stderr == Data("warn".utf8))
    }

    @Test
    func nonZeroExitThrowsWithTheResult() async {
        let error = await #expect(throws: CommandError.self) {
            try await runner.run(sh("echo boom >&2; exit 3"))
        }

        guard case let .nonZeroExit(result)? = error else {
            Issue.record("expected nonZeroExit, got \(String(describing: error))")
            return
        }

        #expect(result.exitCode == 3)
        #expect(String(decoding: result.stderr, as: UTF8.self) == "boom\n")
        #expect(error?.errorDescription?.contains("status 3: boom") == true)
    }

    @Test
    func signalThrowsUncaughtSignal() async {
        let error = await #expect(throws: CommandError.self) { try await runner.run(sh("kill -9 $$")) }

        guard case let .uncaughtSignal(signal, result)? = error else {
            Issue.record("expected uncaughtSignal, got \(String(describing: error))")
            return
        }

        #expect(signal == 9)
        #expect(result.exitCode == 9)
    }

    @Test
    func missingExecutableThrowsExplicitly() async {
        let error = await #expect(throws: CommandError.self) {
            try await runner.run(CommandRunner.Command("definitely-not-a-tool"))
        }

        guard case let .executableNotFound(name, searched)? = error else {
            Issue.record("expected executableNotFound, got \(String(describing: error))")
            return
        }

        #expect(name == "definitely-not-a-tool")
        #expect(searched.contains("/opt/homebrew/bin"))
    }

    @Test
    func handlerFailureOnSuccessIsOutputHandling() async {
        struct Failing: CommandShellDataHandler {
            func handle(_ data: Data) throws {
                throw CommandError.outputHandling(reason: "no")
            }
        }

        let error = await #expect(throws: CommandError.self) {
            try await runner.run(sh("printf x"), outputHandler: Failing())
        }

        guard case .outputHandling? = error else {
            Issue.record("expected outputHandling, got \(String(describing: error))")
            return
        }
    }

    @Test
    func executionExposesWhatItWasCreatedWith() {
        let handler = CommandShellDataHandlerEmpty()
        let command = sh("true")

        let execution = runner.makeExecution(command, outputHandler: handler, errorHandler: nil)

        #expect(execution.command == command)
        #expect(execution.outputHandler != nil)
        #expect(execution.errorHandler == nil)
    }

    @Test
    func makingAnExecutionLaunchesNothing() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        _ = runner.makeExecution(sh("touch \(marker.path)"), outputHandler: nil, errorHandler: nil)

        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test
    func secondRunThrows() async throws {
        let execution = runner.makeExecution(sh("true"), outputHandler: nil, errorHandler: nil)
        _ = try await execution.run()

        await #expect(throws: CommandError.self) { try await execution.run() }
    }

    @Test
    func environmentAndWorkingDirectoryAreApplied() async throws {
        let command = CommandRunner.Command(
            "sh",
            arguments: ["-c", "printf \"$KIT_VALUE:$(pwd -P)\""],
            environment: ["KIT_VALUE": "x"],
            workingDirectory: URL(fileURLWithPath: "/")
        )

        let result = try await runner.run(command)

        #expect(String(decoding: result.stdout, as: UTF8.self) == "x:/")
    }

    @Test
    func parallelRunsOnOneRunnerDoNotInterfere() async throws {
        try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0 ..< 8 {
                group.addTask { try await String(
                    decoding: runner.run(sh("printf \(index)")).stdout,
                    as: UTF8.self
                ) }
            }
            var seen: [String] = []
            for try await value in group {
                seen.append(value)
            }
            #expect(seen.sorted() == (0 ..< 8).map(String.init))
        }
    }

    @Test
    func loggerSeesStartAndEndWithoutEnvironmentValues() async throws {
        let recorder = CommandLoggerRecorder()
        let logged = CommandLineRunnerDefault(logger: recorder)

        _ = try await logged.run(CommandRunner.Command(
            "sh",
            arguments: ["-c", "true"],
            environment: ["TOKEN": "s3cr3t"]
        ))
        _ = try? await logged.run(sh("exit 4"))

        let events = recorder.events
        #expect(events.filter { $0.message == "finished" }.count == 2)
        #expect(events.contains { $0.metadata["exitCode"] == "4" })
        #expect(!events
            .contains {
                $0.message.contains("s3cr3t") || $0.metadata.values.contains { $0.contains("s3cr3t") }
            })
    }
}

@Suite(.timeLimit(.minutes(1)))
struct FacadeTests {
    @Test
    func staticRunForwardsToTheTaskLocalRunner() async throws {
        let stub = CommandLineRunnerStub { _ in CommandResult(exitCode: 0, stdout: Data("stubbed".utf8)) }

        let result = try await CommandRunner.$current.withValue(stub) {
            try await CommandRunner.run(CommandRunner.Command("anything", arguments: ["a"]))
        }

        #expect(result.stdout == Data("stubbed".utf8))
        #expect(await stub.commands.map(\.arguments) == [["a"]])
    }

    @Test
    func parallelScopesDoNotInterfere() async throws {
        try await withThrowingTaskGroup(of: Bool.self) { group in
            for index in 0 ..< 10 {
                group.addTask {
                    let stub = CommandLineRunnerStub(results: [])
                    try await CommandRunner.$current.withValue(stub) {
                        _ = try await CommandRunner.run(CommandRunner.Command("tool\(index)"))
                    }
                    return await stub.commands.map(\.executable) == ["tool\(index)"]
                }
            }
            for try await isolated in group {
                #expect(isolated)
            }
        }
    }

    @Test
    func detachedTaskFallsBackToTheDefaultRunner() async throws {
        let stub = CommandLineRunnerStub(results: [])

        try await CommandRunner.$current.withValue(stub) {
            _ = try await Task.detached { try await CommandRunner.run(sh("true")) }.value
        }

        #expect(await stub.commands.isEmpty)
    }

    @Test
    func completionVariantCallsBackOnce() async {
        let result: Result<CommandResult, any Error> = await withCheckedContinuation { continuation in
            CommandRunner.run(sh("printf hi")) { continuation.resume(returning: $0) }
        }

        #expect((try? result.get())?.stdout == Data("hi".utf8))
    }
}

@Suite(.timeLimit(.minutes(1)))
struct ProcessCommandTests {
    @Test
    func returnsStdoutThenStderr() async throws {
        let output = try await Process.command("sh", arguments: ["-c", "printf out; printf err >&2"])

        #expect(output == "outerr")
    }

    @Test
    func nonZeroExitIsStillASuccess() async throws {
        let output = try await Process.command("sh", arguments: ["-c", "echo failed; exit 3"])

        #expect(output == "failed\n")
    }

    @Test
    func signalIsAnError() async {
        await #expect(throws: ProcessError.self) {
            try await Process.command("sh", arguments: ["-c", "kill -9 $$"])
        }
    }

    @Test
    func largeOutputCompletes() async throws {
        let output = try await Process.command("sh", arguments: ["-c", "head -c 4194304 /dev/zero"])

        #expect(output.utf8.count == 4_194_304)
    }

    @Test
    func followsTheTaskLocalRunner() async throws {
        let stub = CommandLineRunnerStub { _ in CommandResult(exitCode: 1, stdout: Data("from stub".utf8)) }

        let output = try await CommandRunner.$current.withValue(stub) {
            try await Process.command("whatever", arguments: [])
        }

        #expect(output == "from stub")
    }

    @Test
    func callbackFiresExactlyOnce() async throws {
        let counter = Collector()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Process.command("sh", arguments: ["-c", "head -c 1048576 /dev/zero"]) { _ in
                try? counter.handle(Data([1]))
                continuation.resume()
            }
        }
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(counter.chunkCount == 1)
    }
}
