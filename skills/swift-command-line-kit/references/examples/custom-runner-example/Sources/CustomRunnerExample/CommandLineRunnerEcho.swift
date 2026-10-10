import CommandLineKitCore
import Foundation

/// An in-memory runner: no process is started. The command's arguments describe the outcome:
/// `out=<bytes>`, `err=<bytes>` and `exit=<status>`. Writing an engine for another system (swift-subprocess,
/// ssh, docker) follows the same three steps: make an execution, honour the handler contract, call
/// `CommandResult.evaluate`.
public struct CommandLineRunnerEcho: CommandLineRunner {
    public init() {}

    public func makeExecution(
        _ command: CommandRunner.Command,
        outputHandler: (any CommandShellDataHandler)?,
        errorHandler: (any CommandShellDataHandler)?
    ) -> any CommandExecution {
        CommandExecutionEcho(command: command, outputHandler: outputHandler, errorHandler: errorHandler)
    }
}

struct CommandExecutionEcho: CommandExecution {
    let command: CommandRunner.Command
    let outputHandler: (any CommandShellDataHandler)?
    let errorHandler: (any CommandShellDataHandler)?

    private let claim = CommandSingleUse()

    func run() async throws -> CommandResult {
        guard claim.take() else {
            throw CommandError.launchFailed(executable: command.executable, reason: "already run")
        }

        var stdout = Data(repeating: 0x78, count: value(of: "out"))
        if command.arguments.contains("cat") { stdout = await input() }
        let stderr = Data(repeating: 0x79, count: value(of: "err"))
        try outputHandler?.handleAll(stdout)
        try errorHandler?.handleAll(stderr)

        return try CommandResult.evaluate(.exited(Int32(value(of: "exit"))), stdout: stdout, stderr: stderr)
    }

    private func input() async -> Data {
        switch command.standardInput {
        case .nullDevice: Data()
        case let .data(bytes): bytes
        case let .stream(stream): await stream.reduce(into: Data()) { $0.append($1) }
        }
    }

    private func value(of key: String) -> Int {
        command.arguments
            .compactMap { $0.hasPrefix("\(key)=") ? Int($0.dropFirst(key.count + 1)) : nil }
            .first ?? 0
    }
}
