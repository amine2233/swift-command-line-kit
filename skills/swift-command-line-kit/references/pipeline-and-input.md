# Middleware, pipelines and input

## Middleware (`CommandLineKitPipeline`)

```swift
import CommandLineKitPipeline

let runner = CommandLineRunnerMiddleware(
    base: CommandLineRunnerDefault(),
    links: [CommandMiddlewareLogging(logger: logger), CommandMiddlewareRedaction(secrets: [token])]
)
```

The first link is the outermost. Nothing runs before `CommandExecution.run()`. Redaction replaces secrets with `***` in streamed chunks, in the returned result and in a thrown `CommandError`.

## Pipelines

```swift
let lines = try await (Command("git", arguments: ["log", "--oneline"]) | Command("wc", arguments: ["-l"]))
    .run(on: runner)
```

Each stage's stdout becomes the next stage's `standardInput`. Piped input ignores `SIGPIPE` for the whole process.

## Input (`CommandLineKitInput`)

```swift
import CommandLineKitInput

let name   = try await CommandInput.current.prompt("Name", default: "anonymous", secret: false)
let token  = try await CommandInput.current.prompt("Token", default: nil, secret: true)
let ok     = try await CommandInput.current.confirm("Continue?", default: true)
let target = try await CommandInput.current.choose("Target", from: ["staging", "production"])
```

Inject `any CommandLineInput` the same way as the runner. Prompts go to stderr, secrets are not echoed, and with stdin not a terminal the default is returned (or an error thrown when there is none).

Retry-on-failure pattern:

```swift
while true {
    do { _ = try await runner.run(build); return }
    catch let CommandError.nonZeroExit(result) {
        guard try await input.confirm("Build failed (exit \(result.exitCode)). Retry?", default: true)
        else { throw CommandError.nonZeroExit(result) }
    }
}
```
