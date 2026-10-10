import CommandLineKitCore
import Foundation

/// What a finished child process produced.
struct ProcessOutcome {
    let executablePath: String
    let termination: CommandTermination
    let stdout: Data
    let stderr: Data
    /// The first error thrown by a stream handler, if any. Draining continues after it.
    let handlerError: (any Error)?
}

/// What to run.
struct ProcessSpec {
    var executable: String
    var arguments: [String] = []
    /// Merged over the inherited environment.
    var environment: [String: String] = [:]
    var workingDirectory: URL?
    var standardInput: CommandInput = .nullDevice
    /// Send stderr into the stdout pipe, so both streams are one.
    var mergeStandardError = false
    var outputHandler: (any CommandShellDataHandler)?
    var errorHandler: (any CommandShellDataHandler)?
}

enum ProcessRunnerError: Error {
    case executableNotFound(String, searched: [String])
    case launchFailed(executable: String, reason: String)

    var commandError: CommandError {
        switch self {
        case let .executableNotFound(name, searched): .executableNotFound(name, searched: searched)
        case let .launchFailed(executable, reason): .launchFailed(executable: executable, reason: reason)
        }
    }
}

/// The single execution engine behind every legacy entry point.
///
/// Both pipes are drained concurrently on dedicated threads until EOF, the termination handler is set before
/// launch, and success is decided by the exit status alone. The run completes once stdout EOF, stderr EOF and
/// termination have all happened.
enum ProcessRunner {
    /// Launches the process and calls `completion` exactly once, on a Foundation thread.
    static func start(
        _ spec: ProcessSpec,
        completion: @escaping @Sendable (Result<ProcessOutcome, ProcessRunnerError>) -> Void
    ) {
        let process = Process()
        let environment = mergedEnvironment(spec.environment)

        let directories = searchDirectories(path: environment["PATH"], home: environment["HOME"])
        guard let path = resolve(spec.executable, in: directories) else {
            completion(.failure(.executableNotFound(spec.executable, searched: directories)))
            return
        }

        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = spec.arguments
        process.currentDirectoryURL = spec.workingDirectory
        if !spec.environment.isEmpty {
            process.environment = environment
        }
        let inputPipe: Pipe?
        switch spec.standardInput {
        case .nullDevice:
            inputPipe = nil
            process.standardInput = FileHandle.nullDevice
        case .data, .stream:
            let pipe = Pipe()
            inputPipe = pipe
            process.standardInput = pipe
        }

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        let errorPipe: Pipe? = spec.mergeStandardError ? nil : Pipe()
        process.standardError = errorPipe ?? outputPipe

        let state = RunState(
            executablePath: path,
            pendingEvents: errorPipe == nil ? 2 : 3,
            completion: completion
        )
        process.terminationHandler = { finished in
            let termination: CommandTermination = finished.terminationReason == .uncaughtSignal
                ? .signaled(finished.terminationStatus)
                : .exited(finished.terminationStatus)
            state.recordTermination(termination)
        }

        do {
            try process.run()
        } catch {
            completion(.failure(.launchFailed(executable: spec.executable, reason: "\(error)")))
            return
        }

        if let inputPipe {
            feed(spec.standardInput, to: inputPipe)
        }
        drain(outputPipe.fileHandleForReading, into: .stdout, handler: spec.outputHandler, state: state)
        if let errorPipe {
            drain(errorPipe.fileHandleForReading, into: .stderr, handler: spec.errorHandler, state: state)
        }
    }

    /// Runs the process and suspends until it completes, without holding a cooperative-pool thread.
    static func run(_ spec: ProcessSpec) async throws -> ProcessOutcome {
        try await withCheckedThrowingContinuation { continuation in
            start(spec) { continuation.resume(with: $0) }
        }
    }

    // MARK: - Resolution

    private static func mergedEnvironment(_ overrides: [String: String]) -> [String: String] {
        ProcessInfo.processInfo.environment.merging(overrides) { _, override in override }
    }

    /// Where a bare name is looked up after `PATH`, for processes started with a minimal environment
    /// (GUI apps, launchd, CI): Homebrew, MacPorts, the system, and the usual per-user bin folders.
    static func fallbackDirectories(home: String?) -> [String] {
        let home = home ?? NSHomeDirectory()
        return [
            "/usr/local/bin", "/opt/homebrew/bin", "/opt/homebrew/sbin", "/opt/local/bin", "/snap/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
            "\(home)/.local/bin", "\(home)/bin", "\(home)/.cargo/bin", "\(home)/.swiftly/bin"
        ]
    }

    /// `PATH` entries first (empty entries skipped), then the fallback directories, without duplicates.
    static func searchDirectories(path: String?, home: String?) -> [String] {
        let fromPath = (path ?? "").split(separator: ":", omittingEmptySubsequences: true).map(String.init)
        var seen = Set<String>()
        return (fromPath + fallbackDirectories(home: home)).filter { seen.insert($0).inserted }
    }

    /// A name containing `/` is used as given. Otherwise the first executable regular file found in
    /// `directories` wins.
    static func resolve(_ executable: String, in directories: [String]) -> String? {
        let fileManager = FileManager.default

        func isExecutableFile(_ path: String) -> Bool {
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
                && fileManager.isExecutableFile(atPath: path)
        }

        if executable.contains("/") {
            return isExecutableFile(executable) ? executable : nil
        }
        return directories.map { "\($0)/\(executable)" }.first(where: isExecutableFile)
    }

    // MARK: - Draining

    /// Writes off the cooperative pool, then closes the pipe. A child that exits early only stops the writer:
    /// the rest of the input is discarded.
    ///
    /// `SIGPIPE` is ignored for the whole process, because a write to a closed pipe would kill the host.
    private static func feed(_ input: CommandInput, to pipe: Pipe) {
        signal(SIGPIPE, SIG_IGN)
        let writer = pipe.fileHandleForWriting
        switch input {
        case .nullDevice:
            break
        case let .data(bytes):
            Thread {
                try? writer.write(contentsOf: bytes)
                try? writer.close()
            }.start()
        case let .stream(stream):
            let queue = DispatchQueue(label: "command-line-kit.stdin")
            Task {
                var broken = false
                for await chunk in stream where !broken {
                    broken = await withCheckedContinuation { (continuation: CheckedContinuation<
                        Bool,
                        Never
                    >) in
                        queue.async {
                            continuation.resume(returning: (try? writer.write(contentsOf: chunk)) == nil)
                        }
                    }
                }
                try? writer.close()
            }
        }
    }

    private static func drain(
        _ handle: FileHandle,
        into stream: RunState.Stream,
        handler: (any CommandShellDataHandler)?,
        state: RunState
    ) {
        let thread = Thread {
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }

                state.append(chunk, to: stream)
                do {
                    try handler?.handle(chunk)
                } catch {
                    state.recordHandlerError(error)
                }
            }
            handler?.end()
            state.recordEndOfStream()
        }
        thread.start()
    }
}

/// The only `@unchecked Sendable` type of the engine: buffers, counters and the first handler error, all
/// guarded by one lock.
private final class RunState: @unchecked Sendable {
    enum Stream {
        case stdout
        case stderr
    }

    private let executablePath: String
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    private var termination: CommandTermination?
    private var handlerError: (any Error)?
    private var pendingEvents: Int
    private var completion: (@Sendable (Result<ProcessOutcome, ProcessRunnerError>) -> Void)?

    init(
        executablePath: String,
        pendingEvents: Int,
        completion: @escaping @Sendable (Result<ProcessOutcome, ProcessRunnerError>) -> Void
    ) {
        self.executablePath = executablePath
        self.pendingEvents = pendingEvents
        self.completion = completion
    }

    func append(_ chunk: Data, to stream: Stream) {
        lock.lock()
        defer { lock.unlock() }

        switch stream {
        case .stdout: stdout.append(chunk)
        case .stderr: stderr.append(chunk)
        }
    }

    func recordHandlerError(_ error: any Error) {
        lock.lock()
        defer { lock.unlock() }

        if handlerError == nil { handlerError = error }
    }

    func recordTermination(_ newTermination: CommandTermination) {
        lock.lock()
        termination = newTermination
        lock.unlock()
        finishEvent()
    }

    func recordEndOfStream() {
        finishEvent()
    }

    private func finishEvent() {
        lock.lock()
        pendingEvents -= 1
        guard pendingEvents == 0, let termination, let completion else {
            lock.unlock()
            return
        }

        self.completion = nil
        let outcome = ProcessOutcome(
            executablePath: executablePath,
            termination: termination,
            stdout: stdout,
            stderr: stderr,
            handlerError: handlerError
        )
        lock.unlock()
        completion(.success(outcome))
    }
}
