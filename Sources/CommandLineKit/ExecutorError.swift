import Foundation

/// A structure that conforms to the `Error` and `CustomStringConvertible` protocols,
/// representing an error with a descriptive message.
public struct ExecutorError: Error, CustomStringConvertible {
    /// A description of the error.
    public let description: String

    /// Initializes a new `ErrorHandler` with a given description.
    ///
    /// - Parameter description: A string describing the error.
    public init(_ description: String) {
        self.description = description
    }
}
