import Foundation

// MARK: - Lock

extension NSLocking {
    @inlinable
    func sync<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

// MARK: - Dynamic equality
//
// Used to drop notifications when the observed state did not change,
// without requiring `Equatable` on every `State`.

func _isEqual(_ lhs: Any, _ rhs: Any) -> Bool? {
    func open<T: Equatable>(_ lhs: T) -> Bool {
        lhs == (rhs as? T)
    }
    guard let lhs = lhs as? any Equatable else { return nil }
    return open(lhs)
}

// MARK: - Box

final class _Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

// MARK: - TaskBag

// @unchecked Sendable: `tasks` is private and only accessed under `lock`; Tasks are
// cancelled outside the lock.
/// Holds the Tasks of a Store's in-flight effects (thread-safe).
final class _TaskBag: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [UUID: Task<Void, Never>] = [:]

    func insert(_ id: UUID, _ task: Task<Void, Never>) {
        lock.sync { tasks[id] = task }
    }

    func remove(_ id: UUID) {
        _ = lock.sync { tasks.removeValue(forKey: id) }
    }

    func cancel(_ ids: some Sequence<UUID>) {
        let toCancel = lock.sync { ids.compactMap { tasks.removeValue(forKey: $0) } }
        toCancel.forEach { $0.cancel() }
    }

    func cancelAll() {
        let all = lock.sync { () -> [Task<Void, Never>] in
            defer { tasks.removeAll() }
            return Array(tasks.values)
        }
        all.forEach { $0.cancel() }
    }

    var count: Int { lock.sync { tasks.count } }
}

// MARK: - Combining Tasks

func _combine(_ tasks: [Task<Void, Never>]) -> Task<Void, Never>? {
    switch tasks.count {
    case 0: return nil
    case 1: return tasks[0]
    default:
        return Task {
            await withTaskCancellationHandler {
                for task in tasks { await task.value }
            } onCancel: {
                for task in tasks { task.cancel() }
            }
        }
    }
}

// MARK: - megaYield

extension Task where Success == Never, Failure == Never {
    /// Yields several times to give newly created Tasks (on other
    /// executors) a chance to run. Used by the TestStore.
    ///
    /// Adapted from `Task.megaYield` in swift-concurrency-extras
    /// (Point-Free, MIT License — see NOTICE).
    package static func megaYield(count: Int = 20) async {
        for _ in 0..<count {
            await Task<Void, Never>.detached(priority: .background) { await Task.yield() }.value
        }
    }
}
