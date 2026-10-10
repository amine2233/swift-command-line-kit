# sample-cli-app

Exercises the CommandLineKit public API and checks the behaviours that used to be defective. Each subcommand runs a child
process through the library and prints `PASS`/`FAIL <case>: <observed behaviour>` on stdout
(diagnostics on stderr). Exit code is 0 only if every executed case passes, else 1.

Cases: `echo`, `fail`, `silent-fail`, `warn`, `big`, `stdin`, `completion`, `which`, and `selftest` (all of them).
Options: `--timeout <seconds>` (default 10, hard per case), `--verbose`.

## macOS

    swift run --package-path skills/swift-command-line-kit/references/examples/sample-cli-app sample-cli-app selftest

## Linux

    docker run --rm -v "$PWD":/w -w /w swift:6.1 \
      swift run --package-path skills/swift-command-line-kit/references/examples/sample-cli-app sample-cli-app selftest

`./test.sh` at the repository root builds this package, runs every command and checks exit codes and
output (`./test.sh --docker 6.1` for Linux).

A single case, e.g. `... sample-cli-app warn --verbose`.

The sample is a separate package (path dependency on the root, plus swift-argument-parser);
the library's own `Package.swift` is untouched.
