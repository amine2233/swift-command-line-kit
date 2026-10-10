import Foundation

/// The static facade of user input.
public enum CommandInput {
    /// The input the facade uses. Override it for a scope with `$current.withValue(_:operation:)`.
    ///
    /// It is a task-local value: under `Task.detached`, a `Thread` and a `DispatchQueue` it falls back to
    /// ``CommandLineInputDefault``. Inject `any CommandLineInput` in testable code.
    @TaskLocal public static var current: any CommandLineInput = CommandLineInputDefault()
}
