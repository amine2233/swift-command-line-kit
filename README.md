# Command Line Kit

This framework provides a simple and easy-to-use command line interface for Swift applications.

## Installation

Add this package to your Package.swift as dependency and to your target.

```swift
dependencies: [
    .package(
        url: "https://github.com/amine2233/swift-command-line-kit.git",
        from: "1.0.1"
    )
],
targets: [
    .target(name: "App", dependencies: [
        .product(name: "CommandLineKit", package: "command-line-kit"),
    ]),
    .testTarget(name: "AppTests", dependencies: [
        .product(name: "CommandLineKitTesting", package: "command-line-kit"),
    ]),
]
```

`CommandLineKitCore` (the contract only, no engine) is for packages that implement their own runner.

Import in your code

```swift
import CommandLineKit
```

## Usage

Depend on `any CommandLineRunner` and inject the default engine, a stub or your own:

```swift
struct Deployer {
    let runner: any CommandLineRunner

    func deploy() async throws {
        _ = try await runner.run(.init("swift", arguments: ["build", "-c", "release"]))
    }
}

let deployer = Deployer(runner: CommandLineRunnerDefault())
```

One-liner through the static facade, and streaming:

```swift
let status = try await CommandRunner.run(.init("git", arguments: ["status"]))

try await CommandRunner.run(
    .init("swift", arguments: ["build"]),
    outputHandler: FileHandle.standardOutput,
    errorHandler: FileHandle.standardError
)
```

A test, with no process:

```swift
@Test func deployBuildsRelease() async throws {
    let runner = CommandLineRunnerStub { _ in .success }
    try await Deployer(runner: runner).deploy()
    #expect(await runner.commands.map(\.arguments) == [["build", "-c", "release"]])
}
```

A run succeeds when the process exits with status 0; stderr never changes that. See the DocC articles
"Migrating to 1.0" and "Writing your own runner".

## Middleware and pipelines

`CommandLineKitPipeline` wraps any runner in links (logging, redaction, your own) and pipes commands:

```swift
let runner = CommandLineRunnerMiddleware(
    base: CommandLineRunnerDefault(),
    links: [CommandMiddlewareLogging(logger: logger), CommandMiddlewareRedaction(secrets: [token])]
)

let lines = try await (Command("git", arguments: ["log", "--oneline"]) | Command("wc", arguments: ["-l"]))
    .run(on: runner)
```

Feeding a child uses `Command.standardInput` (`.data` or `.stream`). Piped input ignores `SIGPIPE` for the whole
process.

## Asking the user

`CommandLineKitInput` asks questions without a terminal in your tests. Prompts go to stderr, secrets are not
echoed, and with stdin not a terminal (CI, pipes) it returns the default or throws instead of hanging.

```swift
import CommandLineKitInput

struct Deployer {
    let runner: any CommandLineRunner
    let input: any CommandLineInput

    func deploy() async throws {
        while true {
            do {
                _ = try await runner.run(.init("swift", arguments: ["build", "-c", "release"]))
                return
            } catch let CommandError.nonZeroExit(result) {
                guard try await input.confirm("Build failed (exit \(result.exitCode)). Retry?", default: true)
                else { throw CommandError.nonZeroExit(result) }
            }
        }
    }
}

let name = try await CommandInput.current.prompt("Name", default: "anonymous", secret: false)
let token = try await CommandInput.current.prompt("Token", default: nil, secret: true)
let target = try await CommandInput.current.choose("Target", from: ["staging", "production"])
```

In tests, `CommandLineInputStub(answers: ["y"])` (from `CommandLineKitTesting`) scripts the answers and records
the prompts.

## Checking the package

`./test.sh` runs the static rules, the unit tests, the custom-runner example, every command of the sample app and
the input checks, including under a pseudo-terminal.
`./test.sh --docker 6.1` does the same on Linux.

## Agent skill

`skills/swift-command-line-kit` teaches a coding agent to integrate and use this package. Install it with

```bash
npx skills add amine2233/swift-command-line-kit
```

or as a Claude Code plugin:

```text
/plugin marketplace add amine2233/swift-command-line-kit
/plugin install swift-command-line-kit@swift-command-line-kit
```

The examples live in `skills/swift-command-line-kit/references/examples`.
