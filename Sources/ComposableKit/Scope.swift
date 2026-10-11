// MARK: - Composition
//
// ```swift
// var body: some ReducerOf<Self> {
//     Scope(state: \.header, action: \.header) { HeaderFeature() }
//     Reduce { state, action in ... }
//         .ifLet(\.detail, action: \.detail) { DetailFeature() }
//         .forEach(\.rows, action: \.rows) { RowFeature() }
// }
// ```

// MARK: - Scope

/// Runs a child reducer on a slice of the parent's state/actions.
public struct Scope<ParentState, ParentAction, Child: Reducer>: Reducer {
    let toChildState: WritableKeyPath<ParentState, Child.State>
    let toChildAction: AnyCasePath<ParentAction, Child.Action>
    let child: Child

    public init<ChildState, ChildAction>(
        state toChildState: WritableKeyPath<ParentState, ChildState>,
        action toChildAction: CaseKeyPath<ParentAction, ChildAction>,
        @ReducerBuilder<ChildState, ChildAction> child: () -> Child
    ) where ParentAction: CasePathable, Child.State == ChildState, Child.Action == ChildAction {
        self.toChildState = toChildState
        self.toChildAction = ParentAction.allCasePaths[keyPath: toChildAction]
        self.child = child()
    }

    public func reduce(into state: inout ParentState, action: ParentAction) -> Effect<ParentAction> {
        guard let childAction = toChildAction.extract(from: action) else { return .none }
        let casePath = toChildAction
        return child
            .reduce(into: &state[keyPath: toChildState], action: childAction)
            .map { casePath.embed($0) }
    }
}

// MARK: - IdentifiedAction

/// Action of a collection element (used with `forEach`).
public enum IdentifiedAction<ID: Hashable & Sendable, Action>: CasePathable {
    case element(id: ID, action: Action)

    public struct AllCasePaths: Sendable {
        public var element: AnyCasePath<IdentifiedAction, (id: ID, action: Action)> {
            AnyCasePath(
                embed: { .element(id: $0.id, action: $0.action) },
                extract: {
                    guard case let .element(id, action) = $0 else { return nil }
                    return (id, action)
                }
            )
        }
    }

    public static var allCasePaths: AllCasePaths { AllCasePaths() }
}

/// `IdentifiedActionOf<RowFeature>` = `IdentifiedAction<RowFeature.State.ID, RowFeature.Action>`.
public typealias IdentifiedActionOf<R: _ReducerTypes> = IdentifiedAction<R.State.ID, R.Action>
where R.State: Identifiable, R.State.ID: Sendable

extension IdentifiedAction: Equatable where Action: Equatable {}
extension IdentifiedAction: Sendable where Action: Sendable {}

// MARK: - Composition cancellation ids

// @unchecked Sendable: immutable; they only hold key paths (immutable values the
// compiler does not mark as `Sendable`) and `Hashable & Sendable` ids.
struct _PresentationCancelID: Hashable, @unchecked Sendable {
    let keyPath: AnyKeyPath
}

struct _ElementCancelID: Hashable, @unchecked Sendable {
    let keyPath: AnyKeyPath
    let id: AnyHashable
}

// MARK: - ifLet

extension Reducer {
    /// Integrates an optional child feature (e.g. a presented screen/modal).
    ///
    /// The child runs before the parent. When the child state becomes `nil`,
    /// the child's in-flight effects are cancelled automatically.
    public func ifLet<WrappedState, WrappedAction, Wrapped: Reducer>(
        _ toWrappedState: WritableKeyPath<State, WrappedState?>,
        action toWrappedAction: CaseKeyPath<Action, WrappedAction>,
        @ReducerBuilder<WrappedState, WrappedAction> then wrapped: () -> Wrapped,
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) -> _IfLetReducer<Self, Wrapped>
    where Action: CasePathable, Wrapped.State == WrappedState, Wrapped.Action == WrappedAction {
        _IfLetReducer(
            parent: self,
            child: wrapped(),
            toChildState: toWrappedState,
            toChildAction: Action.allCasePaths[keyPath: toWrappedAction],
            location: (fileID, filePath, line, column)
        )
    }

    /// Integrates a collection of child features.
    ///
    /// An element's effects are cancelled when it leaves the collection.
    public func forEach<ElementID: Hashable & Sendable, ElementState, ElementAction, Element: Reducer>(
        _ toElementsState: WritableKeyPath<State, IdentifiedArray<ElementID, ElementState>>,
        action toElementAction: CaseKeyPath<Action, IdentifiedAction<ElementID, ElementAction>>,
        @ReducerBuilder<ElementState, ElementAction> element: () -> Element,
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) -> _ForEachReducer<Self, ElementID, Element>
    where Action: CasePathable, Element.State == ElementState, Element.Action == ElementAction {
        _ForEachReducer(
            parent: self,
            element: element(),
            toElementsState: toElementsState,
            toElementAction: Action.allCasePaths[keyPath: toElementAction],
            location: (fileID, filePath, line, column)
        )
    }
}

public struct _IfLetReducer<Parent: Reducer, Child: Reducer>: Reducer {
    let parent: Parent
    let child: Child
    let toChildState: WritableKeyPath<Parent.State, Child.State?>
    let toChildAction: AnyCasePath<Parent.Action, Child.Action>
    let location: (StaticString, StaticString, UInt, UInt)

    public func reduce(into state: inout Parent.State, action: Parent.Action) -> Effect<Parent.Action> {
        let cancelID = _PresentationCancelID(keyPath: toChildState)
        var childEffect = Effect<Parent.Action>.none
        if let childAction = toChildAction.extract(from: action) {
            if state[keyPath: toChildState] != nil {
                let casePath = toChildAction
                childEffect = child
                    .reduce(into: &state[keyPath: toChildState]!, action: childAction)
                    .namespaced(cancelID)
                    .map { casePath.embed($0) }
                    .cancellable(id: cancelID)
            } else {
                reportIssue(
                    "\"ifLet\" received the child action \(childAction) while the child state was nil.",
                    fileID: location.0, filePath: location.1, line: location.2, column: location.3
                )
            }
        }
        let wasPresent = state[keyPath: toChildState] != nil
        let parentEffect = parent.reduce(into: &state, action: action)
        let isPresent = state[keyPath: toChildState] != nil
        let dismissEffect: Effect<Parent.Action> = wasPresent && !isPresent ? .cancel(id: cancelID) : .none
        return .merge(childEffect, parentEffect, dismissEffect)
    }
}

public struct _ForEachReducer<Parent: Reducer, ID: Hashable & Sendable, Element: Reducer>: Reducer {
    let parent: Parent
    let element: Element
    let toElementsState: WritableKeyPath<Parent.State, IdentifiedArray<ID, Element.State>>
    let toElementAction: AnyCasePath<Parent.Action, IdentifiedAction<ID, Element.Action>>
    let location: (StaticString, StaticString, UInt, UInt)

    public func reduce(into state: inout Parent.State, action: Parent.Action) -> Effect<Parent.Action> {
        var elementEffect = Effect<Parent.Action>.none
        if case let .element(id, elementAction)? = toElementAction.extract(from: action) {
            if state[keyPath: toElementsState][id: id] != nil {
                let casePath = toElementAction
                elementEffect = element
                    .reduce(into: &state[keyPath: toElementsState][id: id]!, action: elementAction)
                    .namespaced(_ElementCancelID(keyPath: toElementsState, id: id))
                    .map { casePath.embed(.element(id: id, action: $0)) }
                    .cancellable(id: _ElementCancelID(keyPath: toElementsState, id: id))
            } else {
                reportIssue(
                    "\"forEach\" received an action for element \(id), which is not in the collection.",
                    fileID: location.0, filePath: location.1, line: location.2, column: location.3
                )
            }
        }
        let idsBefore = state[keyPath: toElementsState].ids
        let parentEffect = parent.reduce(into: &state, action: action)
        let idsAfter = Set(state[keyPath: toElementsState].ids)
        let removed = idsBefore.filter { !idsAfter.contains($0) }
        let cancelEffects = removed.map {
            Effect<Parent.Action>.cancel(id: _ElementCancelID(keyPath: toElementsState, id: $0))
        }
        return .merge([elementEffect, parentEffect] + cancelEffects)
    }
}
