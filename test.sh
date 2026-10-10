#!/usr/bin/env bash
# Checks the whole package: static rules, unit tests, the custom-runner example, then builds
# skills/swift-command-line-kit/references/examples/sample-cli-app, runs every command and the input checks (including under a pseudo-terminal), checking each exit code and PASS line.
# Exit 0 only if everything matches.
#
#   ./test.sh                 build and run on this machine
#   ./test.sh --docker 6.1    run inside swift:6.1 (use 6.2 for the other CI lane)
set -uo pipefail

cd "$(dirname "$0")"

if [[ "${1:-}" == "--docker" ]]; then
    image="swift:${2:?usage: ./test.sh --docker <swift-version>}"
    exec docker run --rm -v "$PWD":/w -w /w "$image" ./test.sh
fi

readonly examples="skills/swift-command-line-kit/references/examples"
readonly package="$examples/sample-cli-app"
readonly timeout=10
errfile="$(mktemp)"
trap 'rm -f "$errfile"' EXIT
passed=0
failed=0

ok() { printf '  ok    %s\n' "$1"; passed=$((passed + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; failed=$((failed + 1)); }

echo "== static: no #if os() under Sources/"
if grep -rnE '^\s*#\s*(if|elseif)\s+os\(' Sources/; then
    bad "platform conditionals found"
else
    ok "Sources/ is free of #if os()"
fi

echo "== static: no output/error streams"
if grep -rnE 'outputStream|errorStream|CommandStream' Sources/ "$examples"/ Tests/ --include='*.swift' --exclude-dir=.build; then
    bad "stream API found"
else
    ok "no output/error streams"
fi

echo "== extension seam: the custom runner depends on Core and Testing only"
if grep -E 'name: "CommandLineKit"[,)]' "$examples"/custom-runner-example/Package.swift; then
    bad "custom-runner-example depends on the default engine"
else
    ok "custom-runner-example does not use CommandLineKit"
fi

echo "== library unit tests"
if swift test 2>&1 | tail -3; then ok "swift test"; else bad "swift test"; fi

echo "== custom runner example (contract checks)"
if swift test --package-path "$examples"/custom-runner-example 2>&1 | tail -3; then
    ok "custom-runner-example passes the runner contract"
else
    bad "custom-runner-example"
fi

echo "== build $package"
if ! swift build --package-path "$package" 2>&1 | tail -3; then
    echo "build failed"
    exit 1
fi
bin="$(swift build --package-path "$package" --show-bin-path)/sample-cli-app"
[[ -x "$bin" ]] || { echo "binary not found at $bin"; exit 1; }
ok "built $bin"

# expect <name> <exit-code> <stdout-regex> <args...>
expect() {
    local name="$1" code="$2" pattern="$3"
    shift 3
    local output status
    output="$("$bin" "$@" 2>/dev/null </dev/null)"
    status=$?
    if [[ $status -ne $code ]]; then
        bad "$name: exit $status, expected $code"
    elif ! grep -qE "$pattern" <<<"$output"; then
        bad "$name: output did not match /$pattern/: $output"
    else
        ok "$name"
    fi
}

echo "== every command (hard timeout ${timeout}s per case)"
for check in echo fail silent-fail warn big stdin completion which; do
    expect "$check" 0 "^PASS $check:" "$check" --timeout "$timeout"
done
expect "selftest" 0 "^PASS which:" selftest --timeout "$timeout"
expect "--version" 0 "^[0-9]+\\.[0-9]+" --version
expect "--help" 0 "selftest" --help
expect "unknown subcommand is rejected" 64 "^$" no-such-command

echo "== input: stdin is not a terminal (prompts on stderr, never blocks)"
out="$("$bin" ask 2>"$errfile" </dev/null)"; status=$?
if [[ $status -eq 0 && "$out" == "name: anonymous" ]] && grep -q "Name \[anonymous\]" "$errfile"; then
    ok "ask: default used, stdout holds only the result, prompt went to stderr"
else
    bad "ask: status=$status stdout=$out stderr=$(cat "$errfile")"
fi
expect "ask --confirm uses its default" 0 "^confirmed: true$" ask --confirm
out="$("$bin" ask --secret 2>"$errfile" </dev/null)"; status=$?
if [[ $status -eq 1 && -z "$out" ]] && grep -q "not a terminal" "$errfile"; then
    ok "ask --secret: refuses without a terminal"
else
    bad "ask --secret: status=$status stdout=$out stderr=$(cat "$errfile")"
fi
out="$("$bin" ask --choose a,b 2>"$errfile" </dev/null)"; status=$?
if [[ $status -eq 1 && -z "$out" ]] && grep -q "not a terminal" "$errfile"; then
    ok "ask --choose: refuses without a terminal"
else
    bad "ask --choose: status=$status stdout=$out stderr=$(cat "$errfile")"
fi

echo "== input under a pseudo-terminal (no echo, Ctrl-C restores echo)"
pty="$("$bin" pty-check 2>/dev/null </dev/null)"; status=$?
echo "$pty"
if [[ $status -eq 0 && $(grep -c '^PASS pty' <<<"$pty") -eq 3 ]] && ! grep -q '^FAIL' <<<"$pty"; then
    ok "pty-check: 3/3"
else
    bad "pty-check: status=$status"
fi

echo "== selftest reports every case"
cases="$("$bin" selftest --timeout "$timeout" 2>/dev/null | grep -c '^PASS ')"
if [[ "$cases" -eq 8 ]]; then ok "selftest: 8/8 PASS"; else bad "selftest: $cases/8 PASS"; fi

echo
echo "passed: $passed, failed: $failed"
[[ $failed -eq 0 ]]
