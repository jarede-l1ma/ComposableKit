// MARK: - CasePathable
//
// Equivalent to `@CasePathable` from the swift-case-paths library (Point-Free).
// For each enum case the macro generates a "case path": an embed/extract
// pair that lets you reference the case by key path, e.g. `\.child`.
// It underpins `Scope`, `ifLet`, `forEach`, `store.scope` and `TestStore.receive`.

public protocol CasePathable {
    associatedtype AllCasePaths: Sendable
    static var allCasePaths: AllCasePaths { get }
}

/// An enum case treated as a value: builds (`embed`) and extracts (`extract`).
public struct AnyCasePath<Root, Value>: Sendable {
    private let _embed: @Sendable (Value) -> Root
    private let _extract: @Sendable (Root) -> Value?

    public init(embed: @escaping @Sendable (Value) -> Root, extract: @escaping @Sendable (Root) -> Value?) {
        self._embed = embed
        self._extract = extract
    }

    public func embed(_ value: Value) -> Root {
        _embed(value)
    }

    public func extract(from root: Root) -> Value? {
        _extract(root)
    }
}

/// Key path to a case: `\.didLoad`, `\.child`, `\.binding`...
public typealias CaseKeyPath<Root: CasePathable, Value> = KeyPath<Root.AllCasePaths, AnyCasePath<Root, Value>>

extension CasePathable {
    /// Extracts the case's associated value, or `nil` for any other case.
    /// ```swift
    /// action[case: \.didLoad]   // ViewData?
    /// ```
    public subscript<Value>(case keyPath: CaseKeyPath<Self, Value>) -> Value? {
        Self.allCasePaths[keyPath: keyPath].extract(from: self)
    }

    /// `true` if the value is the given case: `action.is(\.didLoad)`.
    public func `is`<Value>(_ keyPath: CaseKeyPath<Self, Value>) -> Bool {
        self[case: keyPath] != nil
    }
}
