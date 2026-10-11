import SwiftUI

// MARK: - Bindings (forms)
//
// ```swift
// @Reducer
// struct LoginFeature {
//     @ObservableState
//     struct State: Equatable {
//         var email = ""
//         var acceptsTerms = false
//     }
//     enum Action: BindableAction {
//         case binding(BindingAction<State>)
//         case tapSubmit
//     }
//     var body: some ReducerOf<Self> {
//         BindingReducer()
//         Reduce { state, action in
//             switch action {
//             case .binding(\.email):     // react to a specific field
//                 return .none
//             case .binding, .tapSubmit:
//                 return .none
//             }
//         }
//     }
// }
//
// // View
// @ObservedObject var store: StoreOf<LoginFeature>
// TextField("Email", text: $store.email)
// Toggle("I accept", isOn: $store.acceptsTerms)
// ```

// @unchecked Sendable: immutable; `value` and the closures only hold the key path and a
// `Sendable` value (`set(_:_:)` requires `Value: Sendable`). `PartialKeyPath` is not
// `Sendable` to the compiler, but key paths are immutable values.
/// Action that changes a state field from a View `Binding`.
public struct BindingAction<Root>: Equatable, @unchecked Sendable {
    public let keyPath: PartialKeyPath<Root>
    let set: (inout Root) -> Void
    let value: Any
    let valueIsEqualTo: (Any) -> Bool

    /// Action that assigns `value` to the `keyPath` field.
    public static func set<Value: Equatable & Sendable>(
        _ keyPath: WritableKeyPath<Root, Value>,
        _ value: Value
    ) -> Self {
        Self(
            keyPath: keyPath,
            set: { $0[keyPath: keyPath] = value },
            value: value,
            valueIsEqualTo: { ($0 as? Value) == value }
        )
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.keyPath == rhs.keyPath && lhs.valueIsEqualTo(rhs.value)
    }

    /// Enables `case .binding(\.email):` in the reducer's switch.
    public static func ~= <Value>(keyPath: WritableKeyPath<Root, Value>, bindingAction: Self) -> Bool {
        keyPath == bindingAction.keyPath
    }
}

extension BindingAction: CustomStringConvertible {
    public var description: String {
        "BindingAction.set(\(keyPath), \(value))"
    }
}

/// An Action that has `case binding(BindingAction<State>)`.
///
/// `@CasePathable` (applied by `@Reducer`) generates the `_bindingAction`
/// implementation automatically.
public protocol BindableAction {
    associatedtype State
    static func binding(_ action: BindingAction<State>) -> Self
    var _bindingAction: BindingAction<State>? { get }
}

extension BindableAction {
    /// Shorthand: `.set(\.email, "a@b.com")`.
    public static func set<Value: Equatable & Sendable>(
        _ keyPath: WritableKeyPath<State, Value>,
        _ value: Value
    ) -> Self {
        .binding(.set(keyPath, value))
    }
}

/// Applies `BindingAction`s to the state. Place it before `Reduce` in `body`.
public struct BindingReducer<State, Action: BindableAction>: Reducer where Action.State == State {
    public init() {}

    public func reduce(into state: inout State, action: Action) -> Effect<Action> {
        guard let bindingAction = action._bindingAction else { return .none }
        bindingAction.set(&state)
        return .none
    }
}

// MARK: - Bindings on the Store

extension Store where Action: BindableAction, Action.State == State {
    /// Field reads and writes: `$store.email` produces a `Binding<String>`
    /// that sends `.binding(.set(\.email, newValue))`.
    public subscript<Value: Equatable & Sendable>(
        dynamicMember keyPath: WritableKeyPath<State, Value>
    ) -> Value {
        get { state[keyPath: keyPath] }
        set { send(.binding(.set(keyPath, newValue))) }
    }
}
