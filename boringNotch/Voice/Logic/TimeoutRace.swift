import Foundation

/// Runs `op` for at most `seconds`. Returns its value, or nil once the cap passes.
/// On timeout `op` is abandoned: it is neither cancelled nor awaited, so an
/// operation that ignores cancellation cannot hold the caller past the cap.
enum TimeoutRace {
    static func run<T: Sendable>(seconds: Double, _ op: @escaping @Sendable () async -> T) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let once = Once()
            Task {
                let value = await op()
                if once.claim() { continuation.resume(returning: value) }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                if once.claim() { continuation.resume(returning: nil) }
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
