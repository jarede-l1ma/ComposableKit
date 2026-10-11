import Foundation

// MARK: - Dependencies
//
// Same model as TCA (swift-dependencies):
//
// ```swift
// // 1. Client
// struct HomeClient: Sendable {
//     var fetchData: @Sendable () async throws -> HomeResponse
// }
//
// // 2. live/test/preview values
// extension HomeClient: DependencyKey {
//     static let liveValue = HomeClient(fetchData: { try await HomeService().fetchData() })
//     static let testValue = HomeClient(fetchData: { throw UnimplementedError("HomeClient.fetchData") })
// }
//
// // 3. Access
// extension DependencyValues {
//     var homeClient: HomeClient {
//         get { self[HomeClient.self] }
//         set { self[HomeClient.self] = newValue }
//     }
// }
//
// // 4. Use in the feature
// @Dependency(\.homeClient) var homeClient
// ```

/// Context in which dependencies are being resolved.
public enum DependencyContext: Sendable {
    case live
    case preview
    case test
}

/// A key with test and preview values.
public protocol TestDependencyKey {
    associatedtype Value: Sendable = Self
    static var testValue: Value { get }
    static var previewValue: Value { get }
}

extension TestDependencyKey {
    public static var previewValue: Value { testValue }
}

/// A key with a production value.
public protocol DependencyKey: TestDependencyKey {
    static var liveValue: Value { get }
}

extension DependencyKey {
    public static var previewValue: Value { liveValue }

    /// Default: reports that the dependency was used in a test without being
    /// overridden and returns the live value.
    public static var testValue: Value {
        reportIssue(
            """
            The dependency "\(Self.self)" was accessed in a test without a test value.

            Override it in the TestStore:
                TestStore(...) { ... } withDependencies: { $0.<dependency> = ... }
            or define "static let testValue" on the key.
            """
        )
        return liveValue
    }
}

/// Error for clients' `testValue`: fails if the test calls something it did
/// not override.
public struct UnimplementedError: Error, CustomStringConvertible {
    public let description: String

    public init(_ endpoint: String) {
        self.description = "Unimplemented endpoint in test: \(endpoint)"
        reportIssue("Unimplemented endpoint called in test: \(endpoint)")
    }
}

// MARK: - DependencyValues

public struct DependencyValues: Sendable {
    /// Values in use in the current Task (task-local). The `Store` sets it
    /// when running the reducer and the effects.
    @TaskLocal public static var _current = DependencyValues()

    public var context: DependencyContext
    private var storage: [ObjectIdentifier: any Sendable] = [:]

    public init() {
        self.init(context: DependencyValues.defaultContext)
    }

    public init(context: DependencyContext) {
        self.context = context
        if context == .test {
            // Its own counter (not the static `testValue`, global to the process):
            // every TestStore starts at 00000000-…-000000000000, in any execution
            // order. Copies (effects of the same TestStore) share the counter.
            self.uuid = .incrementing
        }
    }

    public subscript<Key: TestDependencyKey>(key: Key.Type) -> Key.Value {
        get {
            if let value = storage[ObjectIdentifier(key)] as? Key.Value {
                return value
            }
            switch context {
            case .live:
                if let liveKey = key as? any DependencyKey.Type {
                    return Self.liveValue(of: liveKey) as! Key.Value
                }
                reportIssue("The dependency \"\(Key.self)\" has no \"liveValue\" (it is only a TestDependencyKey).")
                return Key.testValue
            case .preview:
                return Key.previewValue
            case .test:
                return Key.testValue
            }
        }
        set {
            storage[ObjectIdentifier(key)] = newValue
        }
    }

    /// `true` if the dependency was set explicitly (`withDependencies`).
    func _isOverridden<Key: TestDependencyKey>(_ key: Key.Type) -> Bool {
        storage[ObjectIdentifier(key)] != nil
    }

    private static func liveValue<K: DependencyKey>(of key: K.Type) -> any Sendable {
        K.liveValue
    }

    static let defaultContext: DependencyContext = {
        let environment = ProcessInfo.processInfo.environment
        if environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            return .preview
        }
        let processName = ProcessInfo.processInfo.processName
        let isTesting = environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || processName == "xctest"
            || processName.hasSuffix("PackageTests")
            || processName == "swiftpm-testing-helper"
        // Does not use "the XCTestCase class exists": a debug framework that loads
        // XCTest into the app (Debug) would make the whole app run with `testValue`s.
        return isTesting ? .test : .live
    }()
}

// MARK: - @Dependency

// @unchecked Sendable: immutable; only holds the key path (read in `wrappedValue` from
// the current Task's `DependencyValues`). Requiring `KeyPath & Sendable` would break
// `@Dependency(\.x)` in apps using the Swift 5 language mode.
/// Reads a dependency from the `DependencyValues` in use.
///
/// Inside `Effect.run`, capture the dependency first:
/// `.run { [homeClient] send in ... }`.
@propertyWrapper
public struct Dependency<Value>: @unchecked Sendable {
    private let keyPath: KeyPath<DependencyValues, Value>

    public init(_ keyPath: KeyPath<DependencyValues, Value>) {
        self.keyPath = keyPath
    }

    public var wrappedValue: Value {
        DependencyValues._current[keyPath: keyPath]
    }
}

// MARK: - withDependencies

/// Runs `operation` with modified dependencies.
@discardableResult
public func withDependencies<R>(
    _ updateValuesForOperation: (inout DependencyValues) throws -> Void,
    operation: () throws -> R
) rethrows -> R {
    var dependencies = DependencyValues._current
    try updateValuesForOperation(&dependencies)
    return try DependencyValues.$_current.withValue(dependencies, operation: operation)
}

/// Runs the (asynchronous) `operation` with modified dependencies.
///
/// `nonisolated(nonsending)`: runs on the caller's executor (replaces the
/// old `isolation: #isolation` parameter, which used a deprecated
/// `TaskLocal.withValue` overload). Available since iOS 13.
@discardableResult
nonisolated(nonsending) public func withDependencies<R>(
    _ updateValuesForOperation: (inout DependencyValues) throws -> Void,
    operation: nonisolated(nonsending) () async throws -> R
) async rethrows -> R {
    var dependencies = DependencyValues._current
    try updateValuesForOperation(&dependencies)
    return try await DependencyValues.$_current.withValue(dependencies, operation: operation)
}

// MARK: - Built-in dependencies

/// Injectable clock (equivalent to TCA's `continuousClock`, compatible
/// with iOS 15). In tests use `TestClock` or `ImmediateClock`.
public protocol EffectClock: Sendable {
    func sleep(for seconds: Double) async throws
}

public struct LiveEffectClock: EffectClock {
    public init() {}

    public func sleep(for seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}

/// A clock that does not wait (useful in tests that do not control time).
public struct ImmediateClock: EffectClock {
    public init() {}

    public func sleep(for seconds: Double) async throws {
        try Task.checkCancellation()
        await Task.yield()
    }
}

private enum ContinuousClockKey: DependencyKey {
    static let liveValue: any EffectClock = LiveEffectClock()
    static let testValue: any EffectClock = ImmediateClock()
}

/// Injectable UUID generator.
public struct UUIDGenerator: Sendable {
    private let generate: @Sendable () -> UUID

    public init(_ generate: @escaping @Sendable () -> UUID) {
        self.generate = generate
    }

    public func callAsFunction() -> UUID { generate() }

    /// Sequential UUIDs: 00000000-0000-0000-0000-000000000000, ...0001, ...
    public static var incrementing: Self {
        let counter = LockIsolated(0)
        return Self {
            let value = counter.withValue { value -> Int in
                defer { value += 1 }
                return value
            }
            return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", value))!
        }
    }
}

private enum UUIDGeneratorKey: DependencyKey {
    static let liveValue = UUIDGenerator { UUID() }
    static let testValue = UUIDGenerator.incrementing
}

/// Injectable current date.
public struct DateGenerator: Sendable {
    private let generate: @Sendable () -> Date

    public init(_ generate: @escaping @Sendable () -> Date) {
        self.generate = generate
    }

    public var now: Date { generate() }

    public static func constant(_ date: Date) -> Self { Self { date } }
}

private enum DateGeneratorKey: DependencyKey {
    static let liveValue = DateGenerator { Date() }
    static let testValue = DateGenerator.constant(Date(timeIntervalSince1970: 1_234_567_890))
}

extension DependencyValues {
    public var continuousClock: any EffectClock {
        get { self[ContinuousClockKey.self] }
        set { self[ContinuousClockKey.self] = newValue }
    }

    public var uuid: UUIDGenerator {
        get { self[UUIDGeneratorKey.self] }
        set { self[UUIDGeneratorKey.self] = newValue }
    }

    public var date: DateGenerator {
        get { self[DateGeneratorKey.self] }
        set { self[DateGeneratorKey.self] = newValue }
    }
}
