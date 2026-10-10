# Migrating to 1.0

Every removed symbol and what replaces it.

## Overview

1.0.0 replaces the blocking, per-platform API with an injectable async one. Code written for 0.2.x keeps working
until you move to 1.0.0, and 0.2.4 already fixed its behaviour on Linux.

## Run a command and read its output

```swift
// 0.2.x
let version = try CommandRunner.run(
    "/usr/bin/swift",
    argumentHandler: CommandArgumentHandlerString(argument: "--version"),
    outputHandler: CommandOutputHandlerString()
)

// 1.0.0
let result = try await CommandRunner.run(.init("swift", arguments: ["--version"]))
let version = CommandOutputHandlerString().handleOutput(result.stdout)
```

## Stream the output

```swift
// 0.2.x
try CommandRunner.execute("/usr/bin/swift", argumentHandler: arguments, output: CommandShellDataHandlerDefault(),
                          outputHandler: FileHandle.standardOutput, errorHandler: FileHandle.standardError)

// 1.0.0
try await CommandRunner.run(
    .init("swift", arguments: ["build"]),
    outputHandler: FileHandle.standardOutput,
    errorHandler: FileHandle.standardError
)
```

## Removed symbols

| Removed | Use instead |
| --- | --- |
| `CommandRunner.run(_:argumentHandler:outputHandler:verbose:)` | `try await CommandRunner.run(_:)`, then decode `result.stdout` |
| `CommandRunner.runZsh`, `runXcrun` | `CommandRunner.run(.init("zsh", arguments: ["-c", script]))`, `.init("xcrun", …)` |
| `CommandRunner.execute(…)` | `CommandRunner.run(_:outputHandler:errorHandler:)` |
| `CommandArgumentHandler` family | `CommandRunner.Command.arguments` |
| `CommandExecutable`, `CommandExecutableShell`, `CommandShellDataHandlerCompletion` | `CommandLineRunner` and ``CommandExecution`` |
| `CommandError.commandFailed`, `.result`, `.failure` | `.nonZeroExit`, `.launchFailed`, `.executableNotFound`, `.outputHandling` |
| `verbose: Bool` | inject a ``CommandLogger``, for example `CommandLineRunnerDefault(logger: CommandLoggerPrint(minimumLevel: .debug))` |
| `Process.command` | deprecated: `CommandRunner.run`. It still returns stdout followed by stderr and treats any exit status as success |

## Changed

- ``CommandError`` is reshaped. A non-zero exit throws ``CommandError/nonZeroExit(_:)`` with the whole result,
  so the exit code and stderr are in the error.
- `CommandOutputHandlerCodable` requires `T: Decodable & Sendable` and throws ``CommandError/outputHandling(reason:)``.
- `CommandRunner` is now a namespace plus the facade; the protocol is ``CommandLineRunner``.

## Test code that runs commands

```swift
let runner = CommandLineRunnerStub { _ in .success }
try await Deployer(runner: runner).deploy()
#expect(await runner.commands.map(\.arguments) == [["build", "-c", "release"]])
```

For code that reads ``CommandRunner/current``, scope the stub with `CommandRunner.$current.withValue(stub) { … }`.
That value is task-local: under `Task.detached`, a `Thread` or a `DispatchQueue` it falls back to the default
runner, so inject `any CommandLineRunner` there.
