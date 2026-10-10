---
name: swift-command-line-kit
description: Integrate and use swift-command-line-kit (CommandLineKit) in a Swift package or app to run external processes through an injectable `CommandLineRunner`, stream or capture stdout/stderr, pipe commands, add logging/redaction middleware, ask the user questions in a CLI, and test it all without spawning processes. Use when the user wants to run shell commands from Swift, add CommandLineKit as a dependency, write or test a Swift CLI that launches subprocesses, or drive the package's sample CLI (`sample-cli-app`) to check behaviour.
---

# swift-command-line-kit

Swift 6 library to run child processes behind a protocol (`any CommandLineRunner`), so production code uses the real engine and tests use a stub. Package URL: `https://github.com/amine2233/swift-command-line-kit.git` (macOS 11+, Linux).

## Pick the products

| Product | Use it for |
|---|---|
| `CommandLineKit` | Default engine (`CommandLineRunnerDefault`) and the `CommandRunner.run` facade. The usual choice. |
| `CommandLineKitCore` | The contract only (`CommandLineRunner`, `CommandResult`, `CommandError`). For packages that write their own runner. |
| `CommandLineKitPipeline` | Middleware (logging, redaction) and `a \| b` pipelines. |
| `CommandLineKitInput` | Prompt, confirm, choose, secret input; safe when stdin is not a terminal. |
| `CommandLineKitTesting` | `CommandLineRunnerStub`, `CommandLineInputStub`, `CommandLineRunnerContract`. Test targets only. |

## Integrate

1. Add the dependency. The package identity is `swift-command-line-kit`:

```swift
.package(url: "https://github.com/amine2233/swift-command-line-kit.git", from: "1.0.0")
// target:
.product(name: "CommandLineKit", package: "swift-command-line-kit")
// test target:
.product(name: "CommandLineKitTesting", package: "swift-command-line-kit")
```

2. Depend on the protocol, never on the engine, and inject:

```swift
import CommandLineKit

struct Deployer {
    let runner: any CommandLineRunner

    func deploy() async throws {
        _ = try await runner.run(.init("swift", arguments: ["build", "-c", "release"]))
    }
}

let deployer = Deployer(runner: CommandLineRunnerDefault())
```

3. Handle errors with `CommandError`: `.nonZeroExit(result)`, `.uncaughtSignal`, `.executableNotFound`, `.launchFailed`, `.outputHandling`. Success is exit status 0; stderr never makes a run fail.

4. Write the test with the stub (Swift Testing), no process involved:

```swift
@Test func deployBuildsRelease() async throws {
    let runner = CommandLineRunnerStub { _ in .success }
    try await Deployer(runner: runner).deploy()
    #expect(await runner.commands.map(\.arguments) == [["build", "-c", "release"]])
}
```

## Rules to follow when writing code with it

- Inject `any CommandLineRunner`; use the static `CommandRunner.run(...)` only in leaf code (it reads a task-local that is lost under `Task.detached`, threads and dispatch queues).
- A `CommandExecution` is single-use; make a new one per run.
- Stream with `outputHandler:`/`errorHandler:` (e.g. `FileHandle.standardOutput`); the returned `CommandResult` still holds the full output.
- Feed a child with `Command.standardInput` (`.data`, `.stream`, `.nullDevice`).
- Prompts go to stderr; with stdin not a terminal, `CommandLineInput` returns the default or throws instead of hanging.

## References

Read only what the task needs:

- `references/integration.md`: full runner API, `Command` fields, errors, streaming, migration notes.
- `references/pipeline-and-input.md`: middleware links, pipelines, prompts.
- `references/testing.md`: stubs, scripted input, the runner contract check, writing your own runner.
- `references/cli.md`: driving the sample CLI and `test.sh` to verify behaviour on macOS and Linux.
- `references/examples/sample-cli-app`: a complete Swift CLI (ArgumentParser) built on the library.
- `references/examples/custom-runner-example`: an in-memory runner that depends on `CommandLineKitCore` only.
