# Writing your own runner

Run commands through swift-subprocess, over SSH, in a container or in memory, without forking this package.

## Overview

A new engine is a separate package that depends on `CommandLineKitCore` and, for its tests, on
`CommandLineKitTesting`. It never needs the default engine.

Implement two types: a ``CommandLineRunner`` that creates executions, and a ``CommandExecution`` that runs one command.

```swift
public struct MyRunner: CommandLineRunner {
    public func makeExecution(
        _ command: CommandRunner.Command,
        outputHandler: (any CommandShellDataHandler)?,
        errorHandler: (any CommandShellDataHandler)?
    ) -> any CommandExecution {
        MyExecution(command: command, outputHandler: outputHandler, errorHandler: errorHandler)
    }
}
```

In ``CommandExecution/run()``:

1. Throw if the execution already ran. ``CommandSingleUse`` does this for you.
2. Run the command and feed the handlers with every chunk.
3. Call ``CommandResult/evaluate(_:stdout:stderr:)`` so success means exit status 0 whatever stderr holds.

## The handler contract

- Calls to one stream's handler are serial and in order.
- Different streams may run concurrently.
- `end()` is called exactly once per stream.
- All calls happen before `run` returns or throws.
- `handle(_:)` is never called with empty data.

A runner that cannot stream calls `handler.handleAll(data)` once per stream after the command ends.

## Check it

```swift
@Test func passesTheContract() async throws {
    try await CommandLineRunnerContract.verify(MyRunner()) { scenario in
        // map each scenario to a command your engine understands; the default is `sh -c`
    }
}
```

`Examples/custom-runner-example` in the repository is a complete in-memory runner built this way.
