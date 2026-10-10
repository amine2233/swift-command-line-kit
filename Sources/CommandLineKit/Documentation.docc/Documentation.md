# ``CommandLineKit``

Run command-line programs from Swift with one code path on macOS and Linux, and test code that runs them.

## Overview

The package has five products:

- `CommandLineKitCore` holds the contract: ``CommandLineRunner``, ``CommandExecution``, ``CommandRunner/Command``,
  ``CommandResult``, ``CommandError`` and the handler and logger protocols. It depends on Foundation only.
- `CommandLineKit` is the default engine. It re-exports Core.
- `CommandLineKitInput` asks questions on the terminal.
- `CommandLineKitPipeline` adds middleware, child standard input and pipelines.
- `CommandLineKitTesting` has a test stub, the runner contract checks and a recording logger.

Depend on `any CommandLineRunner` and inject the default engine, the stub or your own:

```swift
struct Deployer {
    let runner: any CommandLineRunner

    func deploy() async throws {
        _ = try await runner.run(.init("swift", arguments: ["build", "-c", "release"]))
    }
}

let deployer = Deployer(runner: CommandLineRunnerDefault())
```

For a one-liner, use the static facade, which runs on ``CommandRunner/current``:

```swift
let result = try await CommandRunner.run(.init("git", arguments: ["status"]))
```

A run succeeds when the process exits with status 0. Whatever it wrote to stderr is in `result.stderr` and never
changes the outcome. A bare executable name is resolved through `PATH`, then through the usual Homebrew, system
and per-user folders. The child's standard input is `/dev/null` unless you set `Command.standardInput`.

This library does not work on iOS because `Process` is not available there.

## Topics

### Articles

- <doc:Migrating-to-1.0>
- <doc:Writing-your-own-runner>
- <doc:Middleware-and-pipelines>

### Running commands

- ``CommandRunner``
- ``CommandLineRunner``
- ``CommandExecution``
- ``CommandLineRunnerDefault``

### Results and errors

- ``CommandResult``
- ``CommandTermination``
- ``CommandError``

### Handling output

- ``CommandShellDataHandler``
- ``CommandShellDataHandlerDefault``
- ``CommandShellDataHandlerEmpty``
- ``CommandOutputHandler``

### Logging

- ``CommandLogger``
- ``CommandLogLevel``
- ``CommandLoggerSilent``
- ``CommandLoggerPrint``
