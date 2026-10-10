import Foundation

/// The namespace of the command-line runner.
///
/// `CommandRunner` is the static facade (see `CommandRunner.run` in `CommandLineKit`), while
/// ``CommandLineRunner`` is the protocol a runner implements and a consumer injects.
public enum CommandRunner {
    /// A command to run: what to launch, with which arguments, in which environment.
    public struct Command: Sendable, Equatable {
        /// A path, or a bare name resolved through `PATH` and the well-known directories.
        public var executable: String

        public var arguments: [String]

        /// Merged over the inherited environment.
        public var environment: [String: String]

        public var workingDirectory: URL?

        /// What the child reads. A runner that cannot feed a child ignores it.
        public var standardInput: CommandInput

        public init(
            _ executable: String,
            arguments: [String] = [],
            environment: [String: String] = [:],
            workingDirectory: URL? = nil,
            standardInput: CommandInput = .nullDevice
        ) {
            self.executable = executable
            self.arguments = arguments
            self.environment = environment
            self.workingDirectory = workingDirectory
            self.standardInput = standardInput
        }
    }
}
