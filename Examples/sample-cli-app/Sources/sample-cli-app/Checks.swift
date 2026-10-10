import CommandLineKit
import Foundation
import Synchronization

final class DataCollector: CommandShellDataHandler, Sendable {
    private let state = Mutex((data: Data(), chunks: 0))

    var text: String {
        state.withLock { String(decoding: $0.data, as: UTF8.self) }
    }

    var chunks: Int {
        state.withLock { $0.chunks }
    }

    func handle(_ data: Data) throws {
        state.withLock {
            $0.data.append(data)
            $0.chunks += 1
        }
    }
}

enum Check: String, CaseIterable, Sendable {
    case echo
    case fail
    case silentFail = "silent-fail"
    case warn
    case big
    case stdin
    case completion
    case which

    private static func shell(_ script: String) -> CommandRunner.Command {
        CommandRunner.Command("sh", arguments: ["-c", script])
    }

    private static func text(_ result: CommandResult) -> String {
        String(decoding: result.stdout, as: UTF8.self)
    }

    func run(runner: any CommandLineRunner, timeout: Double, verbose: Bool) async -> Outcome {
        if verbose { diagnostic("[\(rawValue)] starting") }
        return await race(timeout: timeout) { done in
            Task { await done(perform(on: runner, timeout: timeout)) }
        }
    }

    private func perform(on runner: any CommandLineRunner, timeout: Double) async -> Outcome {
        switch self {
        case .echo: await Self.echo(runner)
        case .fail: await Self.fail(runner)
        case .silentFail: await Self.silentFail(runner)
        case .warn: await Self.warn(runner)
        case .big: await Self.big(runner)
        case .stdin: await Self.stdin(runner)
        case .completion: await Self.completion(runner)
        case .which: await Self.which(runner)
        }
    }

    private static func echo(_ runner: any CommandLineRunner) async -> Outcome {
        do {
            let streamed = DataCollector()
            let result = try await runner.run(shell("printf hello"), outputHandler: streamed)
            let detail = "stdout=\(text(result).debugDescription) streamed chunks=\(streamed.chunks)"
            let ok = text(result) == "hello" && streamed.text == "hello" && streamed.chunks > 0
            return ok ? .pass(detail) : .fail(detail)
        } catch {
            return .fail("threw \(error)")
        }
    }

    private static func fail(_ runner: any CommandLineRunner) async -> Outcome {
        do {
            let result = try await runner.run(shell("echo boom >&2; exit 3"))
            return .fail("did not throw, exit \(result.exitCode)")
        } catch let CommandError.nonZeroExit(result) {
            let stderr = String(decoding: result.stderr, as: UTF8.self)
            return result
                .exitCode == 3 && stderr == "boom\n" ?
                .pass("nonZeroExit(3), stderr \(stderr.debugDescription)")
                : .fail("wrong result \(result)")
        } catch {
            return .fail("wrong error \(error)")
        }
    }

    private static func silentFail(_ runner: any CommandLineRunner) async -> Outcome {
        do {
            let result = try await runner.run(shell("exit 3"))
            return .fail("did not throw on a silent exit 3, exit \(result.exitCode)")
        } catch CommandError.nonZeroExit {
            return .pass("nonZeroExit")
        } catch {
            return .fail("wrong error \(error)")
        }
    }

    private static func warn(_ runner: any CommandLineRunner) async -> Outcome {
        do {
            let result = try await runner.run(shell("echo out; echo warning >&2"))
            let ok = text(result) == "out\n" && result.stderr == Data("warning\n".utf8)
            return ok ? .pass("stdout=\(text(result).debugDescription) stderr kept") :
                .fail("returned \(result)")
        } catch {
            return .fail("threw on exit 0 + stderr: \(error)")
        }
    }

    private static func big(_ runner: any CommandLineRunner) async -> Outcome {
        do {
            let result = try await runner
                .run(shell("head -c 1500000 /dev/zero >&2; head -c 1500000 /dev/zero"))
            let ok = result.stdout.count == 1_500_000 && result.stderr.count == 1_500_000
            return ok ? .pass("stdout and stderr 1500000 bytes each") :
                .fail("truncated: \(result.stdout.count)/\(result.stderr.count)")
        } catch {
            return .fail("threw \(String(describing: error).prefix(60))")
        }
    }

    private static func stdin(_ runner: any CommandLineRunner) async -> Outcome {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0, dup2(fds[0], STDIN_FILENO) >= 0 else {
            return .fail("could not install an open stdin pipe")
        }

        do {
            let result = try await runner.run(shell("cat"))
            return .pass("returned \(text(result).debugDescription)")
        } catch {
            return .fail("threw \(error)")
        }
    }

    private static func completion(_ runner: any CommandLineRunner) async -> Outcome {
        let result: Result<CommandResult, any Error> = await withCheckedContinuation { continuation in
            CommandRunner.$current.withValue(runner) {
                CommandRunner.run(shell("printf hi")) { continuation.resume(returning: $0) }
            }
        }
        switch result {
        case let .success(value):
            return text(value) == "hi" ? .pass("completion got \(text(value).debugDescription)") :
                .fail("got \(text(value))")
        case let .failure(error):
            return .fail("completion failure \(error)")
        }
    }

    private static func which(_ runner: any CommandLineRunner) async -> Outcome {
        var notes: [String] = []
        for command in [shell("printf ok"), CommandRunner.Command("env", arguments: ["printf", "ok"])] {
            do {
                try await notes.append("\(command.executable)=\(text(runner.run(command)))")
            } catch {
                return .fail("bare '\(command.executable)' not resolved: \(error)")
            }
        }
        return .pass(notes.joined(separator: " "))
    }
}
