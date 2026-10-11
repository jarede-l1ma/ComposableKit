import Combine
import Foundation
import SwiftUI

// MARK: - Store
//
// ```swift
// let store = Store(initialState: HomeFeature.State()) {
//     HomeFeature()
// } withDependencies: {
//     $0.homeClient = .mock
// }
// ```
//
// In the View (iOS 15+):
// ```swift
// @ObservedObject var store: StoreOf<HomeFeature>
// Text(store.title)                       // direct State read
// TextField("Email", text: $store.email)  // binding (Action: BindableAction)
// store.send(.tapContinue)
// ```

public typealias StoreOf<R: Reducer> = Store<R.State, R.Action>

@MainActor
@dynamicMemberLookup
public final class Store<State, Action>: ObservableObject {
    private let root: AnyObject
    private let toState: @MainActor () -> State
    private let toSend: @MainActor (Action) -> Task<Void, Never>?
    private let observeRoot: @MainActor (AnyObject, @escaping @MainActor (Set<ObjectIdentifier>) -> Void) -> Void
    private var lastState: State
    private var children: [AnyHashable: AnyObject] = [:]

    // MARK: Init

    /// Creates a feature's root Store.
    ///
    /// - Parameters:
    ///   - initialState: Initial state.
    ///   - reducer: The feature's reducer (`HomeFeature()`).
    ///   - prepareDependencies: Adjusts the dependencies of this Store tree.
    public convenience init<R: Reducer<State, Action>>(
        initialState: @autoclosure () -> R.State,
        @ReducerBuilder<State, Action> reducer: () -> R,
        withDependencies prepareDependencies: ((inout DependencyValues) -> Void)? = nil
    ) {
        var dependencies = DependencyValues._current
        prepareDependencies?(&dependencies)
        let (state, builtReducer) = DependencyValues.$_current.withValue(dependencies) {
            (initialState(), reducer())
        }
        let core = RootCore<State, Action>(
            initialState: state,
            reducer: { builtReducer.reduce(into: &$0, action: $1) },
            dependencies: dependencies
        )
        self.init(
            root: core,
            toState: { core.state },
            toSend: { core.send($0) },
            observeRoot: { core.observe(owner: $0, $1) }
        )
    }

    init(
        root: AnyObject,
        toState: @escaping @MainActor () -> State,
        toSend: @escaping @MainActor (Action) -> Task<Void, Never>?,
        observeRoot: @escaping @MainActor (AnyObject, @escaping @MainActor (Set<ObjectIdentifier>) -> Void) -> Void
    ) {
        self.root = root
        self.toState = toState
        self.toSend = toSend
        self.observeRoot = observeRoot
        self.lastState = toState()
        observeRoot(self) { [weak self] sharedChanges in
            self?.rootDidChange(sharedChanges: sharedChanges)
        }
    }

    // MARK: State

    /// Current state.
    public var state: State {
        toState()
    }

    /// Direct reads of state fields: `store.isLoading`.
    public subscript<Value>(dynamicMember keyPath: KeyPath<State, Value>) -> Value {
        state[keyPath: keyPath]
    }

    /// Redraws if the state changed, or if a `@Shared` held in this state
    /// changed (`==` cannot see it: both sides point to the same reference).
    private func rootDidChange(sharedChanges: Set<ObjectIdentifier>) {
        let newState = toState()
        let stateChanged = _isEqual(lastState, newState) != true
        let sharedChanged = !sharedChanges.isEmpty && _containsSharedReference(newState, in: sharedChanges)
        guard stateChanged || sharedChanged else { return }
        lastState = newState
        objectWillChange.send()
    }

    // MARK: Envio

    /// Sends an Action. The returned `StoreTask` lets you await or cancel the
    /// effects it started: `await store.send(.refresh).finish()`.
    @discardableResult
    public func send(_ action: Action) -> StoreTask {
        StoreTask(rawValue: toSend(action))
    }

    /// Sends an Action inside `withAnimation`.
    @discardableResult
    public func send(_ action: Action, animation: Animation?) -> StoreTask {
        withAnimation(animation) {
            send(action)
        }
    }

    // MARK: Scoping (composition)

    /// Child Store for a child feature (`Scope` in the reducer).
    public func scope<ChildState, ChildAction>(
        state toChildState: KeyPath<State, ChildState>,
        action toChildAction: CaseKeyPath<Action, ChildAction>
    ) -> Store<ChildState, ChildAction> where Action: CasePathable {
        let key: AnyHashable = [AnyHashable(toChildState), AnyHashable(toChildAction)]
        if let child = children[key] as? Store<ChildState, ChildAction> { return child }
        let casePath = Action.allCasePaths[keyPath: toChildAction]
        let parentState = toState
        let parentSend = toSend
        let child = Store<ChildState, ChildAction>(
            root: root,
            toState: { parentState()[keyPath: toChildState] },
            toSend: { parentSend(casePath.embed($0)) },
            observeRoot: observeRoot
        )
        children[key] = child
        return child
    }

    /// Optional child Store (`ifLet` in the reducer). Returns `nil` when the
    /// child state is `nil`.
    public func scope<ChildState, ChildAction>(
        state toChildState: KeyPath<State, ChildState?>,
        action toChildAction: CaseKeyPath<Action, ChildAction>
    ) -> Store<ChildState, ChildAction>? where Action: CasePathable {
        let key: AnyHashable = [AnyHashable(toChildState), AnyHashable(toChildAction)]
        guard let current = state[keyPath: toChildState] else {
            children[key] = nil
            return nil
        }
        if let child = children[key] as? Store<ChildState, ChildAction> { return child }
        let casePath = Action.allCasePaths[keyPath: toChildAction]
        let parentState = toState
        let parentSend = toSend
        let last = _Box(current)
        let child = Store<ChildState, ChildAction>(
            root: root,
            toState: {
                if let value = parentState()[keyPath: toChildState] { last.value = value }
                return last.value
            },
            toSend: { parentSend(casePath.embed($0)) },
            observeRoot: observeRoot
        )
        children[key] = child
        return child
    }

    /// Stores for the elements of a collection (`forEach` in the reducer).
    /// ```swift
    /// ForEach(store.scope(state: \.rows, action: \.rows)) { rowStore in
    ///     RowView(store: rowStore)
    /// }
    /// ```
    public func scope<ElementID: Hashable & Sendable, ElementState, ElementAction>(
        state toElements: KeyPath<State, IdentifiedArray<ElementID, ElementState>>,
        action toElementAction: CaseKeyPath<Action, IdentifiedAction<ElementID, ElementAction>>
    ) -> [Store<ElementState, ElementAction>] where Action: CasePathable {
        let elements = state[keyPath: toElements]
        let casePath = Action.allCasePaths[keyPath: toElementAction]
        let parentState = toState
        let parentSend = toSend
        var result: [Store<ElementState, ElementAction>] = []
        var liveKeys: Set<AnyHashable> = []
        for id in elements.ids {
            let key: AnyHashable = [AnyHashable(toElements), AnyHashable(toElementAction), AnyHashable(id)]
            liveKeys.insert(key)
            if let child = children[key] as? Store<ElementState, ElementAction> {
                result.append(child)
                continue
            }
            let last = _Box(elements[id: id]!)
            let child = Store<ElementState, ElementAction>(
                root: root,
                toState: {
                    if let value = parentState()[keyPath: toElements][id: id] { last.value = value }
                    return last.value
                },
                toSend: { parentSend(casePath.embed(.element(id: id, action: $0))) },
                observeRoot: observeRoot
            )
            children[key] = child
            result.append(child)
        }
        // Evict elements that left the collection from the cache.
        let prefix: [AnyHashable] = [AnyHashable(toElements), AnyHashable(toElementAction)]
        for key in children.keys where !liveKeys.contains(key) {
            if let parts = key.base as? [AnyHashable], parts.count == 3, Array(parts.prefix(2)) == prefix {
                children[key] = nil
            }
        }
        return result
    }
}

extension Store: Identifiable {
    public nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
}

// MARK: - StoreTask

/// The effects started by a `send`.
public struct StoreTask: Hashable, Sendable {
    let rawValue: Task<Void, Never>?

    /// Cancels the effects.
    public func cancel() {
        rawValue?.cancel()
    }

    /// Waits for the effects to finish.
    public func finish() async {
        await rawValue?.value
    }

    public var isCancelled: Bool {
        rawValue?.isCancelled ?? true
    }
}
