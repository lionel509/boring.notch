import Foundation

/// Runs `op` for at most `seconds`. Returns its value, or nil once the cap passes.
/// On timeout `op` is cancelled and abandoned: the caller does not await it, so an
/// operation that ignores cancellation cannot hold the caller past the cap. Cancellation
/// stops a cloud request from running on (and being billed) after the fallback has started.
enum TimeoutRace {
    static func run<T: Sendable>(seconds: Double, _ op: @escaping @Sendable () async -> T) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let once = Once()
            let work = Task {
                let value = await op()
                if once.claim() { continuation.resume(returning: value) }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                if once.claim() {
                    work.cancel()
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Lets exactly one of the two racers resume the continuation.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if claimed { return false }
            claimed = true
            return true
        }
    }
}
