import CommandLineKitCore
import Dispatch
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// The process-wide terminal, used by one prompt at a time.
enum Terminal {
    /// The terminal is process-wide, so concurrent prompts are serialised.
    private static let lock = NSLock()

    static func isTerminal(_ descriptor: Int32) -> Bool {
        isatty(descriptor) == 1
    }

    /// Writes the prompt to the handler, or to stderr.
    static func write(_ text: String, to handler: (any CommandShellDataHandler)?) throws {
        let data = Data(text.utf8)
        do {
            if let handler {
                try handler.handle(data)
            } else if #available(macOS 10.15.4, *) {
                try FileHandle.standardError.write(contentsOf: data)
            } else {
                FileHandle.standardError.write(data)
            }
        } catch {
            throw CommandInputError.unavailable(reason: "cannot write prompt")
        }
    }

    /// Writes the prompt, then reads one line. Runs on a dedicated thread.
    static func ask(_ request: CommandInputRequestDefault) throws -> String? {
        lock.lock()
        defer { lock.unlock() }

        guard request.isSecret else {
            try write("\(request.message): ", to: request.promptHandler)
            return readLine(from: request.descriptor)
        }

        // echo goes off before the prompt appears, so a visible prompt means typed characters are hidden
        let echo = try EchoSuppression(descriptor: request.descriptor)
        defer { echo.restore() }

        try write("\(request.message): ", to: request.promptHandler)
        let line = readLine(from: request.descriptor)
        try write("\n", to: request.promptHandler)
        return line
    }

    /// Reads up to a newline, byte by byte, so nothing is buffered beyond the line. `nil` at end of input.
    private static func readLine(from descriptor: Int32) -> String? {
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while true {
            let count = read(descriptor, &byte, 1)
            if count < 0, errno == EINTR { continue }
            if count <= 0 { return bytes.isEmpty ? nil : String(bytes: bytes, encoding: .utf8) ?? "" }
            if byte == UInt8(ascii: "\n") { return String(bytes: bytes, encoding: .utf8) ?? "" }

            bytes.append(byte)
        }
    }
}

/// Turns terminal echo off and puts it back on every exit path, including Ctrl-C.
///
/// For its lifetime a `DispatchSource` handles SIGINT: it restores the settings and re-raises SIGINT with the
/// default action. An application with its own SIGINT handler is overridden for that time.
private final class EchoSuppression: @unchecked Sendable {
    private let descriptor: Int32
    private var original = termios()
    private let lock = NSLock()
    private var restored = false
    private let interrupt: any DispatchSourceSignal
    private let previousHandler: (@convention(c) (Int32) -> Void)?

    init(descriptor: Int32) throws {
        self.descriptor = descriptor
        guard tcgetattr(descriptor, &original) == 0 else {
            throw CommandInputError.unavailable(reason: "cannot disable echo")
        }

        var silent = original
        silent.c_lflag &= ~tcflag_t(ECHO)
        guard tcsetattr(descriptor, TCSANOW, &silent) == 0 else {
            throw CommandInputError.unavailable(reason: "cannot disable echo")
        }

        self.previousHandler = signal(SIGINT, SIG_IGN)
        self.interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        interrupt.setEventHandler { [self] in
            restoreSettings()
            // libdispatch blocks the signal on its threads (signalfd on Linux), so unblock it before
            // re-raising
            var interrupts = sigset_t()
            sigemptyset(&interrupts)
            sigaddset(&interrupts, SIGINT)
            pthread_sigmask(SIG_UNBLOCK, &interrupts, nil)
            signal(SIGINT, SIG_DFL)
            raise(SIGINT)
        }
        interrupt.resume()
    }

    func restore() {
        interrupt.cancel()
        signal(SIGINT, previousHandler)
        restoreSettings()
    }

    private func restoreSettings() {
        lock.lock()
        defer { lock.unlock() }

        guard !restored else { return }

        restored = true
        var settings = original
        tcsetattr(descriptor, TCSANOW, &settings)
    }
}
