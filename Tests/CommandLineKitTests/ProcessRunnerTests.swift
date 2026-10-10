import CommandLineKitCore
import Foundation
import Testing
@testable import CommandLineKit

final class Collector: CommandShellDataHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Data] = []
    private var endCount = 0
    private let failing: Bool

    init(failing: Bool = false) {
        self.failing = failing
    }

    var data: Data {
        lock.withLock { chunks.reduce(into: Data()) { $0.append($1) } }
    }

    var chunkCount: Int {
        lock.withLock { chunks.count }
    }

    var hasEmptyChunk: Bool {
        lock.withLock { chunks.contains(where: \.isEmpty) }
    }

    var ends: Int {
        lock.withLock { endCount }
    }

    func handle(_ data: Data) throws {
        lock.withLock { chunks.append(data) }
        if failing { throw CommandError.outputHandling(reason: "handler failure") }
    }

    func end() {
        lock.withLock { endCount += 1 }
    }
}

func shell(_ script: String) -> ProcessSpec {
    ProcessSpec(executable: "sh", arguments: ["-c", script])
}

@Suite(.timeLimit(.minutes(1)))
struct ProcessRunnerTests {
    @Test
    func echoReturnsAndStreamsStdout() async throws {
        let collector = Collector()
        var spec = shell("printf hello")
        spec.outputHandler = collector

        let outcome = try await ProcessRunner.run(spec)

        #expect(outcome.termination == .exited(0))
        #expect(String(decoding: outcome.stdout, as: UTF8.self) == "hello")
        #expect(collector.data == outcome.stdout)
        #expect(collector.ends == 1)
        #expect(!collector.hasEmptyChunk)
    }

    @Test
    func nonZeroExitWithStderrFails() async throws {
        let outcome = try await ProcessRunner.run(shell("echo boom >&2; exit 3"))

        #expect(outcome.termination == .exited(3))
        #expect(String(decoding: outcome.stderr, as: UTF8.self) == "boom\n")
    }

    @Test
    func silentNonZeroExitFails() async throws {
        let outcome = try await ProcessRunner.run(shell("exit 3"))

        #expect(outcome.termination == .exited(3))
        #expect(outcome.stderr.isEmpty)
    }

    @Test
    func stderrOnSuccessIsNotAFailure() async throws {
        let outcome = try await ProcessRunner.run(shell("echo out; echo warning >&2"))

        #expect(outcome.termination.isSuccess)
        #expect(String(decoding: outcome.stderr, as: UTF8.self) == "warning\n")
    }

    @Test
    func signalIsReported() async throws {
        let outcome = try await ProcessRunner.run(shell("kill -9 $$"))

        #expect(outcome.termination == .signaled(9))
    }

    @Test
    func childStdinIsClosed() async throws {
        let outcome = try await ProcessRunner.run(shell("cat; echo done"))

        #expect(String(decoding: outcome.stdout, as: UTF8.self) == "done\n")
    }

    @Test
    func twoMebibytesOnBothStreamsDoNotDeadlock() async throws {
        let size = 2 * 1_024 * 1_024
        let outcome = try await ProcessRunner.run(
            shell("head -c \(size) /dev/zero >&2; head -c \(size) /dev/zero")
        )

        #expect(outcome.termination.isSuccess)
        #expect(outcome.stdout.count == size)
        #expect(outcome.stderr.count == size)
    }

    @Test
    func concurrentRunsDoNotSerialize() async throws {
        let script = "head -c 2097152 /dev/zero >&2; head -c 2097152 /dev/zero"
        let clock = ContinuousClock()
        let single = try await clock.measure { _ = try await ProcessRunner.run(shell(script)) }

        let pair = try await clock.measure {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0 ..< 2 {
                    group.addTask { _ = try await ProcessRunner.run(shell(script)) }
                }
                try await group.waitForAll()
            }
        }

        #expect(pair < single * 2 + .seconds(5))
    }

    @Test
    func handlerErrorIsRecordedAndDrainingContinues() async throws {
        var spec = shell("printf abc")
        spec.outputHandler = Collector(failing: true)

        let outcome = try await ProcessRunner.run(spec)

        #expect(outcome.handlerError != nil)
        #expect(outcome.stdout == Data("abc".utf8))
    }

    @Test
    func sameHandlerOnBothStreamsGetsEachStreamEnded() async throws {
        let collector = Collector()
        var spec = shell("printf out; printf err >&2")
        spec.outputHandler = collector
        spec.errorHandler = collector

        _ = try await ProcessRunner.run(spec)

        #expect(collector.ends == 2)
        #expect(collector.data.count == 6)
    }

    @Test
    func mergedStandardErrorGoesToStdout() async throws {
        var spec = shell("printf out; printf err >&2")
        spec.mergeStandardError = true

        let outcome = try await ProcessRunner.run(spec)

        #expect(outcome.stdout.count == 6)
        #expect(outcome.stderr.isEmpty)
    }

    @Test
    func environmentOverridesAreMergedOverInherited() async throws {
        var spec = shell("printf \"$KIT_VALUE:$HOME\"")
        spec.environment = ["KIT_VALUE": "x"]

        let outcome = try await ProcessRunner.run(spec)

        #expect(String(decoding: outcome.stdout, as: UTF8.self).hasPrefix("x:/"))
    }

    @Test
    func workingDirectoryIsApplied() async throws {
        var spec = shell("pwd -P")
        spec.workingDirectory = URL(fileURLWithPath: "/")

        let outcome = try await ProcessRunner.run(spec)

        #expect(String(decoding: outcome.stdout, as: UTF8.self) == "/\n")
    }

    @Test
    func missingExecutableThrowsWithoutLaunching() async {
        await #expect(throws: ProcessRunnerError.self) {
            try await ProcessRunner.run(ProcessSpec(executable: "definitely-not-a-tool-\(UUID().uuidString)"))
        }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct ExecutableResolutionTests {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeExecutable(named name: String, in directory: URL) throws -> String {
        let path = directory.appendingPathComponent(name).path
        try "#!/bin/sh\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    @Test
    func nameWithSlashIsUsedAsGiven() {
        #expect(ProcessRunner.resolve("/bin/sh", in: []) == "/bin/sh")
        #expect(ProcessRunner.resolve("/no/such/tool", in: ["/bin"]) == nil)
    }

    @Test
    func bareNameResolvesInTheGivenDirectories() {
        #expect(ProcessRunner.resolve("sh", in: ["/nonexistent", "/bin", "/usr/bin"]) != nil)
        #expect(ProcessRunner.resolve("sh", in: []) == nil)
    }

    @Test
    func pathComesFirstThenFallbacksWithoutDuplicatesOrEmptyEntries() {
        let directories = ProcessRunner.searchDirectories(path: "/custom/bin::/usr/bin", home: "/home/me")

        #expect(directories.first == "/custom/bin")
        #expect(directories.filter { $0 == "/usr/bin" }.count == 1)
        #expect(!directories.contains(""))
        #expect(directories.contains("/opt/homebrew/bin"))
        #expect(directories.contains("/home/me/.local/bin"))
    }

    @Test
    func toolOutsideAMinimalPathIsFoundInFallbacks() async throws {
        var spec = shell("printf ok")
        spec.environment = ["PATH": "/nonexistent"]

        let outcome = try await ProcessRunner.run(
            ProcessSpec(executable: "sh", arguments: spec.arguments, environment: spec.environment)
        )

        #expect(String(decoding: outcome.stdout, as: UTF8.self) == "ok")
    }

    @Test
    func unfoundToolFailsExplicitlyListingWhereItLooked() async {
        let name = "definitely-not-a-tool-\(UUID().uuidString)"

        let error = await #expect(throws: ProcessRunnerError.self) {
            try await ProcessRunner.run(ProcessSpec(executable: name, environment: ["PATH": "/custom/bin"]))
        }

        let message = error?.commandError.errorDescription ?? ""
        #expect(message.contains("'\(name)' not found"))
        #expect(message.contains("/custom/bin"))
        #expect(message.contains("/opt/homebrew/bin"))
        #expect(message.contains(".local/bin"))
    }

    @Test
    func directoryNamedLikeTheToolIsSkipped() throws {
        let first = try makeDirectory()
        let second = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        try FileManager.default.createDirectory(
            at: first.appendingPathComponent("kit-tool"),
            withIntermediateDirectories: true
        )
        let expected = try makeExecutable(named: "kit-tool", in: second)

        #expect(ProcessRunner.resolve("kit-tool", in: [first.path, second.path]) == expected)
    }
}
