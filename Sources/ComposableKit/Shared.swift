import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Shared state
//
// Same model as TCA's `@Shared`: several features read and write the same
// value, optionally persisted.
//
// ```swift
// @ObservableState
// struct State: Equatable {
//     @Shared(.inMemory("cartCount")) var cartCount = 0
//     @Shared(.appStorage("hasSeenOnboarding")) var hasSeenOnboarding = false
//     @Shared(.fileStorage(.documentsDirectory.appendingPathComponent("user.json"))) var user: User? = nil
// }
//
// // Mutation (in the reducer or in an effect):
// state.$cartCount.withLock { $0 += 1 }
// ```
//
// When a shared value changes, only the Stores whose state contains that
// `@Shared` are notified (other screens do not redraw).
//
// Tests:
// - Each test has its own `@Shared` values (with an up-to-date
//   `ComposableKitTestSupport.swift`): parallel tests do not see each other, with no
//   `.serialized` or `resetSharedState()`. Cases of one parameterized test share them.
// - `.appStorage` and `.fileStorage` stay in memory only in tests (to make
//   `.appStorage` persist in a test, set `defaultAppStorage` in
//   `withDependencies`).
// - The `TestStore` does not check `@Shared` fields through the assertion closure
//   (the value is a reference): use `#expect(store.state.cartCount == 1)`.

// MARK: - SharedKey

/// Storage strategy of a `@Shared`.
public protocol SharedKey<Value>: Sendable {
    associatedtype Value: Sendable
    /// Identifies the value: same `id` = same shared value.
    var id: String { get }
    /// Loads the persisted value, if any.
    func load() -> Value?
    /// Persists the new value.
    func save(_ value: Value)
}

/// In memory only, for the app's lifetime.
public struct InMemoryKey<Value: Sendable>: SharedKey {
    let key: String

    public var id: String { "inMemory:\(key)" }
    public func load() -> Value? { nil }
    public func save(_ value: Value) {}
}

/// Persisted in `UserDefaults` (primitive types or `Codable`). In tests, without
/// `defaultAppStorage` set in `withDependencies`, it stays in memory only.
public struct AppStorageKey<Value: Codable & Sendable>: SharedKey {
    let key: String
    /// `nil`: in memory only (tests without an explicit `defaultAppStorage`).
    let defaults: _UncheckedUserDefaults?

    public var id: String { "appStorage:\(key)" }

    public func load() -> Value? {
        guard let defaults, let object = defaults.value.object(forKey: key) else { return nil }
        if let value = object as? Value { return value }
        guard let data = object as? Data else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    public func save(_ value: Value) {
        guard let defaults else { return }
        switch value {
        case is Bool, is Int, is Double, is Float, is String, is Data, is Date:
            defaults.value.set(value, forKey: key)
        default:
            if let data = try? JSONEncoder().encode(value) {
                defaults.value.set(data, forKey: key)
            }
        }
    }
}

/// Persisted in a JSON file. In tests it stays in memory only.
public struct FileStorageKey<Value: Codable & Sendable>: SharedKey {
    let url: URL
    let isTesting: Bool

    public var id: String { "fileStorage:\(url.absoluteString)" }

    public func load() -> Value? {
        guard !isTesting, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    /// Writes on a serial queue, off the mutating thread; several consecutive
    /// changes become a single write with the newest value.
    public func save(_ value: Value) {
        guard !isTesting else { return }
        _FileWriter.shared.write({ try? JSONEncoder().encode(value) }, to: url)
    }
}

// @unchecked Sendable: `UserDefaults` is thread-safe (Apple's documentation), but it is
// not `Sendable` in every supported SDK (iOS 15+).
public struct _UncheckedUserDefaults: @unchecked Sendable {
    let value: UserDefaults
}

extension SharedKey {
    public static func inMemory<V: Sendable>(_ key: String) -> Self where Self == InMemoryKey<V> {
        InMemoryKey(key: key)
    }

    public static func appStorage<V: Codable & Sendable>(_ key: String) -> Self where Self == AppStorageKey<V> {
        let dependencies = DependencyValues._current
        // In tests, memory only (one test does not read what another wrote), unless
        // the test sets `defaultAppStorage` to verify persistence.
        let inMemoryOnly = dependencies.context == .test && !dependencies._isOverridden(DefaultAppStorageKey.self)
        return AppStorageKey(
            key: key,
            defaults: inMemoryOnly ? nil : _UncheckedUserDefaults(value: dependencies.defaultAppStorage)
        )
    }

    public static func fileStorage<V: Codable & Sendable>(_ url: URL) -> Self where Self == FileStorageKey<V> {
        FileStorageKey(url: url, isTesting: DependencyValues._current.context == .test)
    }
}

enum DefaultAppStorageKey: DependencyKey {
    static let liveValue = _UncheckedUserDefaults(value: .standard)
    static let testValue: _UncheckedUserDefaults = {
        let name = "ComposableKit.tests"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return _UncheckedUserDefaults(value: defaults)
    }()
}

extension DependencyValues {
    /// `UserDefaults` used by `@Shared(.appStorage(...))`. In tests, `.appStorage`
    /// only writes here if the test sets this value in `withDependencies`.
    public var defaultAppStorage: UserDefaults {
        get { self[DefaultAppStorageKey.self].value }
        set { self[DefaultAppStorageKey.self] = _UncheckedUserDefaults(value: newValue) }
    }
}

// MARK: - Shared

@propertyWrapper
@dynamicMemberLookup
public struct Shared<Value: Sendable>: Sendable {
    let reference: _SharedReference<Value>

    public init<Key: SharedKey<Value>>(wrappedValue: @autoclosure () -> Value, _ key: Key) {
        self.reference = _SharedRegistry.current.reference(for: key, default: wrappedValue())
    }

    /// Current value. To change it, use `$field.withLock { ... }`.
    public var wrappedValue: Value {
        reference.value
    }

    public var projectedValue: Shared<Value> {
        self
    }

    /// Changes the value atomically and notifies the Stores.
    @discardableResult
    public func withLock<R>(_ operation: (inout Value) throws -> R) rethrows -> R {
        try reference.withLock(operation)
    }

    public subscript<Member>(dynamicMember keyPath: KeyPath<Value, Member>) -> Member {
        wrappedValue[keyPath: keyPath]
    }
}

extension Shared: Equatable where Value: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.wrappedValue == rhs.wrappedValue
    }
}

extension Shared: CustomStringConvertible {
    public var description: String {
        "Shared(\(wrappedValue))"
    }
}

// MARK: - Internals

// @unchecked Sendable: `_value` is private and only accessed under `lock`; `save` is
// `@Sendable` and runs outside the lock.
final class _SharedReference<Value: Sendable>: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var _value: Value
    private let save: @Sendable (Value) -> Void

    init(value: Value, save: @escaping @Sendable (Value) -> Void) {
        self._value = value
        self.save = save
    }

    var value: Value {
        lock.sync { _value }
    }

    func withLock<R>(_ operation: (inout Value) throws -> R) rethrows -> R {
        let (result, newValue) = try lock.sync { () throws -> (R, Value) in
            let result = try operation(&_value)
            return (result, _value)
        }
        save(newValue)
        _SharedObservation.notifyChange(ObjectIdentifier(self))
        return result
    }
}

// @unchecked Sendable: `references` is private and only accessed under `lock`.
final class _SharedRegistry: @unchecked Sendable {
    static let shared = _SharedRegistry()

    /// Per-test registries (key: the current test, via `ComposableKitTestSupport`).
    private static let byTest = LockIsolated<[String: _SharedRegistry]>([:])

    /// The registry in use: the current test's, or the global one (the app, or a
    /// test target with an old `ComposableKitTestSupport.swift`).
    static var current: _SharedRegistry {
        guard let scope = _currentTestScope() else { return shared }
        return registry(forTest: scope)
    }

    static func registry(forTest scope: String) -> _SharedRegistry {
        byTest.withValue { registries in
            if let existing = registries[scope] { return existing }
            let registry = _SharedRegistry()
            registries[scope] = registry
            return registry
        }
    }

    private let lock = NSLock()
    private var references: [String: AnyObject] = [:]

    func reference<Key: SharedKey>(for key: Key, default defaultValue: @autoclosure () -> Key.Value) -> _SharedReference<Key.Value> {
        lock.sync {
            if let existing = references[key.id] as? _SharedReference<Key.Value> {
                return existing
            }
            let reference = _SharedReference(value: key.load() ?? defaultValue(), save: { key.save($0) })
            references[key.id] = reference
            return reference
        }
    }

    /// Removes all shared values (useful between tests).
    func reset() {
        lock.sync { references.removeAll() }
    }

    /// Removes one shared value. The next `@Shared` with that key reloads it.
    func remove<Key: SharedKey>(_ key: Key) {
        _ = lock.sync { references.removeValue(forKey: key.id) }
    }
}

/// Clears the in-memory `@Shared` values (all keys) of the current test (or
/// of the app). With an up-to-date `ComposableKitTestSupport.swift`, each test already
/// starts with its own; use it to go back to the initial value mid-test.
public func resetSharedState() {
    _SharedRegistry.current.reset()
}

/// Clears the in-memory `@Shared` value of one key. The next `@Shared` with the
/// same key goes back to the persisted value (or the default value).
public func resetSharedState<Key: SharedKey>(_ key: Key) {
    _SharedRegistry.current.remove(key)
}

@MainActor
enum _SharedObservation {
    private struct WeakCore {
        weak var core: (any _ObservableCore)?
    }

    private static var cores: [WeakCore] = []

    static func register(_ core: any _ObservableCore) {
        cores.removeAll { $0.core == nil }
        cores.append(WeakCore(core: core))
    }

    /// Notifies the live Stores; each one only redraws if its state contains the
    /// reference that changed (`_containsSharedReference`).
    nonisolated static func notifyChange(_ referenceID: ObjectIdentifier) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { notifyAll(referenceID) }
        } else {
            Task { @MainActor in notifyAll(referenceID) }
        }
    }

    private static func notifyAll(_ referenceID: ObjectIdentifier) {
        cores.removeAll { $0.core == nil }
        for entry in cores {
            entry.core?.notifyObservers(sharedChanges: [referenceID])
        }
    }
}

// MARK: - Who contains a @Shared

/// Implemented by `Shared`: identifies the shared reference.
protocol _SharedReferenceProviding {
    var _sharedReferenceID: ObjectIdentifier { get }
}

extension Shared: _SharedReferenceProviding {
    var _sharedReferenceID: ObjectIdentifier { ObjectIdentifier(reference) }
}

/// `true` if `value` (a State) has, at any level (fields, optionals,
/// collections, enums with associated values), a `@Shared` with one of the references.
/// Does not descend into classes (avoids cycles). Runs only when a `@Shared` changes.
func _containsSharedReference(_ value: Any, in ids: Set<ObjectIdentifier>, depth: Int = 0) -> Bool {
    if let shared = value as? _SharedReferenceProviding {
        return ids.contains(shared._sharedReferenceID)
    }
    guard depth < 16 else { return false }
    let mirror = Mirror(reflecting: value)
    guard mirror.displayStyle != .class, !mirror.children.isEmpty else { return false }
    return mirror.children.contains { child in
        _containsSharedReference(child.value, in: ids, depth: depth + 1)
    }
}

// MARK: - .fileStorage writes

/// Writes `.fileStorage` files on a serial queue. If several writes for the same
/// file arrive before the queue runs, only the newest is written.
/// When the app goes to the background or terminates, pending writes are flushed
/// immediately (`flush`) so they are not lost.
// @unchecked Sendable: `pending` is a `LockIsolated`; `writeLock` serializes the
// disk writes (from the queue and from `flush`); the queue is serial.
final class _FileWriter: @unchecked Sendable {
    static let shared = _FileWriter()

    private let queue = DispatchQueue(label: "ComposableKit.fileStorage", qos: .utility)
    private let pending = LockIsolated<[URL: @Sendable () -> Data?]>([:])
    /// Whoever takes a value out of `pending` writes it before releasing the lock: an
    /// older write never finishes after a newer one for the same file.
    private let writeLock = NSLock()
    private var observers: [NSObjectProtocol] = []

    init() {
        observers = Self.flushNotificationNames.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
                _FileWriter.shared.flush()
            }
        }
    }

    /// Moments when pending writes go to disk immediately.
    static var flushNotificationNames: [Notification.Name] {
        #if canImport(UIKit)
        [UIApplication.didEnterBackgroundNotification, UIApplication.willTerminateNotification]
        #elseif canImport(AppKit)
        [NSApplication.willTerminateNotification]
        #else
        []
        #endif
    }

    func write(_ encode: @escaping @Sendable () -> Data?, to url: URL) {
        let isScheduled = pending.withValue { items -> Bool in
            let alreadyScheduled = items[url] != nil
            items[url] = encode
            return alreadyScheduled
        }
        guard !isScheduled else { return } // the already scheduled write picks up the newest value
        queue.async { [self] in
            writePending(only: url)
        }
    }

    /// Writes everything pending now, on the caller's thread.
    func flush() {
        writePending(only: nil)
    }

    private func writePending(only url: URL?) {
        writeLock.lock()
        defer { writeLock.unlock() }
        let items: [(URL, @Sendable () -> Data?)] = pending.withValue { pendingItems in
            if let url {
                guard let encode = pendingItems.removeValue(forKey: url) else { return [] }
                return [(url, encode)]
            }
            defer { pendingItems.removeAll() }
            return pendingItems.map { ($0.key, $0.value) }
        }
        for (url, encode) in items {
            guard let data = encode() else { continue }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? data.write(to: url, options: .atomic)
        }
    }

    #if DEBUG
    /// Tests: holds the queue to prove that `flush` writes without it.
    func _suspendQueueForTests() { queue.suspend() }
    func _resumeQueueForTests() { queue.resume() }
    #endif
}
