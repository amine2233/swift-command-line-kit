import CommandLineKitCore
import Foundation

/// A logger that keeps every event, for assertions.
public final class CommandLoggerRecorder: CommandLogger, @unchecked Sendable {
    public struct Event: Sendable, Equatable {
        public let level: CommandLogLevel
        public let message: String
        public let metadata: [String: String]
    }

    private let lock = NSLock()
    private var recorded: [Event] = []

    public init() {}

    public var events: [Event] {
        lock.lock()
        defer { lock.unlock() }

        return recorded
    }

    public func log(
        _ level: CommandLogLevel,
        _ message: @autoclosure @Sendable () -> String,
        metadata: [String: String]
    ) {
        let event = Event(level: level, message: message(), metadata: metadata)
        lock.lock()
        recorded.append(event)
        lock.unlock()
    }
}
