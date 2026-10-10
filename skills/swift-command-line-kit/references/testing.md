# Testing

Add `CommandLineKitTesting` to test targets only.

## Runner stub

```swift
let always = CommandLineRunnerStub { _ in .success }
let queued = CommandLineRunnerStub(results: [.success, CommandResult(exitCode: 0, stdout: Data("ok".utf8))])
let failing = CommandLineRunnerStub { _ in throw CommandError.nonZeroExit(CommandResult(exitCode: 2)) }

await always.commands   // every command that ran, in order (recorded when an execution runs)
```

The stub applies the same success rule as the default engine, feeds the handlers, and is single-use per execution. `results:` answers in turn, then `CommandResult.success`.

## Input stub

```swift
let input = CommandLineInputStub(answers: ["y"])
// ... run code under test ...
await input.prompts   // the questions that were asked
```

## Runner contract

Run the executable contract against any runner, including your own:

```swift
@Test func passesTheContract() async throws {
    try await CommandLineRunnerContract.verify(MyRunner(), standardInput: true) { scenario in
        scenario.posixShellCommand   // default mapping; map to something your engine understands otherwise
    }
}
```

It throws instead of using `#expect`, so it works under Swift Testing and XCTest.

## Writing your own runner

Depend on `CommandLineKitCore` (and `CommandLineKitTesting` for tests), never on `CommandLineKit`.

1. Implement `CommandLineRunner.makeExecution(_:outputHandler:errorHandler:)` returning a `CommandExecution`.
2. In `run()`: throw if already run (`CommandSingleUse` does it), run the command, feed handlers, finish with `CommandResult.evaluate(_:stdout:stderr:)`.
3. Handler rules: serial per stream, in order, `end()` exactly once, never empty chunks, all calls before `run` returns. A runner that cannot stream calls `handler.handleAll(data)` once per stream.

Full example: `references/examples/custom-runner-example`.
