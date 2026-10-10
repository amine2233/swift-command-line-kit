# Integration

## Command

```swift
CommandRunner.Command(
    "git",                         // path, or a bare name resolved via PATH and well-known directories
    arguments: ["status"],
    environment: ["LANG": "C"],    // merged over the inherited environment
    workingDirectory: URL(fileURLWithPath: "/tmp"),
    standardInput: .nullDevice     // .data(Data) | .stream(AsyncStream<Data>)
)
```

## Running

```swift
// injected runner
let result = try await runner.run(.init("git", arguments: ["status"]))
String(decoding: result.stdout, as: UTF8.self)   // result.exitCode, result.stdout, result.stderr

// static facade (uses CommandRunner.current, default CommandLineRunnerDefault)
let status = try await CommandRunner.run(.init("git", arguments: ["status"]))

// streaming while still capturing
try await CommandRunner.run(
    .init("swift", arguments: ["build"]),
    outputHandler: FileHandle.standardOutput,
    errorHandler: FileHandle.standardError
)

// callback form, completion called exactly once
CommandRunner.run(.init("ls")) { result in ... }
```

Override the facade runner for a scope: `CommandRunner.$current.withValue(stub) { ... }`.

## Errors

```swift
do { _ = try await runner.run(command) }
catch let CommandError.nonZeroExit(result) { /* result.exitCode, result.stderr */ }
catch let CommandError.uncaughtSignal(signal, result) { }
catch CommandError.executableNotFound(let name, let searched) { }
catch CommandError.launchFailed(let executable, let reason) { }
```

`CommandError` is `LocalizedError`; its description includes the last 2 KiB of stderr.

## Handlers

Implement `CommandShellDataHandler` (`handle(_:)` per chunk, `end()` once). Calls per stream are serial and ordered, never empty, and finish before `run` returns. `FileHandle` already conforms. `CommandShellDataHandlerTee` (in `CommandLineKitPipeline`) observes a stream while forwarding it.

## Logging

`CommandLineRunnerDefault(logger:)` takes a `CommandLogger`: `CommandLoggerPrint(minimumLevel: .debug)`, `CommandLoggerSilent()`, or your own. Loggers never receive output bytes or environment values.

## Migrating from pre-1.0

Output/error stream APIs were removed in favour of handlers. See the DocC article "Migrating to 1.0" in `Sources/CommandLineKit/Documentation.docc/`.
