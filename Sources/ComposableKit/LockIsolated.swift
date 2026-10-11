import Foundation

// @unchecked Sendable: every access to `_value` goes through the lock and no lock is
// held across an `await` (the closures are synchronous). `Value` does not need to be
// `Sendable` (e.g. analytics events in tests): so do not store a mutable reference
// here to use it outside `withValue`.
/// A lock-protected value, safe to capture in `@Sendable` closures.
///
/// Useful in tests to record dependency calls:
/// ```swift
/// let calls = LockIsolated(0)
/// $0.homeClient.fetchData = { calls.withValue { $0 += 1 }; return .fixture() }
/// #expect(calls.value == 1)
/// ```
@dynamicMemberLookup
public final class LockIsolated<Value>: @unchecked Sendable {
    private var _value: Value
    private let lock = NSRecursiveLock()

    public init(_ value: Value) {
        self._value = value
    }

    public var value: Value {
        lock.sync { _value }
    }

    public subscript<Subject>(dynamicMember keyPath: KeyPath<Value, Subject>) -> Subject {
        lock.sync { _value[keyPath: keyPath] }
    }

    @discardableResult
    public func withValue<T>(_ operation: (inout Value) throws -> T) rethrows -> T {
        try lock.sync { try operation(&_value) }
    }

    public func setValue(_ newValue: Value) {
        lock.sync { _value = newValue }
    }
}

extension LockIsolated: Equatable where Value: Equatable {
    public static func == (lhs: LockIsolated, rhs: LockIsolated) -> Bool {
        lhs.value == rhs.value
    }
}
