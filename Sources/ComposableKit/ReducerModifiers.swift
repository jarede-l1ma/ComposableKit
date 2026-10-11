import Foundation

// MARK: - Reducer modifiers
//
// Same syntax as TCA:
//
// ```swift
// var body: some ReducerOf<Self> {
//     BindingReducer()
//         .onChange(of: \.email) { oldValue, newValue in
//             Reduce { state, _ in
//                 state.isValid = newValue.contains("@")
//                 return .none
//             }
//         }
//     Reduce { state, action in ... }
//         ._printChanges()
//     Scope(state: \.card, action: \.card) {
//         CardFeature()
//             .dependency(\.cardClient, .mock)
//     }
// }
// ```

// MARK: - _printChanges

extension Reducer {
    /// Prints each Action and the state lines it changed (debugging).
    /// Prints nothing in Release. Do not leave it in production code: it is
    /// an investigation tool, as in TCA.
    ///
    /// - Parameter output: Where the text goes (default: `print`). Tests
    ///   pass a closure to capture the output.
    public func _printChanges(
        _ output: @escaping (String) -> Void = { print($0) }
    ) -> _PrintChangesReducer<Self> {
        _PrintChangesReducer(base: self, output: output)
    }
}

public struct _PrintChangesReducer<Base: Reducer>: Reducer {
    let base: Base
    let output: (String) -> Void

    public func reduce(into state: inout Base.State, action: Base.Action) -> Effect<Base.Action> {
        #if DEBUG
        let before = debugText(state)
        let effect = base.reduce(into: &state, action: action)
        let after = debugText(state)
        let changes = before == after
            ? "  (no state change)"
            : lineDiff(expected: before, actual: after)
                .split(separator: "\n")
                .filter { $0.hasPrefix("−") || $0.hasPrefix("+") }
                .map(Self.readableLine)
                .joined(separator: "\n")
        output("🔹 Action: \(action)\n\(changes)")
        return effect
        #else
        return base.reduce(into: &state, action: action)
        #endif
    }

    /// "−   - isLoading: true" (a diff line over the `dump`) → "  − isLoading: true":
    /// strips the `dump` marker ("- ", "▿ ") and keeps the indentation of nested fields.
    static func readableLine(_ line: Substring) -> String {
        let sign = line.prefix(1)
        let body = line.dropFirst(2)
        let indent = body.prefix { $0 == " " }.count
        var content = body.dropFirst(indent)
        if content.hasPrefix("- ") || content.hasPrefix("▿ ") { content = content.dropFirst(2) }
        return "  \(sign) " + String(repeating: " ", count: max(0, indent - 2)) + content
    }
}

// MARK: - onChange

extension Reducer {
    /// Runs `reducer` when the value of `toValue` changes after this Action.
    /// Useful with `BindingReducer`, where the field changes without a
    /// dedicated Action: `.onChange(of: \.email) { oldValue, newValue in ... }`.
    ///
    /// - Parameters:
    ///   - toValue: The observed value (key path or closure).
    ///   - reducer: Receives the old and new values; runs after this reducer,
    ///     with the same Action, and its effects are merged with this one's.
    public func onChange<Value: Equatable, Reaction: Reducer>(
        of toValue: @escaping (State) -> Value,
        @ReducerBuilder<State, Action> _ reducer: @escaping (_ oldValue: Value, _ newValue: Value) -> Reaction
    ) -> _OnChangeReducer<Self, Value, Reaction>
    where Reaction.State == State, Reaction.Action == Action {
        _OnChangeReducer(base: self, toValue: toValue, reaction: reducer)
    }
}

public struct _OnChangeReducer<Base: Reducer, Value: Equatable, Reaction: Reducer>: Reducer
where Reaction.State == Base.State, Reaction.Action == Base.Action {
    let base: Base
    let toValue: (Base.State) -> Value
    let reaction: (Value, Value) -> Reaction

    public func reduce(into state: inout Base.State, action: Base.Action) -> Effect<Base.Action> {
        let oldValue = toValue(state)
        let baseEffect = base.reduce(into: &state, action: action)
        let newValue = toValue(state)
        guard oldValue != newValue else { return baseEffect }
        let reactionEffect = reaction(oldValue, newValue).reduce(into: &state, action: action)
        return .merge(baseEffect, reactionEffect)
    }
}

// MARK: - dependency

extension Reducer {
    /// Overrides a dependency only for this reducer (e.g. a child Feature) and
    /// for the effects it creates — including a `@Dependency` read inside
    /// `.run`.
    ///
    /// ```swift
    /// Scope(state: \.card, action: \.card) {
    ///     CardFeature().dependency(\.cardClient, .mock)
    /// }
    /// ```
    public func dependency<Value: Sendable>(
        _ keyPath: WritableKeyPath<DependencyValues, Value>,
        _ value: Value
    ) -> _DependencyKeyWritingReducer<Self> {
        _DependencyKeyWritingReducer(base: self, update: _DependencyUpdate { $0[keyPath: keyPath] = value })
    }
}

// @unchecked Sendable: the closure only captures a key path (an immutable value the
// compiler does not mark as `Sendable`) and a `Sendable` value (`dependency(_:_:)`
// requires `Value: Sendable`); it neither holds nor mutates state of its own.
struct _DependencyUpdate: @unchecked Sendable {
    let apply: (inout DependencyValues) -> Void
}

public struct _DependencyKeyWritingReducer<Base: Reducer>: Reducer {
    let base: Base
    let update: _DependencyUpdate

    public func reduce(into state: inout Base.State, action: Base.Action) -> Effect<Base.Action> {
        var dependencies = DependencyValues._current
        update.apply(&dependencies)
        let effect = DependencyValues.$_current.withValue(dependencies) {
            base.reduce(into: &state, action: action)
        }
        // The Store runs effects with its own dependencies; apply the override again
        // inside each `.run` (on top of the dependencies in effect when it runs).
        return effect._applyingDependencies(update)
    }
}

extension Effect {
    func _applyingDependencies(_ update: _DependencyUpdate) -> Self {
        switch operation {
        case .none, .send, .cancel:
            return self
        case let .run(priority, operation):
            return Self(operation: .run(priority: priority) { send in
                var dependencies = DependencyValues._current
                update.apply(&dependencies)
                await DependencyValues.$_current.withValue(dependencies) {
                    await operation(send)
                }
            })
        case let .merge(effects):
            return Self(operation: .merge(effects.map { $0._applyingDependencies(update) }))
        case let .concatenate(effects):
            return Self(operation: .concatenate(effects.map { $0._applyingDependencies(update) }))
        case let .cancellable(id, cancelInFlight, effect):
            return Self(operation: .cancellable(id: id, cancelInFlight: cancelInFlight, effect: effect._applyingDependencies(update)))
        }
    }
}
