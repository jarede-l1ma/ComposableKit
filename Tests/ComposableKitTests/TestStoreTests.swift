import Foundation
import ComposableKit
import Testing

/// Reducer used to exercise the TestStore.
private func logReducer(clock: TestClock? = nil) -> Reduce<Log, Act> {
    Reduce { state, action in
        switch action {
        case .start:
            state.entries.append("start")
            return .run { send in await send(.append("effect")) }
        case .stop:
            return .none
        case let .append(value):
            state.entries.append(value)
            return .none
        case let .value(seconds):
            return .run { send in
                try await (clock ?? TestClock()).sleep(for: Double(seconds))
                await send(.append("after \(seconds)s"))
            }
        }
    }
}

@MainActor
@Suite("TestStore")
struct TestStoreTests {

    // MARK: Caminho feliz

    @Test
    func sendWithoutClosureWhenStateDoesNotChange() async {
        let store = TestStore(initialState: Log()) { logReducer() }
        await store.send(.stop)
    }

    @Test
    func receiveByEquatableCaseAndValue() async {
        let store = TestStore(initialState: Log()) { logReducer() }
        await store.send(.start) { $0.entries = ["start"] }
        await store.receive(\.append, "effect") { $0.entries = ["start", "effect"] }

        await store.send(.start) { $0.entries = ["start", "effect", "start"] }
        await store.receive(\.append) { $0.entries.append("effect") }

        await store.send(.start) { $0.entries.append("start") }
        await store.receive(.append("effect")) { $0.entries.append("effect") }
    }

    @Test
    func stateIsReadableAfterSend() async {
        let store = TestStore(initialState: Log()) { logReducer() }
        await store.send(.append("x")) { $0.entries = ["x"] }
        #expect(store.state.entries == ["x"])
    }

    @Test
    func testStoreTaskFinishWaitsAndCancelStops() async {
        let clock = TestClock()
        let store = TestStore(initialState: Log()) { logReducer(clock: clock) }

        let task = await store.send(.value(1))
        await clock.advance(by: 1)
        await task.finish()
        await store.receive(.append("after 1s")) { $0.entries = ["after 1s"] }

        let cancellable = await store.send(.value(5))
        await cancellable.cancel()
        #expect(cancellable.isCancelled)
        await store.finish()
    }

    @Test
    func skipReceivedActionsAndSkipInFlightEffects() async {
        let clock = TestClock()
        let store = TestStore(initialState: Log()) { logReducer(clock: clock) }

        await store.send(.start) { $0.entries = ["start"] }
        await store.skipReceivedActions()
        #expect(store.state.entries == ["start", "effect"])

        await store.send(.value(10))
        await store.skipInFlightEffects()
    }

    @Test
    func nonExhaustiveReceiveSkipsUnrelatedActions() async {
        let store = TestStore(initialState: Log()) {
            Reduce<Log, Act> { state, action in
                switch action {
                case .start:
                    return .merge(.send(.append("a")), .send(.append("b")), .send(.append("c")))
                case let .append(value):
                    state.entries.append(value)
                    return .none
                default:
                    return .none
                }
            }
        }
        store.exhaustivity = .off

        await store.send(.start)
        await store.receive(.append("c")) { $0.entries = ["a", "b", "c"] }
    }

    @Test
    func nonExhaustiveSendOnlyChecksDeclaredFields() async {
        let store = TestStore(initialState: CounterFeature.State()) { CounterFeature() }.nonExhaustive()
        await store.send(.increment)
        await store.send(.increment) { $0.count = 2 }
    }

    // MARK: Failures the TestStore must detect

    @Test
    func failsWhenStateDiffers() async {
        await withKnownIssue {
            let store = TestStore(initialState: Log()) { logReducer() }
            await store.send(.append("x")) { $0.entries = ["y"] }
        } matching: { issue($0, contains: "is not the expected one") && issue($0, contains: "−") }
    }

    @Test
    func failsWhenClosureGivenButStateUnchanged() async {
        await withKnownIssue {
            let store = TestStore(initialState: Log()) { logReducer() }
            await store.send(.stop) { _ in }
        } matching: { issue($0, contains: "the state did not change") }
    }

    @Test
    func failsWhenReceivedActionDiffers() async {
        await withKnownIssue {
            let store = TestStore(initialState: Log()) { logReducer() }
            await store.send(.start) { $0.entries = ["start"] }
            await store.receive(.append("other"))
        } matching: { issue($0, contains: "Received Action differs") }
    }

    @Test
    func failsWhenNothingIsReceived() async {
        await withKnownIssue {
            let store = TestStore(initialState: Log()) { logReducer() }
            await store.receive(.append("never"))
        } matching: { issue($0, contains: "no matching Action") }
    }

    @Test
    func failsWhenReceiveTimesOut() async {
        await withKnownIssue {
            let clock = TestClock()
            let store = TestStore(initialState: Log()) { logReducer(clock: clock) }
            store.timeout = 0.05
            await store.send(.value(1))
            await store.receive(\.append)
            await store.skipInFlightEffects()
        } matching: { issue($0, contains: "no matching Action") }
    }

    @Test
    func failsWhenSendingWithUnreceivedActions() async {
        await withKnownIssue {
            let store = TestStore(initialState: Log()) { logReducer() }
            await store.send(.start) { $0.entries = ["start"] }
            await store.finish() // ensures the effect has already delivered the Action
            await store.send(.stop)
        } matching: { issue($0, contains: "not checked before sending") }
    }

    @Test
    func failsWhenTestEndsWithUnreceivedActions() async {
        await withKnownIssue {
            let store = TestStore(initialState: Log()) { logReducer() }
            await store.send(.start) { $0.entries = ["start"] }
            await store.finish()
        } matching: { issue($0, contains: "finished with 1 received Action(s)") }
    }

    @Test
    func failsWhenTestEndsWithEffectsInFlight() async {
        await withKnownIssue {
            let clock = TestClock()
            let store = TestStore(initialState: Log()) { logReducer(clock: clock) }
            await store.send(.value(10))
        } matching: { issue($0, contains: "effect(s) still in flight") }
    }

    @Test
    func failsWhenFinishTimesOut() async {
        await withKnownIssue {
            let clock = TestClock()
            let store = TestStore(initialState: Log()) { logReducer(clock: clock) }
            await store.send(.value(10))
            await store.finish(timeout: 0.05)
            await store.skipInFlightEffects()
        } matching: { issue($0, contains: "Expected the effects to finish") }
    }

    @Test
    func failsWhenTaskFinishTimesOut() async {
        await withKnownIssue {
            let clock = TestClock()
            let store = TestStore(initialState: Log()) { logReducer(clock: clock) }
            let task = await store.send(.value(10))
            await task.finish(timeout: 0.05)
            await store.skipInFlightEffects()
        } matching: { issue($0, contains: "did not finish") }
    }

    @Test
    func failsWhenAssertionClosureThrows() async {
        struct Oops: Error {}
        await withKnownIssue {
            let store = TestStore(initialState: Log()) { logReducer() }
            await store.send(.append("x")) { _ in throw Oops() }
        } matching: { issue($0, contains: "threw an error") }
    }

    @Test
    func failsWhenDependencyIsNotOverridden() async {
        await withKnownIssue {
            let store = TestStore(initialState: CounterFeature.State()) { CounterFeature() }
            await store.send(.factButtonTapped) { $0.isLoading = true }
            await store.skipReceivedActions()
            await store.finish()
        } matching: { issue($0, contains: "NumberFactClient.fetch") }
    }
}

@Suite("TestStore · default timeout")
struct TestStoreDefaultTimeoutTests {
    @Test
    func defaultTimeoutIsOneSecond() {
        #expect(TestStoreDefaults.timeout(environment: [:]) == 1)
    }

    @Test
    func environmentOverridesDefaultTimeout() {
        #expect(TestStoreDefaults.timeout(environment: ["COMPOSABLEKIT_TEST_TIMEOUT": "5"]) == 5)
        #expect(TestStoreDefaults.timeout(environment: ["COMPOSABLEKIT_TEST_TIMEOUT": "2.5"]) == 2.5)
    }

    @Test(arguments: ["", "abc", "0", "-3"])
    func invalidEnvironmentValueFallsBackToOneSecond(_ raw: String) {
        #expect(TestStoreDefaults.timeout(environment: ["COMPOSABLEKIT_TEST_TIMEOUT": raw]) == 1)
    }

    @MainActor
    @Test
    func testStoreUsesTheDefaultTimeout() {
        let store = TestStore(initialState: CounterFeature.State()) { CounterFeature() }
        #expect(store.timeout == TestStoreDefaults.timeout)
    }
}

/// Drops the last reference off the main thread (a `nonisolated async` function:
/// in the package's Swift 6 mode it runs on the global executor, in the same Task).
private nonisolated func releaseOffMain<T: AnyObject>(_ box: LockIsolated<T?>) async -> Bool {
    box.setValue(nil)
    return isOnMainThread()
}

private nonisolated func isOnMainThread() -> Bool { Thread.isMainThread }

@MainActor
@Suite("TestStore · released off the main thread")
struct TestStoreReleasedOffMainTests {
    /// Regression: `deinit` used `MainActor.assumeIsolated`, which crashes the
    /// whole test process if the TestStore is released off the main thread.
    @Test
    func releasingOffMainReportsIssueInsteadOfCrashing() async {
        let box = LockIsolated<TestStore<Log, Act>?>(
            TestStore(initialState: Log()) { Reduce { _, _ in .none } }
        )
        await withKnownIssue {
            let ranOnMain = await releaseOffMain(box)
            #expect(ranOnMain == false) // ensures the scenario happened
        } matching: { issue($0, contains: "off the main thread") }
    }
}
