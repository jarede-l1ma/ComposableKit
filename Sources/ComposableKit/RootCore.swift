import Foundation

// MARK: - RootCore
//
// Engine of a Store tree: holds the state, runs the reducer, executes the
// effects (with cancellation) and notifies observing Stores. `Store` and
// `TestStore` are facades over it.

@MainActor
package protocol _ObservableCore: AnyObject {
    /// `sharedChanges`: `@Shared` references that changed (empty = state only).
    func notifyObservers(sharedChanges: Set<ObjectIdentifier>)
}

@MainActor
package final class RootCore<State, Action>: _ObservableCore {
    package private(set) var state: State
    package var dependencies: DependencyValues
    /// Called after each reduced Action (used by the TestStore).
    package var onAction: ((Action, State) -> Void)?

    private let reducer: (inout State, Action) -> Effect<Action>
    private var buffer: [Action] = []
    private var isSending = false
    private var pendingSharedChanges: Set<ObjectIdentifier> = []
    private let tasks = _TaskBag()
    private var cancellations: [_CancelID: Set<UUID>] = [:]
    private var observers: [Observer] = []

    private struct Observer {
        weak var owner: AnyObject?
        let callback: @MainActor (_ sharedChanges: Set<ObjectIdentifier>) -> Void
    }

    package init(
        initialState: State,
        reducer: @escaping (inout State, Action) -> Effect<Action>,
        dependencies: DependencyValues
    ) {
        self.state = initialState
        self.reducer = reducer
        self.dependencies = dependencies
        _SharedObservation.register(self)
    }

    deinit {
        tasks.cancelAll()
    }

    /// Number of in-flight effects.
    package var inFlightEffectCount: Int { tasks.count }

    package func cancelAllEffects() {
        tasks.cancelAll()
        cancellations.removeAll()
    }

    // MARK: Observation

    package func observe(owner: AnyObject, _ callback: @escaping @MainActor (_ sharedChanges: Set<ObjectIdentifier>) -> Void) {
        observers.append(Observer(owner: owner, callback: callback))
    }

    package func notifyObservers(sharedChanges: Set<ObjectIdentifier>) {
        // During the reducer `state` is under exclusive access (`inout`): reading
        // it now (e.g. a `@Shared` mutated in the reducer) would violate
        // exclusivity. `drain` notifies when it finishes.
        if isSending {
            pendingSharedChanges.formUnion(sharedChanges)
            return
        }
        observers.removeAll { $0.owner == nil }
        for observer in observers {
            observer.callback(sharedChanges)
        }
    }

    // MARK: Envio

    package func send(_ action: Action) -> Task<Void, Never>? {
        buffer.append(action)
        return drain()
    }

    private func drain() -> Task<Void, Never>? {
        guard !isSending else { return nil }
        isSending = true
        var spawned: [Task<Void, Never>] = []
        while !buffer.isEmpty {
            let action = buffer.removeFirst()
            let effect = DependencyValues.$_current.withValue(dependencies) {
                reducer(&state, action)
            }
            onAction?(action, state)
            spawned += execute(effect)
        }
        isSending = false
        let sharedChanges = pendingSharedChanges
        pendingSharedChanges = []
        notifyObservers(sharedChanges: sharedChanges)
        return _combine(spawned)
    }

    // MARK: Running effects

    private func execute(_ effect: Effect<Action>) -> [Task<Void, Never>] {
        switch effect.operation {
        case .none:
            return []

        case let .send(action):
            buffer.append(action)
            if isSending { return [] }
            return drain().map { [$0] } ?? []

        case let .cancel(id):
            cancel(id: id)
            return []

        case let .merge(effects):
            return effects.flatMap { execute($0) }

        case let .concatenate(effects):
            let uuid = UUID()
            let task = Task { @MainActor [weak self] in
                for effect in effects {
                    guard !Task.isCancelled, let self else { break }
                    let inner = self.execute(effect)
                    await withTaskCancellationHandler {
                        for task in inner { await task.value }
                    } onCancel: {
                        for task in inner { task.cancel() }
                    }
                }
                self?.tasks.remove(uuid)
            }
            tasks.insert(uuid, task)
            return [task]

        case let .cancellable(id, cancelInFlight, effect):
            if cancelInFlight { cancel(id: id) }
            let inner = execute(effect)
            guard !inner.isEmpty else { return [] }
            let uuid = UUID()
            let task = Task { @MainActor [weak self] in
                await withTaskCancellationHandler {
                    for task in inner { await task.value }
                } onCancel: {
                    for task in inner { task.cancel() }
                }
                self?.finishCancellable(id: id, uuid: uuid)
            }
            tasks.insert(uuid, task)
            cancellations[id, default: []].insert(uuid)
            return [task]

        case let .run(priority, operation):
            let uuid = UUID()
            let dependencies = self.dependencies
            let send = Send<Action> { [weak self] action in
                _ = self?.send(action)
            }
            let task = Task(priority: priority) { @MainActor [weak self] in
                await DependencyValues.$_current.withValue(dependencies) {
                    await operation(send)
                }
                self?.tasks.remove(uuid)
            }
            tasks.insert(uuid, task)
            return [task]
        }
    }

    private func cancel(id: _CancelID) {
        guard let uuids = cancellations.removeValue(forKey: id) else { return }
        tasks.cancel(uuids)
    }

    private func finishCancellable(id: _CancelID, uuid: UUID) {
        tasks.remove(uuid)
        cancellations[id]?.remove(uuid)
        if cancellations[id]?.isEmpty == true {
            cancellations[id] = nil
        }
    }
}
