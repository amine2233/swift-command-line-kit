import ArgumentParser
import CommandLineKit
import Foundation

struct GlobalOptions: ParsableArguments {
    @Flag(name: .shortAndLong, help: "Log progress to stderr.")
    var verbose = false

    @Option(help: "Hard per-case timeout in seconds.")
    var timeout: Double = 10

    func validate() throws {
        guard timeout > 0 else { throw ValidationError("--timeout must be greater than 0") }
    }

    /// The injected runner every case runs through.
    var runner: any CommandLineRunner {
        CommandLineRunnerDefault(logger: verbose ? CommandLoggerPrint(minimumLevel: .debug) :
            CommandLoggerSilent())
    }
}

private func report(_ check: Check, _ outcome: Outcome) {
    let status = outcome.passed ? "PASS" : "FAIL"
    print("\(status) \(check.rawValue): \(outcome.detail)")
}

protocol CheckCommand: AsyncParsableCommand {
    static var check: Check { get }
    var options: GlobalOptions { get }
}

extension CheckCommand {
    func run() async throws {
        let outcome = await Self.check.run(
            runner: options.runner,
            timeout: options.timeout,
            verbose: options.verbose
        )
        report(Self.check, outcome)
        guard outcome.passed else { throw ExitCode.failure }
    }
}

@main
struct SampleCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sample-cli-app",
        abstract: "Exercises the CommandLineKit public API and reports PASS/FAIL per behaviour.",
        version: "1.0.0",
        subcommands: [
            Echo.self, Fail.self, SilentFail.self, Warn.self, Big.self, Stdin.self, Completion.self,
            Which.self, SelfTest.self, Ask.self, PtyCheck.self
        ]
    )

    struct Echo: CheckCommand {
        static let configuration =
            CommandConfiguration(abstract: "Successful command, stdout captured and streamed.")
        static let check = Check.echo
        @OptionGroup var options: GlobalOptions
    }

    struct Fail: CheckCommand {
        static let configuration = CommandConfiguration(abstract: "Non-zero exit with stderr must throw.")
        static let check = Check.fail
        @OptionGroup var options: GlobalOptions
    }

    struct SilentFail: CheckCommand {
        static let configuration = CommandConfiguration(
            commandName: "silent-fail",
            abstract: "Non-zero exit with no stderr must throw."
        )
        static let check = Check.silentFail
        @OptionGroup var options: GlobalOptions
    }

    struct Warn: CheckCommand {
        static let configuration = CommandConfiguration(abstract: "Exit 0 with stderr must not throw.")
        static let check = Check.warn
        @OptionGroup var options: GlobalOptions
    }

    struct Big: CheckCommand {
        static let configuration =
            CommandConfiguration(abstract: "More than 1 MiB on stdout and stderr must not hang.")
        static let check = Check.big
        @OptionGroup var options: GlobalOptions
    }

    struct Stdin: CheckCommand {
        static let configuration = CommandConfiguration(abstract: "A child reading stdin must not block.")
        static let check = Check.stdin
        @OptionGroup var options: GlobalOptions
    }

    struct Completion: CheckCommand {
        static let configuration =
            CommandConfiguration(abstract: "Callback-based path must call back in time.")
        static let check = Check.completion
        @OptionGroup var options: GlobalOptions
    }

    struct Which: CheckCommand {
        static let configuration =
            CommandConfiguration(abstract: "Bare executable names must resolve via PATH.")
        static let check = Check.which
        @OptionGroup var options: GlobalOptions
    }

    struct SelfTest: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "selftest",
            abstract: "Runs every case under a hard timeout; exits 1 if any fails."
        )
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            let runner = options.runner
            var failures = 0
            for check in Check.allCases {
                let outcome = await check.run(
                    runner: runner,
                    timeout: options.timeout,
                    verbose: options.verbose
                )
                report(check, outcome)
                if !outcome.passed { failures += 1 }
            }
            diagnostic("\(Check.allCases.count - failures)/\(Check.allCases.count) passed")
            guard failures == 0 else { throw ExitCode.failure }
        }
    }
}
