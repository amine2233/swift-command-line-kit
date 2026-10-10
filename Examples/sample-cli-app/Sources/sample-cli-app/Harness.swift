import Foundation
import Synchronization

struct Outcome: Sendable {
    let passed: Bool
    let detail: String

    static func pass(_ detail: String) -> Outcome {
        Outcome(passed: true, detail: detail)
    }

    static func fail(_ detail: String) -> Outcome {
        Outcome(passed: false, detail: detail)
    }
}

private final class Once: Sendable {
    private let continuation: Mutex<CheckedContinuation<Outcome, Never>?>

    init(_ continuation: CheckedContinuation<Outcome, Never>) {
        self.continuation = Mutex(continuation)
    }

    func resume(_ outcome: Outcome) {
        let taken = continuation.withLock { state in
            defer { state = nil }
            return state
        }
        taken?.resume(returning: outcome)
    }
}

/// Resumes with whichever happens first: the case reporting back, or the timeout.
func race(
    timeout: Double,
    start: @Sendable (@escaping @Sendable (Outcome) -> Void) -> Void
) async -> Outcome {
    await withCheckedContinuation { continuation in
        let once = Once(continuation)
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            once.resume(.fail("TIMEOUT after \(timeout)s (library call did not return)"))
        }
        start { once.resume($0) }
    }
}

func diagnostic(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
