import CommandLineKit
import CommandLineKitCore
import CommandLineKitPipeline
import CommandLineKitTesting
import Foundation
import Testing

private struct Tag: CommandMiddleware {
    let name: String
    let log: Log

    func handle(
        _ invocation: CommandInvocation,
        next: @Sendable (CommandInvocation) async throws -> CommandResult
    ) async throws -> CommandResult {
        log.add("\(name)>")
        defer { log.add("<\(name)") }
        return try await next(invocation)
    }
}

private struct ShortCircuit: CommandMiddleware {
    func handle(
        _ invocation: CommandInvocation,
        next: @Sendable (CommandInvocation) async throws -> CommandResult
    ) async throws -> CommandResult {
        CommandResult(exitCode: 0, stdout: Data("cached".utf8))
    }
}

private struct Retry: CommandMiddleware {
    func handle(
        _ invocation: CommandInvocation,
        next: @Sendable (CommandInvocation) async throws -> CommandResult
    ) async throws -> CommandResult {
        do { return try await next(invocation) } catch { return try await next(invocation) }
    }
}

private final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func add(_ entry: String) {
        lock.lock()
        entries.append(entry)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

private final class Sink: CommandShellDataHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var endCount = 0

    func handle(_ data: Data) throws {
        lock.lock()
        bytes.append(data)
        lock.unlock()
    }

    func end() {
        lock.lock()
        endCount += 1
        lock.unlock()
    }

    var text: String {
        String(decoding: bytes, as: UTF8.self)
    }

    var ends: Int {
        endCount
    }
}

private func sh(_ script: String) -> CommandRunner.Command {
    CommandRunner.Command("sh", arguments: ["-c", script])
}

@Suite
struct CommandMiddlewareTests {
    @Test
    func linksRunOutermostFirstAndNothingLaunchesBeforeRun() async throws {
        let log = Log()
        let stub = CommandLineRunnerStub(results: [])
        let runner = CommandLineRunnerMiddleware(
            base: stub,
            links: [Tag(name: "a", log: log), Tag(name: "b", log: log)]
        )

        let execution = runner.makeExecution(
            CommandRunner.Command("x"),
            outputHandler: nil,
            errorHandler: nil
        )
        #expect(log.all.isEmpty)
        _ = try await execution.run()

        #expect(log.all == ["a>", "b>", "<b", "<a"])
        #expect(await stub.commands.count == 1)
    }

    @Test
    func shortCircuitSkipsTheBase() async throws {
        let stub = CommandLineRunnerStub(results: [])
        let runner = CommandLineRunnerMiddleware(base: stub, links: [ShortCircuit()])

        let result = try await runner.run(CommandRunner.Command("x"))

        #expect(result.stdout == Data("cached".utf8))
        #expect(await stub.commands.isEmpty)
    }

    @Test
    func aLinkMayCallNextTwice() async throws {
        let stub = CommandLineRunnerStub(results: [CommandResult(exitCode: 1), .success])
        let runner = CommandLineRunnerMiddleware(base: stub, links: [Retry()])

        _ = try await runner.run(CommandRunner.Command("x"))

        #expect(await stub.commands.count == 2)
    }

    @Test
    func secondRunThrows() async throws {
        let runner = CommandLineRunnerMiddleware(base: CommandLineRunnerStub(results: []), links: [])
        let execution = runner.makeExecution(
            CommandRunner.Command("x"),
            outputHandler: nil,
            errorHandler: nil
        )
        _ = try await execution.run()

        await #expect(throws: CommandError.self) { try await execution.run() }
    }
}

@Suite
struct CommandPipelineTests {
    private let runner = CommandLineRunnerDefault()

    @Test
    func standardInputReachesTheChild() async throws {
        let command = CommandRunner.Command("cat", standardInput: .data(Data("hello".utf8)))

        let result = try await runner.run(command)

        #expect(String(decoding: result.stdout, as: UTF8.self) == "hello")
    }

    @Test
    func aChildThatStopsReadingDoesNotHangOrCrash() async throws {
        let big = Data(repeating: 0x78, count: 4 * 1_024 * 1_024)
        let command = CommandRunner.Command("head", arguments: ["-c", "1"], standardInput: .data(big))

        let result = try await runner.run(command)

        #expect(result.stdout == Data("x".utf8))
    }

    @Test
    func stagesFeedEachOther() async throws {
        let out = Sink()
        let err = Sink()

        let results = try await (sh("printf 'b\\na\\nb\\n'; printf e1 >&2") | sh("sort -u; printf e2 >&2"))
            .run(on: runner, outputHandler: out, errorHandler: err).stages

        #expect(out.text == "a\nb\n")
        #expect(results.count == 2)
        #expect(err.text == "e1e2")
        #expect(err.ends == 1)
    }

    @Test
    func pipelineThroughTheStubRecordsStagesInOrder() async throws {
        let stub = CommandLineRunnerStub { command in
            command.executable == "a" ? CommandResult(exitCode: 0, stdout: Data("x".utf8)) : .success
        }

        _ = try await (CommandRunner.Command("a") | CommandRunner.Command("b")).run(on: stub)

        let commands = await stub.commands
        #expect(commands.map(\.executable) == ["a", "b"])
        #expect(commands[1].standardInput == .data(Data("x".utf8)))
    }

    @Test
    func theLastFailingStageIsReportedAfterAllStagesRan() async throws {
        let pipeline = sh("exit 3") | sh("cat; exit 4") | sh("cat")

        do {
            _ = try await pipeline.run(on: runner)
            Issue.record("expected a failure")
        } catch let CommandPipelineError.stageFailed(index, _, completed) {
            #expect(index == 1)
            #expect(completed.count == 3)
        }
    }

    @Test
    func aMissingExecutableStopsThePipeline() async throws {
        let stub = CommandLineRunnerStub { command in
            if command.executable == "missing" { throw CommandError.executableNotFound("missing") }
            return .success
        }

        do {
            _ = try await (CommandRunner.Command("a") | CommandRunner.Command("missing") | CommandRunner
                .Command("c"))
                .run(on: stub)
            Issue.record("expected a failure")
        } catch let CommandPipelineError.stageFailed(index, _, completed) {
            #expect(index == 1)
            #expect(completed.count == 1)
            #expect(await stub.commands.count == 2)
        }
    }

    @Test
    func emptyPipelineThrows() async throws {
        await #expect(throws: CommandPipelineError.self) {
            try await CommandPipeline(stages: []).run(on: CommandLineRunnerStub(results: []))
        }
    }

    @Test
    func streamingGivesTheSameResultAsBuffered() async throws {
        for mode in [CommandPipeline.Mode.buffered, .streaming] {
            let out = Sink()
            let pipeline = CommandPipeline(
                .command(sh("printf 'b\\na\\nb\\n'")),
                .command(sh("sort -u")),
                .command(sh("tr a-z A-Z")),
                mode: mode
            )

            let result = try await pipeline.run(on: runner, outputHandler: out)

            #expect(out.text == "A\nB\n")
            #expect(result.stages.count == 3)
            #expect(out.ends == 1)
        }
    }

    @Test
    func streamingMovesEightMebibytesAndSurvivesAnEarlyExit() async throws {
        let size = 8 * 1_024 * 1_024
        let out = Sink()
        let big = CommandPipeline(
            .command(sh("head -c \(size) /dev/zero")),
            .command(sh("cat")),
            .command(sh("wc -c")),
            mode: .streaming
        )
        _ = try await big.run(on: runner, outputHandler: out)
        #expect(out.text.trimmingCharacters(in: .whitespacesAndNewlines) == "\(size)")

        let early = CommandPipeline(
            .command(sh("head -c \(size) /dev/zero")),
            .command(sh("head -c 1")),
            mode: .streaming
        )
        let result = try await early.run(on: runner)
        #expect(result.last.stdout.count == 1)
    }

    @Test
    func mergeConcatenatesInOrder() async throws {
        let out = Sink()
        let pipeline = CommandPipeline(
            .merge([sh("printf a"), sh("printf b")]),
            .command(sh("cat")),
            mode: .streaming
        )

        let result = try await pipeline.run(on: runner, outputHandler: out)

        #expect(out.text == "ab")
        #expect(result.stages.map(\.count) == [2, 1])
    }

    @Test
    func aMergeAfterTheFirstStageIsUnsupported() async throws {
        let pipeline = CommandPipeline(.command(sh("true")), .merge([sh("true")]))

        await #expect(throws: CommandPipelineError.self) { try await pipeline.run(on: runner) }
    }

    @Test
    func lastStageModeIgnoresEarlierFailures() async throws {
        let pipeline = CommandPipeline(.command(sh("exit 3")), .command(sh("cat")), failure: .lastStage)

        let result = try await pipeline.run(on: runner)

        #expect(result.stages.count == 2)
    }
}

@Suite
struct CommandMiddlewareLinksTests {
    @Test
    func redactionHidesASecretSplitAcrossChunks() async throws {
        let out = Sink()
        let runner = CommandLineRunnerMiddleware(
            base: CommandLineRunnerDefault(),
            links: [CommandMiddlewareRedaction(secrets: ["s3cret"])]
        )

        let result = try await runner.run(
            sh("printf 'token=s3'; sleep 0.2; printf 'cret done'"),
            outputHandler: out
        )

        #expect(out.text == "token=*** done")
        #expect(String(decoding: result.stdout, as: UTF8.self) == "token=*** done")
        #expect(out.ends == 1)
    }

    @Test
    func redactionCleansAThrownResult() async throws {
        let runner = CommandLineRunnerMiddleware(
            base: CommandLineRunnerStub(results: [CommandResult(
                exitCode: 2,
                stderr: Data("bad s3cret".utf8)
            )]),
            links: [CommandMiddlewareRedaction(secrets: ["s3cret"])]
        )

        do {
            _ = try await runner.run(CommandRunner.Command("x"))
            Issue.record("expected a failure")
        } catch let CommandError.nonZeroExit(result) {
            #expect(String(decoding: result.stderr, as: UTF8.self) == "bad ***")
        }
    }

    @Test
    func loggingReportsStartAndFinishWithoutOutput() async throws {
        let recorder = CommandLoggerRecorder()
        let runner = CommandLineRunnerMiddleware(
            base: CommandLineRunnerStub(results: []),
            links: [CommandMiddlewareLogging(logger: recorder)]
        )

        _ = try await runner.run(CommandRunner.Command("x"))

        #expect(recorder.events.map(\.message) == ["starting", "finished"])
    }
}
