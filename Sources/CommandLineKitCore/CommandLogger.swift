import Foundation

public enum CommandLogLevel: Int, Sendable, Comparable {
    case debug
    case info
    case warning
    case error

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// The diagnostics sink of runners and middleware.
///
/// Adapt `os.Logger`, swift-log or any other sink in a few lines. Messages and metadata never contain
/// environment values or output bytes. `log` MUST be callable from any thread.
public protocol CommandLogger: Sendable {
    func log(
        _ level: CommandLogLevel,
        _ message: @autoclosure @Sendable () -> String,
        metadata: [String: String]
    )
}

extension CommandLogger {
    /// Logs a message without metadata.
    public func log(_ level: CommandLogLevel, _ message: @autoclosure @Sendable () -> String) {
        log(level, message(), metadata: [:])
    }
}

/// Logs nothing. The default, so a library never prints unasked.
public struct CommandLoggerSilent: CommandLogger {
    public init() {}

    public func log(
        _ level: CommandLogLevel,
        _ message: @autoclosure @Sendable () -> String,
        metadata: [String: String]
    ) {}
}

extension CommandLogger where Self == CommandLoggerSilent {
    /// The silent CommandLogger
    public static var silent: some CommandLogger {
        CommandLoggerSilent()
    }
}

/// Prints one line per event to stderr.
public struct CommandLoggerPrint: CommandLogger {
    public let minimumLevel: CommandLogLevel

    public init(minimumLevel: CommandLogLevel = .info) {
        self.minimumLevel = minimumLevel
    }

    public func log(
        _ level: CommandLogLevel,
        _ message: @autoclosure @Sendable () -> String,
        metadata: [String: String]
    ) {
        guard level >= minimumLevel else { return }

        let details = metadata.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        let line = "[\(level)] \(message())" + (details.isEmpty ? "" : " \(details)") + "\n"
        if #available(macOS 10.15.4, *) {
            try? FileHandle.standardError.write(contentsOf: Data(line.utf8))
        } else {
            FileHandle.standardError.write(Data(line.utf8))
        }
    }
}

extension CommandLogger where Self == CommandLoggerPrint {
    /// The print CommandLogger
    public static var print: some CommandLogger {
        CommandLoggerPrint()
    }
}
