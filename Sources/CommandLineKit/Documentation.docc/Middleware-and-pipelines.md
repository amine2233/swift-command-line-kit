# Middleware and pipelines

Wrap any runner in reusable links, feed a child's standard input, and pipe commands like a shell does.

## Overview

`CommandLineKitPipeline` depends on `CommandLineKitCore` only, so it works with the default engine, the stub or
your own runner. Add the product next to the engine:

```swift
.product(name: "CommandLineKitPipeline", package: "command-line-kit")
```

## Wrap a runner in middleware

A `CommandLineRunnerMiddleware` is itself a `CommandLineRunner`: inject it where you inject the engine. The first
link is the outermost. Nothing runs until `run()`.

```swift
let runner = CommandLineRunnerMiddleware(
    base: CommandLineRunnerDefault(),
    links: [
        CommandMiddlewareLogging(logger: logger),
        CommandMiddlewareRedaction(secrets: [token])
    ]
)
let deployer = Deployer(runner: runner)
```

- `CommandMiddlewareLogging` logs start, end and duration through a `CommandLogger`. It never logs output bytes
  or environment values.
- `CommandMiddlewareRedaction` replaces each secret with `***` in streamed chunks, in the returned result and in a
  thrown `CommandError`. A secret split across two chunks is still found.

### Write your own link

A link receives a `CommandInvocation` (command and handlers), may rewrite it, and calls `next` zero times
(short-circuit), once, or more (retry):

```swift
struct Retry: CommandMiddleware {
    func handle(
        _ invocation: CommandInvocation,
        next: @Sendable (CommandInvocation) async throws -> CommandResult
    ) async throws -> CommandResult {
        do { return try await next(invocation) } catch { return try await next(invocation) }
    }
}
```

To capture output, replace `invocation.outputHandler` with a `CommandShellDataHandlerTee`, which forwards each
chunk to the original handler and reports it to a closure.

## Feed a child's standard input

`Command.standardInput` defaults to `.nullDevice`. Use `.data` for bytes you already have, or `.stream` for chunks
that arrive over time; the input ends when the stream finishes.

```swift
let result = try await runner.run(.init("sort", standardInput: .data(Data("b\na\n".utf8))))
```

A child that exits before reading everything does not fail the run: the rest is discarded. The default engine
ignores `SIGPIPE` for the whole process once any input is piped, because a write to a closed pipe would otherwise
kill the host. A runner that cannot feed a child ignores `standardInput`.

## Pipe commands

`a | b` connects the stdout of one stage to the stdin of the next, through any runner:

```swift
let count = try await (Command("git", arguments: ["log", "--oneline"]) | Command("wc", arguments: ["-l"]))
    .run(on: runner)
print(count.last.stdout)
```

For more control build the pipeline from stages:

```swift
let pipeline = CommandPipeline(
    .merge([.init("cat", arguments: ["a.log"]), .init("cat", arguments: ["b.log"])]),   // (cat a; cat b)
    .command(.init("grep", arguments: ["error"])),
    .command(.init("sort", arguments: ["-u"])),
    mode: .streaming
)
let result = try await pipeline.run(on: runner, outputHandler: FileHandle.standardOutput)
print(result.stages.map { $0.map(\.exitCode) })   // [[0, 0], [0], [0]]
```

- **Modes.** `.buffered` (default) runs the stages in order and keeps each stage's output in memory.
  `.streaming` starts all stages at once and moves chunks as they arrive; the link between two stages is
  unbounded, so a slow stage buffers its input. The runner must honour `.data` for buffered and `.stream` for
  streaming.
- **Merge.** `.merge` runs its commands in order and concatenates their stdout. It can only be the first stage.
- **Failures.** By default (`.pipefail`) the run throws `CommandPipelineError.stageFailed` for the last failing
  stage once every started stage has exited, with every result attached. An upstream stage ended by `SIGPIPE`
  because a later stage exited early is not a failure. `failure: .lastStage` lets the final stage decide.
- **Handlers.** The `errorHandler` receives the stderr of every stage, serially, and `end()` once. Only the last
  stage's stdout reaches `outputHandler`.
- **Launch failures.** A missing executable stops a buffered pipeline before the next stage starts. In a
  streaming pipeline the other stages are already running and are awaited.

Every stage goes through the runner you pass, so a middleware runner logs and redacts each one.

## Test a pipeline

The stub records each stage in order; the next stage's input is in `standardInput`:

```swift
let stub = CommandLineRunnerStub { command in
    command.executable == "a" ? CommandResult(exitCode: 0, stdout: Data("x".utf8)) : .success
}
_ = try await (Command("a") | Command("b")).run(on: stub)
#expect(await stub.commands[1].standardInput == .data(Data("x".utf8)))
```

To check your own runner honours `standardInput`, call
`CommandLineRunnerContract.verify(MyRunner(), standardInput: true)`.
