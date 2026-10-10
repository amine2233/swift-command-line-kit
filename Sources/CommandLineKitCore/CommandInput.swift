import Foundation

/// What a child process reads on its standard input.
public enum CommandInput: Sendable, Equatable {
    /// `/dev/null`.
    case nullDevice

    /// These bytes, then end of input.
    case data(Data)

    /// Each chunk as it arrives, then end of input when the stream finishes. Single use.
    case stream(AsyncStream<Data>)

    /// Streams are never equal: they cannot be compared without consuming them.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.nullDevice, .nullDevice): true
        case let (.data(left), .data(right)): left == right
        default: false
        }
    }
}
