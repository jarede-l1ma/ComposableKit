import Foundation

// @unchecked Sendable: all mutable state (`now`, `suspensions`) is private and only
// accessed under `lock`; continuations are resumed outside the lock and no
// lock is held across an `await`.
/// A test-controlled clock: `sleep` only finishes when the test advances time.
///
/// ```swift
/// let clock = TestClock()
/// let store = TestStore(...) { ... } withDependencies: { $0.continuousClock = clock }
/// await store.send(.searchChanged("a"))
/// await clock.advance(by: 0.3)
/// await store.receive(\.didSearch) { ... }
/// ```
public final class TestClock: EffectClock, @unchecked Sendable {
    private struct Suspension {
        let id: UUID
        let deadline: Double
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var now: Double = 0
    private var suspensions: [Suspension] = []

    public init() {}

    public func sleep(for seconds: Double) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let resumeNow: Bool = lock.sync {
                    if seconds <= 0 { return true }
                    suspensions.append(Suspension(id: id, deadline: now + seconds, continuation: continuation))
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let cancelled: Suspension? = lock.sync {
                guard let index = suspensions.firstIndex(where: { $0.id == id }) else { return nil }
                return suspensions.remove(at: index)
            }
            cancelled?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Advances time and releases the `sleep`s that are due.
    public func advance(by seconds: Double = 0) async {
        await Task.megaYield()
        let target = lock.sync { now + seconds }
        await waitForPendingSleeps(dueBy: target)
        // One `sleep` at a time, in deadline order, yielding between them: so
        // the code after each `sleep` runs in deadline order.
        while true {
            let next: Suspension? = lock.sync {
                guard let index = suspensions.indices
                    .filter({ suspensions[$0].deadline <= target })
                    .min(by: { suspensions[$0].deadline < suspensions[$1].deadline })
                else { return nil }
                let suspension = suspensions.remove(at: index)
                now = suspension.deadline
                return suspension
            }
            guard let next else { break }
            next.continuation.resume()
            await Task.megaYield()
        }
        lock.sync { now = target }
        await Task.megaYield()
    }

    /// "advance before sleep" race: the effect about to sleep may not have
    /// reached its `sleep` yet when the test calls `advance` (Tasks created in
    /// a chain, e.g. `.concatenate`, on a slow machine — reproduced with the
    /// Thread Sanitizer: 11 of 15 suite runs failed). Without a `sleep` whose
    /// deadline falls within the advance, it waits a little for one to appear
    /// and for the `sleep` list to settle; if nothing shows up (e.g. the effect
    /// was cancelled), it moves on. Limit: `timeout × 100` attempts of ~1 ms
    /// (~100 ms with the 1 s default; raise it with `COMPOSABLEKIT_TEST_TIMEOUT`).
    private func waitForPendingSleeps(dueBy target: Double) async {
        let maxAttempts = max(1, Int(TestStoreDefaults.timeout * 100))
        var lastCount = -1
        var stableChecks = 0
        for _ in 0..<maxAttempts {
            let (count, hasDue) = lock.sync {
                (suspensions.count, suspensions.contains { $0.deadline <= target })
            }
            if hasDue {
                stableChecks = count == lastCount ? stableChecks + 1 : 0
                if stableChecks >= 2 { return }
            }
            lastCount = count
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    /// Advances until no `sleep` is pending.
    public func run() async {
        await Task.megaYield()
        let last = lock.sync { suspensions.map(\.deadline).max() }
        guard let last else { return }
        await advance(by: max(0, last - lock.sync { now }))
    }
}
