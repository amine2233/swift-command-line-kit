import Foundation

/// Makes a second `run()` of an execution detectable. Third-party executions use it too.
public final class CommandSingleUse: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    public init() {}

    /// Returns `true` the first time only.
    public func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        defer { taken = true }
        return !taken
    }
}
