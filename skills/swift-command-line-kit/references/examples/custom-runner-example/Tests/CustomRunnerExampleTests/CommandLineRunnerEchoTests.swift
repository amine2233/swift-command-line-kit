import CommandLineKitCore
import CommandLineKitTesting
import CustomRunnerExample
import Testing

@Suite
struct CommandLineRunnerEchoTests {
    @Test
    func passesTheRunnerContract() async throws {
        try await CommandLineRunnerContract.verify(CommandLineRunnerEcho(), standardInput: true) { scenario in
            let size = CommandLineRunnerContract.largeSize
            switch scenario {
            case .successWithStderr: return CommandRunner.Command("echo", arguments: ["out=3", "err=3"])
            case .silentFailure: return CommandRunner.Command("echo", arguments: ["exit=3"])
            case .largeOutput: return CommandRunner.Command("echo", arguments: ["out=\(size)", "err=\(size)"])
            case .emptyOutput, .singleUse: return CommandRunner.Command("echo")
            case .standardInputData, .standardInputStream: return CommandRunner.Command(
                    "echo",
                    arguments: ["cat"]
                )
            }
        }
    }
}
