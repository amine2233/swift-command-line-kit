import Foundation

/// Receives the output of a running command, chunk by chunk.
///
/// The contract every ``CommandLineRunner`` honours:
/// - calls to one stream's handler are serial and in order;
/// - different streams MAY run concurrently;
/// - ``end()`` is called exactly once per stream;
/// - all calls happen before `run` returns or throws;
/// - ``handle(_:)`` is never called with empty `Data`.
public protocol CommandShellDataHandler: Sendable {
    /// Called each time there is new data available.
    ///
    /// - Throws: An error if the data cannot be processed. Draining continues; the run reports it afterwards.
    func handle(_ data: Data) throws

    /// Called once when the stream is finished.
    func end()
}

extension CommandShellDataHandler {
    /// Default implementation of `end()`. It does nothing.
    public func end() {}

    /// For runners that cannot stream: one non-empty `handle`, then `end()`.
    public func handleAll(_ data: Data) throws {
        defer { end() }
        guard !data.isEmpty else { return }

        try handle(data)
    }
}

extension FileHandle {
    private var isStandard: Bool {
        self === FileHandle.standardOutput ||
            self === FileHandle.standardError ||
            self === FileHandle.standardInput
    }
}

extension FileHandle: CommandShellDataHandler {
    /// Writes the data. A broken pipe throws instead of raising an exception.
    public func handle(_ data: Data) throws {
        if #available(macOS 10.15.4, *) {
            try write(contentsOf: data)
        } else {
            write(data)
        }
    }

    /// Closes the file, unless it is a standard file handle.
    public func end() {
        guard !isStandard else { return }

        closeFile()
    }
}

/// Prints each chunk as a trimmed UTF-8 line.
public struct CommandShellDataHandlerDefault: CommandShellDataHandler {
    public init() {}

    public func handle(_ data: Data) {
        guard let valueString = String(data: data, encoding: .utf8) else { return }

        let value = valueString.trimmingCharacters(in: .newlines)
        guard !value.isEmpty else { return }

        print(value)
    }
}

extension CommandShellDataHandler where Self == CommandShellDataHandlerDefault {
    /// The default CommandShellDataHandler
    public static var `default`: some CommandShellDataHandler {
        CommandShellDataHandlerDefault()
    }
}

/// Ignores everything.
public struct CommandShellDataHandlerEmpty: CommandShellDataHandler {
    public init() {}

    public func handle(_ data: Data) {}
}

extension CommandShellDataHandler where Self == CommandShellDataHandlerEmpty {
    /// The empty CommandShellDataHandlerEmpty
    public static var empty: some CommandShellDataHandler {
        CommandShellDataHandlerEmpty()
    }
}
