import Foundation

/// The one error of the input product.
public enum CommandInputError: Error, Sendable, LocalizedError {
    /// No answer can be obtained: not a terminal, end of input, no valid answer, no options, echo cannot be
    /// disabled, or a prompt that cannot be written.
    case unavailable(reason: String)

    public var errorDescription: String? {
        switch self {
        case let .unavailable(reason): "Input unavailable: \(reason)"
        }
    }
}
