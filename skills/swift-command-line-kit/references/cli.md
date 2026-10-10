# Driving the sample CLI

`references/examples/sample-cli-app` is a Swift ArgumentParser CLI built on the library. Each subcommand runs a child process through `CommandLineRunnerDefault` and prints `PASS <case>: ...` or `FAIL <case>: ...` on stdout (diagnostics on stderr). Exit code 0 only if every executed case passes.

Run from the repository root (or the installed skill directory), with `$EX` = `skills/swift-command-line-kit/references/examples`:

```bash
swift run --package-path $EX/sample-cli-app sample-cli-app selftest
swift run --package-path $EX/sample-cli-app sample-cli-app warn --verbose
```

| Command | Checks |
|---|---|
| `echo` | Successful command, stdout captured and streamed |
| `fail` | Non-zero exit with stderr throws |
| `silent-fail` | Non-zero exit with no stderr throws |
| `warn` | Exit 0 with stderr does not throw |
| `big` | More than 1 MiB on stdout and stderr does not hang |
| `stdin` | A child reading stdin does not block |
| `completion` | Callback path calls back in time |
| `which` | Bare executable names resolve via `PATH` |
| `selftest` | Every case above under a hard timeout |
| `ask` | A question: text (default), `--secret`, `--confirm`, `--choose a,b,c` |
| `pty-check` | Runs `ask` under a pseudo-terminal, checks echo handling |

Options: `--timeout <seconds>` (default 10), `--verbose`, `--help`, `--version`.

## Whole-repository check

```bash
./test.sh                 # static rules, unit tests, custom-runner example, every sample command, pty checks
./test.sh --docker 6.1    # same on Linux in swift:6.1
```

Exit 0 only if everything matches. Use the sample app's source as the template when building a new CLI on the library: global options produce the injected `runner`, each command stays a thin `AsyncParsableCommand`.
