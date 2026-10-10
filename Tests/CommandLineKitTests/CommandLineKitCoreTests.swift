import CommandLineKitCore
import CommandLineKitTesting
import Foundation
import Testing

@Suite
struct CommandResultTests {
    @Test
    func exitZeroIsSuccessWhateverStderrHolds() throws {
        let result = try CommandResult.evaluate(
            .exited(0),
            stdout: Data("o".utf8),
            stderr: Data("warning".utf8)
        )

        #expect(result.exitCode == 0)
        #expect(result.stderr == Data("warning".utf8))
    }

    @Test
    func nonZeroExitThrows() {
        #expect(throws: CommandError.self) { try CommandResult.evaluate(
            .exited(2),
            stdout: Data(),
            stderr: Data()
        ) }
    }

    @Test
    func signalThrowsWithTheSignalAsExitCode() {
        let error = #expect(throws: CommandError.self) {
            try CommandResult.evaluate(.signaled(9), stdout: Data(), stderr: Data())
        }

        guard case let .uncaughtSignal(signal, result)? = error else {
            Issue.record("expected uncaughtSignal")
            return
        }

        #expect(signal == 9 && result.exitCode == 9)
    }

    @Test
    func errorDescriptionKeepsOnlyTheLastTwoKilobytesOfStderr() {
        let stderr = Data(String(repeating: "a", count: 5_000).utf8) + Data("TAIL".utf8)
        let description = CommandError.nonZeroExit(CommandResult(exitCode: 1, stderr: stderr))
            .errorDescription ?? ""

        #expect(description.hasSuffix("TAIL"))
        #expect(description.count < 2_200)
    }
}

@Suite
struct HandlerTests {
    @Test
    func handleAllSkipsEmptyDataButAlwaysEnds() throws {
        let handler = Collector()

        try handler.handleAll(Data())
        try handler.handleAll(Data("x".utf8))

        #expect(handler.chunkCount == 1)
        #expect(handler.ends == 2)
    }

    @Test
    func fileHandleWriteToABrokenPipeThrowsInsteadOfRaising() throws {
        var descriptors: [Int32] = [0, 0]
        #expect(pipe(&descriptors) == 0)
        signal(SIGPIPE, SIG_IGN)
        close(descriptors[0])
        let writer = FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)

        #expect(throws: (any Error).self) { try writer.handle(Data("x".utf8)) }
    }
}

@Suite
struct StubTests {
    @Test
    func recordsCommandsWhenTheyRun() async throws {
        let stub = CommandLineRunnerStub(results: [CommandResult(exitCode: 0, stdout: Data("one".utf8))])
        _ = stub.makeExecution(CommandRunner.Command("never"), outputHandler: nil, errorHandler: nil)

        let first = try await stub.run(CommandRunner.Command("a"))
        let second = try await stub.run(CommandRunner.Command("b"))

        #expect(first.stdout == Data("one".utf8))
        #expect(second == .success)
        #expect(await stub.commands.map(\.executable) == ["a", "b"])
    }

    @Test
    func nonZeroAnswerThrowsThroughTheSharedSuccessRule() async {
        let stub = CommandLineRunnerStub { _ in CommandResult(exitCode: 5) }

        await #expect(throws: CommandError.self) { try await stub.run(CommandRunner.Command("x")) }
    }

    @Test
    func responderErrorsPropagate() async {
        struct Boom: Error {}
        let stub = CommandLineRunnerStub { _ in throw Boom() }

        await #expect(throws: Boom.self) { try await stub.run(CommandRunner.Command("x")) }
    }

    @Test
    func feedsHandlers() async throws {
        let stub = CommandLineRunnerStub { _ in CommandResult(
            exitCode: 0,
            stdout: Data("out".utf8),
            stderr: Data("err".utf8)
        ) }
        let out = Collector()
        let execution = stub.makeExecution(CommandRunner.Command("x"), outputHandler: out, errorHandler: nil)

        _ = try await execution.run()

        #expect(out.data == Data("out".utf8))
        #expect(out.ends == 1)
    }

    @Test
    func passesTheContractWithAnInterpretedCommandMapping() async throws {
        let stub = CommandLineRunnerStub { command in
            let size = CommandLineRunnerContract.largeSize
            switch command.arguments.first {
            case "success": return CommandResult(
                    exitCode: 0,
                    stdout: Data("out".utf8),
                    stderr: Data("err".utf8)
                )
            case "fail": return CommandResult(exitCode: 3)
            case "large": return CommandResult(
                    exitCode: 0,
                    stdout: Data(count: size),
                    stderr: Data(count: size)
                )
            default: return .success
            }
        }

        try await CommandLineRunnerContract.verify(stub) { scenario in
            switch scenario {
            case .successWithStderr: CommandRunner.Command("x", arguments: ["success"])
            case .silentFailure: CommandRunner.Command("x", arguments: ["fail"])
            case .largeOutput: CommandRunner.Command("x", arguments: ["large"])
            case .emptyOutput, .singleUse, .standardInputData, .standardInputStream:
                CommandRunner.Command("x", arguments: ["empty"])
            }
        }
    }

    @Test
    func contractRejectsARunnerThatBreaksTheSuccessRule() async {
        struct Lenient: CommandLineRunner {
            func makeExecution(
                _ command: CommandRunner.Command,
                outputHandler: (any CommandShellDataHandler)?,
                errorHandler: (any CommandShellDataHandler)?
            ) -> any CommandExecution {
                LenientExecution(command: command, outputHandler: outputHandler, errorHandler: errorHandler)
            }
        }
        struct LenientExecution: CommandExecution {
            let command: CommandRunner.Command
            let outputHandler: (any CommandShellDataHandler)?
            let errorHandler: (any CommandShellDataHandler)?
            func run() async throws -> CommandResult {
                .success
            }
        }

        await #expect(throws: CommandLineRunnerContract.Violation.self) {
            try await CommandLineRunnerContract.verify(Lenient())
        }
    }
}

@Suite
struct LoggerTests {
    @Test
    func printLoggerFiltersByLevel() {
        let logger = CommandLoggerPrint(minimumLevel: .warning)

        logger.log(.info, "hidden")
        #expect(CommandLogLevel.debug < .error)
    }

    @Test
    func recorderKeepsEventsInOrder() {
        let recorder = CommandLoggerRecorder()

        recorder.log(.info, "a")
        recorder.log(.error, "b", metadata: ["k": "v"])

        #expect(recorder.events.map(\.message) == ["a", "b"])
        #expect(recorder.events.last?.metadata == ["k": "v"])
    }
}
