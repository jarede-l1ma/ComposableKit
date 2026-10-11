import Combine
import Foundation
@testable import ComposableKit
import SwiftUI
import Testing

@MainActor
@Suite("Store")
struct StoreBehaviorTests {

    @Test
    func stateAndDynamicMemberLookup() {
        let store = Store(initialState: CounterFeature.State(count: 5)) { CounterFeature() }
        #expect(store.state.count == 5)
        #expect(store.count == 5)
    }

    @Test
    func withDependenciesOverridesAreUsedByEffects() async {
        let store = Store(initialState: CounterFeature.State()) {
            CounterFeature()
        } withDependencies: {
            $0.numberFact.fetch = { "override \($0)" }
        }

        await store.send(.factButtonTapped).finish()
        #expect(store.fact == "override 0")
    }

    @Test
    func sendWithAnimationSendsTheAction() {
        let store = Store(initialState: CounterFeature.State()) { CounterFeature() }
        store.send(.increment, animation: .default)
        #expect(store.count == 1)
    }

    @Test
    func storeTaskCancelStopsEffects() async {
        let clock = TestClock()
        let store = Store(initialState: CounterFeature.State()) {
            CounterFeature()
        } withDependencies: {
            $0.numberFact.fetch = { n in try await clock.sleep(for: 1); return "\(n)" }
        }

        let task = store.send(.factButtonTapped)
        task.cancel()
        await task.finish()
        await clock.advance(by: 1)

        #expect(task.isCancelled)
        #expect(store.fact == nil)
        #expect(store.isLoading == true) // a resposta nunca chegou
    }

    @Test
    func sendWithoutEffectsReturnsEmptyTask() async {
        let store = Store(initialState: CounterFeature.State()) { CounterFeature() }
        let task = store.send(.increment)
        #expect(task.isCancelled) // no effects: nothing to wait for
        await task.finish()
    }

    @Test
    func deallocatingStoreCancelsEffects() async {
        let clock = TestClock()
        let cancelled = LockIsolated(false)
        var store: StoreOf<CounterFeature>? = Store(initialState: CounterFeature.State()) {
            CounterFeature()
        } withDependencies: {
            $0.numberFact.fetch = { _ in
                do {
                    try await clock.sleep(for: 10)
                } catch {
                    cancelled.setValue(true)
                    throw error
                }
                return ""
            }
        }
        weak let weakStore = store

        store?.send(.factButtonTapped)
        await Task.megaYield()
        store = nil
        await Task.megaYield()

        #expect(weakStore == nil)
        #expect(cancelled.value)
    }

    // MARK: Observation

    @Test
    func objectWillChangeIgnoresEqualStates() {
        let store = Store(initialState: CounterFeature.State()) { CounterFeature() }
        let changes = LockIsolated(0)
        let cancellable = store.objectWillChange.sink { changes.withValue { $0 += 1 } }

        store.send(.increment)
        store.send(.cancelTapped) // isLoading is already false: same state
        store.send(.decrement)

        #expect(changes.value == 2)
        _ = cancellable
    }

    @Test
    func scopedStoreOnlyNotifiesWhenChildStateChanges() {
        let store = Store(initialState: ParentFeature.State()) { ParentFeature() }
        let counter = store.scope(state: \.counter, action: \.counter)
        let changes = LockIsolated(0)
        let cancellable = counter.objectWillChange.sink { changes.withValue { $0 += 1 } }

        store.send(.showDetail)        // does not touch counter
        store.send(.addRow(id: 1))     // does not touch counter
        counter.send(.increment)       // mexe

        #expect(changes.value == 1)
        _ = cancellable
    }

    // MARK: Escopo

    @Test
    func scopeIsCachedPerKeyPath() {
        let store = Store(initialState: ParentFeature.State()) { ParentFeature() }
        #expect(store.scope(state: \.counter, action: \.counter) === store.scope(state: \.counter, action: \.counter))
    }

    @Test
    func optionalScopeFollowsPresentation() {
        let store = Store(initialState: ParentFeature.State()) { ParentFeature() }
        #expect(store.scope(state: \.detail, action: \.detail) == nil)

        store.send(.showDetail)
        let detail = store.scope(state: \.detail, action: \.detail)
        detail?.send(.increment)
        detail?.send(.increment)
        #expect(detail?.count == 2)

        store.send(.hideDetail)
        #expect(store.scope(state: \.detail, action: \.detail) == nil)
        // The old Store stays readable (last value) for exit animations.
        #expect(detail?.count == 2)
    }

    @Test
    func optionalScopeIsRecreatedAfterNewPresentation() {
        let store = Store(initialState: ParentFeature.State()) { ParentFeature() }
        store.send(.showDetail)
        let first = store.scope(state: \.detail, action: \.detail)
        store.send(.hideDetail)
        _ = store.scope(state: \.detail, action: \.detail)
        store.send(.showDetail)
        let second = store.scope(state: \.detail, action: \.detail)
        #expect(first !== second)
        #expect(second?.count == 0)
    }

    @Test
    func forEachScopeKeepsOrderCachesAndDropsRemoved() {
        let store = Store(initialState: ParentFeature.State()) { ParentFeature() }
        store.send(.addRow(id: 1))
        store.send(.addRow(id: 2))
        store.send(.addRow(id: 3))

        let rows = store.scope(state: \.rows, action: \.rows)
        #expect(rows.map { $0.state.id } == [1, 2, 3])

        rows[2].send(.toggle)
        #expect(store.rows[id: 3]?.isOn == true)

        store.send(.removeRow(id: 2))
        let after = store.scope(state: \.rows, action: \.rows)
        #expect(after.map { $0.state.id } == [1, 3])
        #expect(after[0] === rows[0])
        #expect(after[1] === rows[2])
        #expect(rows[1].state.id == 2) // a removed Store keeps its last value
    }

    @Test
    func storesAreIdentifiable() {
        let store = Store(initialState: CounterFeature.State()) { CounterFeature() }
        #expect(store.id == ObjectIdentifier(store))
    }
}
