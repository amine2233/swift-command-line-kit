import ArgumentParser
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Drives `ask` under a pseudo-terminal to check what a terminal user would see: typed secrets are not
/// echoed, and after Ctrl-C the terminal echoes again.
struct PtyCheck: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pty-check",
        abstract: "Runs `ask` under a pseudo-terminal and checks echo handling.",
        shouldDisplay: false
    )

    @OptionGroup var options: GlobalOptions

    func run() async throws {
        let outcome = await race(timeout: options.timeout * 3) { done in
            Thread.detachNewThread { done(PseudoTerminalChecks.runAll()) }
        }
        guard outcome.passed else {
            print("FAIL pty-check: \(outcome.detail)")
            throw ExitCode.failure
        }
    }
}

private struct PseudoTerminal {
    let master: Int32
    let slave: Int32

    init?() {
        guard let (master, name) = Self.openMaster() else { return nil }

        let slave = open(name, O_RDWR | O_NOCTTY)
        guard slave >= 0 else { return nil }

        _ = fcntl(master, F_SETFL, O_NONBLOCK)
        self.master = master
        self.slave = slave
    }

    /// Opens a pseudo-terminal master and returns it with the path of its slave.
    private static func openMaster() -> (Int32, String)? {
#if canImport(Darwin)
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0, let name = ptsname(master) else {
            return nil
        }

        return (master, String(cString: name))
#else
        // Swift's Glibc module does not expose posix_openpt and friends, so use the kernel interface:
        // open the multiplexer, unlock the pair (TIOCSPTLCK) and ask for its number (TIOCGPTN).
        let master = open("/dev/ptmx", O_RDWR | O_NOCTTY)
        var unlock: Int32 = 0
        var number: UInt32 = 0
        guard master >= 0, ioctl(master, 0x4004_5431, &unlock) == 0,
              ioctl(master, 0x8004_5430, &number) == 0 else {
            return nil
        }

        return (master, "/dev/pts/\(number)")
#endif
    }

    var isEchoOn: Bool {
        var settings = termios()
        tcgetattr(slave, &settings)
        return settings.c_lflag & tcflag_t(ECHO) != 0
    }

    func type(_ text: String) {
        _ = write(master, text, text.utf8.count)
    }

    /// Whatever the terminal echoed so far.
    func echoed() -> String {
        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = read(master, &buffer, buffer.count)
            if count <= 0 { break }

            collected.append(contentsOf: buffer.prefix(count))
        }
        return String(decoding: collected, as: UTF8.self)
    }

    func release() {
        close(master)
        close(slave)
    }
}

private struct AskProcess {
    let process = Process()
    let stdout = Pipe()
    let stderr = Pipe()

    init(arguments: [String], terminal: PseudoTerminal) throws {
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        process.arguments = ["ask"] + arguments
        process.standardInput = FileHandle(fileDescriptor: terminal.slave, closeOnDealloc: false)
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
    }

    /// Blocks until the prompt text shows up on stderr.
    func waitForPrompt(_ text: String) -> Bool {
        var seen = ""
        while !seen.contains(text) {
            let chunk = stderr.fileHandleForReading.availableData
            if chunk.isEmpty { return false }

            seen += String(decoding: chunk, as: UTF8.self)
        }
        return true
    }

    func finish() -> String {
        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return output.trimmingCharacters(in: .newlines)
    }
}

private enum PseudoTerminalChecks {
    static func runAll() -> Outcome {
        guard let terminal = PseudoTerminal() else { return .fail("cannot open a pseudo-terminal") }

        defer { terminal.release() }
        let cases: [(String, (PseudoTerminal) throws -> Outcome)] = [
            ("typed text is echoed (control)", plainTextIsEchoed),
            ("secret is not echoed", secretIsNotEchoed),
            ("Ctrl-C restores echo", interruptRestoresEcho)
        ]
        var allPassed = true
        for (name, check) in cases {
            let outcome = (try? check(terminal)) ?? .fail("threw")
            print("\(outcome.passed ? "PASS" : "FAIL") pty \(name): \(outcome.detail)")
            allPassed = allPassed && outcome.passed
        }
        return allPassed ? .pass("all pty checks passed") : .fail("see lines above")
    }

    private static func plainTextIsEchoed(_ terminal: PseudoTerminal) throws -> Outcome {
        let ask = try AskProcess(arguments: [], terminal: terminal)
        guard ask.waitForPrompt("Name") else { return .fail("no prompt") }

        terminal.type("Ada\n")
        let result = ask.finish()
        let echo = terminal.echoed()
        return result == "name: Ada" && echo.contains("Ada") ? .pass("result=\(result), echo seen")
            : .fail("result=\(result.debugDescription) echo=\(echo.debugDescription)")
    }

    private static func secretIsNotEchoed(_ terminal: PseudoTerminal) throws -> Outcome {
        let ask = try AskProcess(arguments: ["--secret"], terminal: terminal)
        guard ask.waitForPrompt("Secret") else { return .fail("no prompt") }

        terminal.type("hunter2\n")
        let result = ask.finish()
        let echo = terminal.echoed()
        let ok = result == "secret length: 7" && !echo.contains("hunter2") && terminal.isEchoOn
        return ok ? .pass("result=\(result), nothing echoed, echo back on")
            :
            .fail(
                "result=\(result.debugDescription) echo=\(echo.debugDescription) echoOn=\(terminal.isEchoOn)"
            )
    }

    private static func interruptRestoresEcho(_ terminal: PseudoTerminal) throws -> Outcome {
        let ask = try AskProcess(arguments: ["--secret"], terminal: terminal)
        guard ask.waitForPrompt("Secret") else { return .fail("no prompt") }

        let echoOffWhileAsking = !terminal.isEchoOn
        kill(ask.process.processIdentifier, SIGINT)
        ask.process.waitUntilExit()
        let ended = ask.process.terminationReason == .uncaughtSignal && ask.process
            .terminationStatus == SIGINT
        let ok = echoOffWhileAsking && ended && terminal.isEchoOn
        return ok ? .pass("echo off while asking, SIGINT ended the process, echo back on")
            :
            .fail(
                "echoOffWhileAsking=\(echoOffWhileAsking) ended=\(ended) echoOnAfter=\(terminal.isEchoOn)"
            )
    }
}
