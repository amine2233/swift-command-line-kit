import CommandLineKitCore
import Foundation

/// Forwards each chunk to an optional handler and reports it to a closure.
///
/// Calls are serialised under one lock, so several stages can share a tee and the handler contract still
/// holds for the wrapped handler.
public final class CommandShellDataHandlerTee: CommandShellDataHandler, @unchecked Sendable {
    private let base: (any CommandShellDataHandler)?
    private let forwardsEnd: Bool
    private let observe: @Sendable (Data) -> Void
    private let onEnd: @Sendable () -> Void
    private let lock = NSLock()

    /// - Parameter forwardsEnd: Pass `false` when several tees share `base`, and call `base.end()` yourself
    /// once.
    public init(
        forwardingTo base: (any CommandShellDataHandler)? = nil,
        forwardsEnd: Bool = true,
        observe: @escaping @Sendable (Data) -> Void = { _ in },
        onEnd: @escaping @Sendable () -> Void = {}
    ) {
        self.base = base
        self.forwardsEnd = forwardsEnd
        self.observe = observe
        self.onEnd = onEnd
    }

    public func handle(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }

        defer { observe(data) }
        try base?.handle(data)
    }

    public func end() {
        lock.lock()
        defer { lock.unlock() }

        if forwardsEnd { base?.end() }
        onEnd()
    }
}
