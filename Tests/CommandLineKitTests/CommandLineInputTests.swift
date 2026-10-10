import CommandLineKitCore
import CommandLineKitTesting
import Foundation
import Testing
@testable import CommandLineKitInput

@Suite(.timeLimit(.minutes(1)))
struct CommandLineInputStubTests {
    @Test
    func confirmAcceptsYesAndNoInAnyCase() async throws {
        let input = CommandLineInputStub(answers: ["Y", "No", "YES", "n"])

        #expect(try await input.confirm("a", default: nil))
        #expect(try await !input.confirm("b", default: nil))
        #expect(try await input.confirm("c", default: nil))
        #expect(try await !input.confirm("d", default: nil))
    }

    @Test
    func confirmEmptyAnswerMeansTheDefault() async throws {
        let input = CommandLineInputStub(answers: ["", ""])

        #expect(try await input.confirm("Retry?", default: true))
        #expect(try await !input.confirm("Retry?", default: false))
        #expect(await input.prompts == ["Retry? [Y/n]", "Retry? [y/N]"])
    }

    @Test
    func confirmReasksThenGivesUpAfterThreeInvalidAnswers() async {
        let input = CommandLineInputStub(answers: ["maybe", "perhaps", "dunno", "y"])

        let error = await #expect(throws: CommandInputError.self) { try await input.confirm(
            "Go?",
            default: nil
        ) }

        #expect(error?.errorDescription == "Input unavailable: no valid answer")
        #expect(await input.prompts.count == 3)
        #expect(await input.prompts[1].hasPrefix("Please answer y or n."))
    }

    @Test
    func confirmReasksAndAcceptsALaterValidAnswer() async throws {
        let input = CommandLineInputStub(answers: ["huh", "yes"])

        #expect(try await input.confirm("Go?", default: nil))
    }

    @Test
    func endOfInputUsesTheDefaultOtherwiseThrows() async throws {
        let withDefault = CommandLineInputStub(answers: [nil])
        #expect(try await withDefault.confirm("Go?", default: false) == false)

        let without = CommandLineInputStub(answers: [nil])
        await #expect(throws: CommandInputError.self) { try await without.confirm("Go?", default: nil) }
    }

    @Test
    func chooseAcceptsAOneBasedIndexOrTheExactText() async throws {
        let input = CommandLineInputStub(answers: ["2", "gamma"])

        #expect(try await input.choose("Pick", from: ["alpha", "beta", "gamma"]) == "beta")
        #expect(try await input.choose("Pick", from: ["alpha", "beta", "gamma"]) == "gamma")
    }

    @Test
    func chooseReasksAndGivesUp() async {
        let input = CommandLineInputStub(answers: ["0", "9", "nope"])

        await #expect(throws: CommandInputError.self) { try await input.choose("Pick", from: ["a", "b"]) }
        #expect(await input.prompts.count == 3)
    }

    @Test
    func chooseWithNoOptionsDoesNotPrompt() async {
        let input = CommandLineInputStub(answers: ["1"])

        let error = await #expect(throws: CommandInputError.self) { try await input.choose(
            "Pick",
            from: [String]()
        ) }

        #expect(error?.errorDescription == "Input unavailable: no options")
        #expect(await input.prompts.isEmpty)
    }

    @Test
    func promptShowsTheDefaultAndEmptyMeansTheDefault() async throws {
        let input = CommandLineInputStub(answers: ["", "Ada"])

        #expect(try await input.prompt("Name", default: "anonymous", secret: false) == "anonymous")
        #expect(try await input.prompt("Name", default: "anonymous", secret: false) == "Ada")
        #expect(await input.prompts == ["Name [anonymous]", "Name [anonymous]"])
    }

    @Test
    func promptNeverShowsADefaultForASecret() async throws {
        let input = CommandLineInputStub(answers: ["hunter2"])

        _ = try await input.prompt("Token", default: "x", secret: true)

        #expect(await input.prompts == ["Token"])
    }

    @Test
    func readLineReturnsNilAtEndOfInput() async throws {
        let input = CommandLineInputStub(answers: [])

        #expect(try await input.readLine(prompt: "?", secret: false) == nil)
    }

    @Test
    func aRequestIsSingleUseAndWritesNothingBeforeRun() async throws {
        let handler = Recorder()
        let input = CommandLineInputStub(answers: ["a", "b"])
        let request = input.makeRequest("Q", default: nil, secret: false, promptHandler: handler)

        #expect(handler.text.isEmpty)
        #expect(await input.prompts.isEmpty)
        _ = try await request.run()
        #expect(handler.text == "Q\n")
        await #expect(throws: CommandInputError.self) { try await request.run() }
    }

    @Test
    func requestExposesWhatItWasCreatedWith() {
        let request = CommandLineInputStub(answers: []).makeRequest(
            "Q",
            default: "d",
            secret: true,
            promptHandler: nil
        )

        #expect(request.message == "Q")
        #expect(request.defaultAnswer == "d")
        #expect(request.isSecret)
        #expect(request.promptHandler == nil)
    }

    @Test
    func aFlowRetriesAndSucceedsWithBothStubs() async throws {
        struct Deployer {
            let runner: any CommandLineRunner
            let input: any CommandLineInput

            func deploy() async throws {
                while true {
                    do {
                        _ = try await runner.run(.init("swift", arguments: ["build"]))
                        return
                    } catch let CommandError.nonZeroExit(result) {
                        guard try await input.confirm(
                            "Build failed (exit \(result.exitCode)). Retry?",
                            default: true
                        )
                        else { throw CommandError.nonZeroExit(result) }
                    }
                }
            }
        }
        let runner = CommandLineRunnerStub(results: [CommandResult(exitCode: 1), .success])
        let input = CommandLineInputStub(answers: ["y"])

        try await Deployer(runner: runner, input: input).deploy()

        #expect(await runner.commands.count == 2)
        #expect(await input.prompts == ["Build failed (exit 1). Retry? [Y/n]"])
    }

    @Test
    func facadeFollowsTheTaskLocalAndDetachedTasksSeeTheDefault() async throws {
        let stub = CommandLineInputStub(answers: ["scoped"])

        let scoped = try await CommandInput.$current.withValue(stub) {
            try await CommandInput.current.prompt("Q", default: nil, secret: false)
        }
        #expect(scoped == "scoped")

        let seen: Bool = await CommandInput.$current.withValue(stub) {
            await Task.detached { !(CommandInput.current is CommandLineInputStub) }.value
        }
        #expect(seen)
    }
}

final class Recorder: CommandShellDataHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    var text: String {
        lock.withLock { String(decoding: buffer, as: UTF8.self) }
    }

    func handle(_ data: Data) throws {
        lock.withLock { buffer.append(data) }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct CommandLineInputDefaultTests {
    private func notATerminal() throws -> Int32 {
        let descriptor = open("/dev/null", O_RDONLY)
        try #require(descriptor >= 0)
        return descriptor
    }

    @Test
    func nonTerminalWithADefaultReturnsItAndWritesThePromptWithoutReading() async throws {
        let descriptor = try notATerminal()
        defer { close(descriptor) }
        let handler = Recorder()
        let input = CommandLineInputDefault(descriptor: descriptor)

        let answer = try await input.makeRequest(
            "Name [anonymous]",
            default: "anonymous",
            secret: false,
            promptHandler: handler
        ).run()

        #expect(answer == "anonymous")
        #expect(handler.text == "Name [anonymous]\n")
    }

    @Test
    func nonTerminalWithoutADefaultThrowsAtOnce() async throws {
        let descriptor = try notATerminal()
        defer { close(descriptor) }
        let input = CommandLineInputDefault(descriptor: descriptor)
        let clock = ContinuousClock()

        let elapsed = await clock.measure {
            await #expect(throws: CommandInputError.self) {
                try await input.prompt("Name", default: nil, secret: false)
            }
        }

        #expect(elapsed < .seconds(1))
    }

    @Test
    func nonTerminalNeverReturnsADefaultForASecret() async throws {
        let descriptor = try notATerminal()
        defer { close(descriptor) }
        let input = CommandLineInputDefault(descriptor: descriptor)

        await #expect(throws: CommandInputError.self) {
            try await input.makeRequest("Token", default: "x", secret: true, promptHandler: nil).run()
        }
    }

    @Test
    func aPipedAnswerIsNotReadBecauseItIsNotATerminal() async throws {
        var fds: [Int32] = [0, 0]
        try #require(pipe(&fds) == 0)
        defer { close(fds[0]); close(fds[1]) }
        _ = write(fds[1], "typed\n", 6)
        let input = CommandLineInputDefault(descriptor: fds[0])

        let answer = try await input.confirm("Go?", default: true)

        #expect(answer)
    }

    @Test
    func confirmWithoutADefaultOnANonTerminalThrows() async throws {
        let descriptor = try notATerminal()
        defer { close(descriptor) }

        await #expect(throws: CommandInputError.self) {
            try await CommandLineInputDefault(descriptor: descriptor).confirm("Go?", default: nil)
        }
    }

    @Test
    func chooseOnANonTerminalThrows() async throws {
        let descriptor = try notATerminal()
        defer { close(descriptor) }

        await #expect(throws: CommandInputError.self) {
            try await CommandLineInputDefault(descriptor: descriptor).choose("Pick", from: ["a", "b"])
        }
    }

    @Test
    func aSecondRunThrows() async throws {
        let descriptor = try notATerminal()
        defer { close(descriptor) }
        let request = CommandLineInputDefault(descriptor: descriptor)
            .makeRequest("Q", default: "d", secret: false, promptHandler: Recorder())
        _ = try await request.run()

        await #expect(throws: CommandInputError.self) { try await request.run() }
    }

    @Test
    func aRequestWritesNothingBeforeItRuns() async throws {
        let descriptor = try notATerminal()
        defer { close(descriptor) }
        let handler = Recorder()

        _ = CommandLineInputDefault(descriptor: descriptor)
            .makeRequest("Q", default: "d", secret: false, promptHandler: handler)
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(handler.text.isEmpty)
    }

    @Test
    func aFailingPromptHandlerMeansUnavailable() async throws {
        struct Broken: CommandShellDataHandler {
            func handle(_ data: Data) throws {
                throw CommandInputError.unavailable(reason: "x")
            }
        }
        let descriptor = try notATerminal()
        defer { close(descriptor) }

        let error = await #expect(throws: CommandInputError.self) {
            try await CommandLineInputDefault(descriptor: descriptor)
                .makeRequest("Q", default: "d", secret: false, promptHandler: Broken()).run()
        }

        #expect(error?.errorDescription == "Input unavailable: cannot write prompt")
    }

    @Test
    func loggerRecordsTheTerminalDecisionButNeverTheMessage() async throws {
        let descriptor = try notATerminal()
        defer { close(descriptor) }
        let recorder = CommandLoggerRecorder()

        _ = try await CommandLineInputDefault(logger: recorder, descriptor: descriptor)
            .makeRequest("secret question text", default: "d", secret: false, promptHandler: Recorder()).run()

        #expect(recorder.events.map(\.message) == ["stdin is not a terminal"])
        #expect(!recorder.events.contains { $0.message.contains("secret question") })
    }
}
