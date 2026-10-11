import Foundation
import ComposableKit
import Testing

@MainActor
@Suite("TestStore + Effects")
struct IntegrationTestStoreTests {
    @Test
    func syncActionsChangeState() async {
        let store = TestStore(initialState: CounterFeature.State()) {
            CounterFeature()
        }

        await store.send(.increment) { $0.count = 1 }
        await store.send(.increment) { $0.count = 2 }
        await store.send(.decrement) { $0.count = 1 }
    }

    @Test
    func runEffectSendsResponse() async {
        let store = TestStore(initialState: CounterFeature.State(count: 3)) {
            CounterFeature()
        } withDependencies: {
            $0.numberFact.fetch = { "\($0) is odd" }
        }

        await store.send(.factButtonTapped) { $0.isLoading = true }
        await store.receive(\.factResponse, "3 is odd") {
            $0.isLoading = false
            $0.fact = "3 is odd"
        }
    }

    @Test
    func runEffectErrorGoesToCatch() async {
        struct Failure: Error, CustomStringConvertible { var description: String { "failed" } }
        let store = TestStore(initialState: CounterFeature.State()) {
            CounterFeature()
        } withDependencies: {
            $0.numberFact.fetch = { _ in throw Failure() }
        }

        await store.send(.factButtonTapped) { $0.isLoading = true }
        await store.receive(.factFailed("failed")) {
            $0.isLoading = false
            $0.fact = "failed"
        }
    }

    @Test
    func cancellationStopsInFlightEffect() async {
        let clock = TestClock()
        let store = TestStore(initialState: CounterFeature.State()) {
            CounterFeature()
        } withDependencies: {
            $0.numberFact.fetch = { number in
                try await clock.sleep(for: 1)
                return "\(number)"
            }
        }

        await store.send(.factButtonTapped) { $0.isLoading = true }
        await store.send(.cancelTapped) { $0.isLoading = false }
        await clock.advance(by: 1)
        // No Action received: the effect was cancelled.
        await store.finish()
    }

    @Test
    func cancelInFlightKeepsOnlyLatestRequest() async {
        let clock = TestClock()
        let store = TestStore(initialState: CounterFeature.State()) {
            CounterFeature()
        } withDependencies: {
            $0.numberFact.fetch = { number in
                try await clock.sleep(for: 1)
                return "fact \(number)"
            }
        }

        await store.send(.factButtonTapped) { $0.isLoading = true }
        await store.send(.increment) { $0.count = 1 }
        await store.send(.factButtonTapped)
        await clock.advance(by: 1)
        await store.receive(\.factResponse, "fact 1") {
            $0.isLoading = false
            $0.fact = "fact 1"
        }
    }

    @Test
    func concatenateRunsInOrder() async {
        let store = TestStore(initialState: SequenceFeature.State()) {
            SequenceFeature()
        }

        await store.send(.start)
        await store.receive(.append("a")) { $0.log = ["a"] }
        await store.receive(.append("b")) { $0.log = ["a", "b"] }
        await store.receive(.append("c")) { $0.log = ["a", "b", "c"] }
    }

    @Test
    func debounceWithTestClock() async {
        let clock = TestClock()
        let store = TestStore(initialState: SearchFeature.State()) {
            SearchFeature()
        } withDependencies: {
            $0.continuousClock = clock
        }

        await store.send(.queryChanged("a")) { $0.query = "a" }
        await clock.advance(by: 0.1)
        await store.send(.queryChanged("ab")) { $0.query = "ab" }
        await clock.advance(by: 0.3)
        await store.receive(\.didSearch, ["AB"]) { $0.results = ["AB"] }
    }

    @Test
    func reportsWrongStateAssertion() async {
        let store = TestStore(initialState: CounterFeature.State()) {
            CounterFeature()
        }

        await withKnownIssue {
            await store.send(.increment) { $0.count = 2 }
        }
    }

    @Test
    func reportsUnreceivedActionsAndUnimplementedDependency() async {
        await withKnownIssue {
            let store = TestStore(initialState: CounterFeature.State()) {
                CounterFeature()
            }
            // numberFact was not overridden: testValue throws UnimplementedError
            await store.send(.factButtonTapped) { $0.isLoading = true }
            await store.finish()
        }
    }

    @Test
    func nonExhaustiveIgnoresUnassertedChanges() async {
        let store = TestStore(initialState: CounterFeature.State()) {
            CounterFeature()
        } withDependencies: {
            $0.numberFact.fetch = { "fact \($0)" }
        }
        store.exhaustivity = .off

        await store.send(.increment)
        await store.send(.factButtonTapped)
        await store.receive(\.factResponse) { $0.fact = "fact 1" }
        #expect(store.state.count == 1)
    }
}

@MainActor
@Suite("Composition")
struct IntegrationCompositionTests {
    @Test
    func scopeRunsChildReducer() async {
        let store = TestStore(initialState: ParentFeature.State()) {
            ParentFeature()
        }

        await store.send(.counter(.increment)) { $0.counter.count = 1 }
    }

    @Test
    func ifLetRunsChildWhilePresented() async {
        let store = TestStore(initialState: ParentFeature.State()) {
            ParentFeature()
        }

        await store.send(.showDetail) { $0.detail = CounterFeature.State() }
        await store.send(.detail(.increment)) { $0.detail?.count = 1 }
        await store.send(.hideDetail) { $0.detail = nil }
    }

    @Test
    func ifLetCancelsChildEffectsOnDismiss() async {
        let clock = TestClock()
        let store = TestStore(initialState: ParentFeature.State()) {
            ParentFeature()
        } withDependencies: {
            $0.numberFact.fetch = { number in
                try await clock.sleep(for: 1)
                return "\(number)"
            }
        }

        await store.send(.showDetail) { $0.detail = CounterFeature.State() }
        await store.send(.detail(.factButtonTapped)) { $0.detail?.isLoading = true }
        await store.send(.hideDetail) { $0.detail = nil }
        await clock.advance(by: 1)
        await store.finish()
    }

    @Test
    func forEachRoutesElementActionsAndCancelsRemoved() async {
        let clock = TestClock()
        let store = TestStore(initialState: ParentFeature.State()) {
            ParentFeature()
        } withDependencies: {
            $0.continuousClock = clock
        }

        await store.send(.addRow(id: 1)) { $0.rows = [RowFeature.State(id: 1)] }
        await store.send(.rows(.element(id: 1, action: .toggle))) { $0.rows[id: 1]?.isOn = true }
        await store.send(.rows(.element(id: 1, action: .startTimer)))
        await clock.advance(by: 1)
        await store.receive(.rows(.element(id: 1, action: .tick))) { $0.rows[id: 1]?.ticks = 1 }
        await store.send(.removeRow(id: 1)) { $0.rows = [] }
        await clock.advance(by: 5)
        await store.finish()
    }

    /// Regression: cancellation ids live in each element's namespace. Before,
    /// row 2's `cancelInFlight` cancelled row 1's request.
    @Test
    func forEachRowsWithSameCancelIDDoNotCancelEachOther() async {
        let clock = TestClock()
        let store = TestStore(initialState: ParentFeature.State(rows: [.init(id: 1), .init(id: 2)])) {
            ParentFeature()
        } withDependencies: {
            $0.continuousClock = clock
        }

        await store.send(.rows(.element(id: 1, action: .load)))
        await store.send(.rows(.element(id: 2, action: .load)))
        await clock.advance(by: 1)
        await store.receive(.rows(.element(id: 1, action: .loaded(1)))) { $0.rows[id: 1]?.loaded = 1 }
        await clock.advance(by: 1)
        await store.receive(.rows(.element(id: 2, action: .loaded(2)))) { $0.rows[id: 2]?.loaded = 2 }
    }

    @Test
    func forEachRowCancelInFlightStillCancelsItsOwnRequest() async {
        let clock = TestClock()
        let store = TestStore(initialState: ParentFeature.State(rows: [.init(id: 1)])) {
            ParentFeature()
        } withDependencies: {
            $0.continuousClock = clock
        }

        await store.send(.rows(.element(id: 1, action: .load)))
        await store.send(.rows(.element(id: 1, action: .load)))
        await clock.advance(by: 1)
        await store.receive(.rows(.element(id: 1, action: .loaded(1)))) { $0.rows[id: 1]?.loaded = 1 }
        await store.finish() // a single response: the first request was cancelled
    }

    /// Regression: the `ifLet` child does not cancel the effect of a sibling of the
    /// same Feature in a `Scope` (both use `CounterFeature.CancelID.fact`).
    @Test
    func ifLetChildDoesNotCancelScopedSiblingWithSameCancelID() async {
        let clock = TestClock()
        let store = TestStore(initialState: ParentFeature.State()) {
            ParentFeature()
        } withDependencies: {
            $0.numberFact.fetch = { number in
                try await clock.sleep(for: Double(number) + 1)
                return "\(number)"
            }
        }

        await store.send(.counter(.increment)) { $0.counter.count = 1 }
        await store.send(.counter(.factButtonTapped)) { $0.counter.isLoading = true }
        await store.send(.showDetail) { $0.detail = CounterFeature.State() }
        await store.send(.detail(.factButtonTapped)) { $0.detail?.isLoading = true }
        await clock.advance(by: 1)
        await store.receive(.detail(.factResponse("0"))) {
            $0.detail?.isLoading = false
            $0.detail?.fact = "0"
        }
        await clock.advance(by: 1)
        await store.receive(.counter(.factResponse("1"))) {
            $0.counter.isLoading = false
            $0.counter.fact = "1"
        }
    }

    @Test
    func ifLetChildCanCancelItsOwnEffect() async {
        let clock = TestClock()
        let store = TestStore(initialState: ParentFeature.State()) {
            ParentFeature()
        } withDependencies: {
            $0.numberFact.fetch = { number in
                try await clock.sleep(for: 1)
                return "\(number)"
            }
        }

        await store.send(.showDetail) { $0.detail = CounterFeature.State() }
        await store.send(.detail(.factButtonTapped)) { $0.detail?.isLoading = true }
        await store.send(.detail(.cancelTapped)) { $0.detail?.isLoading = false }
        await clock.advance(by: 1)
        await store.finish() // no receive: the child's effect was cancelled
    }
}

@MainActor
@Suite("Store")
struct IntegrationStoreTests {
    @Test
    func sendUpdatesStateAndDynamicMemberLookup() {
        let store = Store(initialState: CounterFeature.State()) {
            CounterFeature()
        }

        store.send(.increment)

        #expect(store.count == 1)
        #expect(store.state.count == 1)
    }

    @Test
    func sendReturnsTaskThatCanBeAwaited() async {
        let store = Store(initialState: CounterFeature.State()) {
            CounterFeature()
        } withDependencies: {
            $0.numberFact.fetch = { "fact \($0)" }
        }

        await store.send(.factButtonTapped).finish()

        #expect(store.fact == "fact 0")
        #expect(store.isLoading == false)
    }

    @Test
    func scopedStoresSendToParent() {
        let store = Store(initialState: ParentFeature.State()) {
            ParentFeature()
        }

        let counter = store.scope(state: \.counter, action: \.counter)
        counter.send(.increment)
        #expect(store.counter.count == 1)
        #expect(counter.count == 1)
        #expect(store.scope(state: \.counter, action: \.counter) === counter)

        #expect(store.scope(state: \.detail, action: \.detail) == nil)
        store.send(.showDetail)
        let detail = store.scope(state: \.detail, action: \.detail)
        detail?.send(.increment)
        #expect(store.detail?.count == 1)

        store.send(.addRow(id: 1))
        store.send(.addRow(id: 2))
        let rows = store.scope(state: \.rows, action: \.rows)
        #expect(rows.map(\.id).count == 2)
        rows[1].send(.toggle)
        #expect(store.rows[id: 2]?.isOn == true)
    }

    @Test
    func bindingThroughDynamicMember() {
        let store = Store(initialState: FormFeature.State()) {
            FormFeature()
        }

        store.email = "a@b.com"

        #expect(store.email == "a@b.com")
        #expect(store.isValid)
    }

    @Test
    func objectWillChangeFiresOnlyWhenStateChanges() {
        let store = Store(initialState: FormFeature.State()) {
            FormFeature()
        }
        var changes = 0
        let cancellable = store.objectWillChange.sink { changes += 1 }

        store.send(.submit)               // does not change the state
        store.send(.set(\.acceptsTerms, true))

        #expect(changes == 1)
        _ = cancellable
    }

    /// Basis for the list recommendation (architecture guide): with one Store per row
    /// (`store.scope(state: \.rows, action: \.rows)`), changing a row only notifies
    /// that row's Store; the other rows do not redraw.
    @Test
    func forEachScopedStoresNotifyOnlyTheChangedRow() {
        let store = Store(initialState: ParentFeature.State(rows: [.init(id: 1), .init(id: 2)])) {
            ParentFeature()
        }
        let rows = store.scope(state: \.rows, action: \.rows)
        var parentChanges = 0, firstRowChanges = 0, secondRowChanges = 0
        let cancellables = [
            store.objectWillChange.sink { parentChanges += 1 },
            rows[0].objectWillChange.sink { firstRowChanges += 1 },
            rows[1].objectWillChange.sink { secondRowChanges += 1 },
        ]

        rows[0].send(.toggle)

        #expect(rows[0].isOn == true)
        #expect(firstRowChanges == 1)
        #expect(secondRowChanges == 0)
        #expect(parentChanges == 1) // the parent Store changes (the array changed): the parent View must be light
        _ = cancellables
    }
}

@MainActor
@Suite("Bindings, Dependencies, Shared, CasePaths", .serialized)
struct IntegrationFeaturesTests {
    @Test
    func bindingReducerAndPatternMatching() async {
        let store = TestStore(initialState: FormFeature.State()) {
            FormFeature()
        }

        await store.send(.binding(.set(\.email, "a@b"))) {
            $0.email = "a@b"
            $0.isValid = true
        }
        await store.send(.set(\.acceptsTerms, true)) { $0.acceptsTerms = true }
    }

    @Test
    func dependencyOverridesWithWithDependencies() async throws {
        let fact = try await withDependencies {
            $0.numberFact.fetch = { "\($0)!" }
        } operation: {
            @Dependency(\.numberFact) var numberFact
            return try await numberFact.fetch(7)
        }
        #expect(fact == "7!")
    }

    @Test
    func builtInDependenciesHaveDeterministicTestValues() {
        let values = DependencyValues(context: .test)
        #expect(values.uuid().uuidString == "00000000-0000-0000-0000-000000000000")
        #expect(values.date.now == Date(timeIntervalSince1970: 1_234_567_890))
    }

    @Test
    func sharedStateIsSharedBetweenStores() {
        let first = Store(initialState: SharedCounterFeature.State()) { SharedCounterFeature() }
        let second = Store(initialState: SharedCounterFeature.State()) { SharedCounterFeature() }
        let initial = first.count

        first.send(.increment)
        second.send(.increment)

        #expect(first.count == initial + 2)
        #expect(second.count == initial + 2)
    }

    @Test
    func casePathsGeneratedByMacro() {
        let action = CounterFeature.Action.factResponse("x")
        #expect(action[case: \.factResponse] == "x")
        #expect(action.is(\.factResponse))
        #expect(!action.is(\.increment))
        #expect(CounterFeature.Action.allCasePaths.increment.embed(()) == .increment)

        let rowAction = ParentFeature.Action.addRow(id: 3)
        #expect(rowAction[case: \.addRow] == 3)
    }
}
