import Foundation
import ComposableKit
import Testing

// MARK: - Test keys

private enum LiveOnlyKey: DependencyKey {
    // With only `liveValue`, Swift does not infer `Value` (it falls back to `Self`).
    typealias Value = String
    static let liveValue = "live"
}

private enum FullKey: DependencyKey {
    static let liveValue = "live"
    static let testValue = "test"
    static let previewValue = "preview"
}

private enum TestOnlyKey: TestDependencyKey {
    static let testValue = "test-only"
}

private extension DependencyValues {
    var liveOnly: String { self[LiveOnlyKey.self] }
    var full: String {
        get { self[FullKey.self] }
        set { self[FullKey.self] = newValue }
    }
    var testOnly: String { self[TestOnlyKey.self] }
}

// MARK: - Feature that reads dependencies in the reducer and in the effect

@Reducer
private struct DependencyReader {
    struct State: Equatable {
        var fromReducer = ""
        var fromEffect = ""
    }

    enum Action: Equatable {
        case read
        case effectRead(String)
    }

    @Dependency(\.full) var full
    @Dependency(\.uuid) var uuid

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .read:
                state.fromReducer = full
                return .run { send in
                    @Dependency(\.full) var fullInEffect
                    await send(.effectRead(fullInEffect))
                }
            case let .effectRead(value):
                state.fromEffect = value
                return .none
            }
        }
    }
}

@Suite("Dependencies")
struct DependencyTests {
    @Test
    func contextSelectsValue() {
        #expect(DependencyValues(context: .live).full == "live")
        #expect(DependencyValues(context: .test).full == "test")
        #expect(DependencyValues(context: .preview).full == "preview")
    }

    @Test
    func previewDefaultsToLiveForDependencyKey() {
        #expect(DependencyValues(context: .preview).liveOnly == "live")
    }

    @Test
    func previewDefaultsToTestForTestDependencyKey() {
        #expect(DependencyValues(context: .preview).testOnly == "test-only")
    }

    @Test
    func testOnlyKeyInLiveContextReportsIssue() {
        withKnownIssue {
            #expect(DependencyValues(context: .live).testOnly == "test-only")
        } matching: { issue($0, contains: "has no \"liveValue\"") }
    }

    @Test
    func liveOnlyKeyInTestContextReportsIssueAndReturnsLive() {
        withKnownIssue {
            #expect(DependencyValues(context: .test).liveOnly == "live")
        } matching: { issue($0, contains: "without a test value") }
    }

    @Test
    func overrideWinsOverContext() {
        var values = DependencyValues(context: .live)
        values.full = "override"
        #expect(values.full == "override")
    }

    @Test
    func defaultContextInTestsIsTest() {
        #expect(DependencyValues().context == .test)
        #expect(DependencyValues._current.context == .test)
    }

    @Test
    func withDependenciesNestsAndRestores() {
        @Dependency(\.full) var full
        #expect(full == "test")
        withDependencies {
            $0.full = "outer"
        } operation: {
            #expect(full == "outer")
            withDependencies {
                $0.full = "inner"
            } operation: {
                #expect(full == "inner")
            }
            #expect(full == "outer")
        }
        #expect(full == "test")
    }

    @Test
    func withDependenciesAsync() async {
        let value = await withDependencies {
            $0.full = "async"
        } operation: { () async -> String in
            await Task.yield()
            @Dependency(\.full) var full
            return full
        }
        #expect(value == "async")
    }

    @MainActor
    @Test
    func storeDependenciesReachReducerAndEffects() async {
        let store = TestStore(initialState: DependencyReader.State()) {
            DependencyReader()
        } withDependencies: {
            $0.full = "store"
        }

        await store.send(.read) { $0.fromReducer = "store" }
        await store.receive(.effectRead("store")) { $0.fromEffect = "store" }
    }

    @MainActor
    @Test
    func testStoreDependenciesCanChangeBetweenSends() async {
        let store = TestStore(initialState: DependencyReader.State()) {
            DependencyReader()
        } withDependencies: {
            $0.full = "a"
        }
        await store.send(.read) { $0.fromReducer = "a" }
        await store.receive(.effectRead("a")) { $0.fromEffect = "a" }

        store.dependencies.full = "b"
        await store.send(.read) { $0.fromReducer = "b" }
        await store.receive(.effectRead("b")) { $0.fromEffect = "b" }
    }

    @Test
    func unimplementedErrorReportsIssue() {
        withKnownIssue {
            let error = UnimplementedError("Client.endpoint")
            #expect(error.description.contains("Client.endpoint"))
        } matching: { issue($0, contains: "Client.endpoint") }
    }

    // MARK: Built-in dependencies

    @Test
    func uuidIncrementing() {
        let uuid = UUIDGenerator.incrementing
        #expect(uuid().uuidString == "00000000-0000-0000-0000-000000000000")
        #expect(uuid().uuidString == "00000000-0000-0000-0000-000000000001")
        #expect(uuid().uuidString == "00000000-0000-0000-0000-000000000002")
    }

    /// Regression: the counter was global to the process; the second TestStore
    /// started at ...0001 and the result depended on test order.
    @Test
    func uuidTestValueStartsAtZeroForEachDependencyValues() {
        let first = DependencyValues(context: .test)
        let second = DependencyValues(context: .test)
        #expect(first.uuid().uuidString == "00000000-0000-0000-0000-000000000000")
        #expect(second.uuid().uuidString == "00000000-0000-0000-0000-000000000000")
    }

    @Test
    func uuidTestValueIsSharedBetweenCopies() {
        let values = DependencyValues(context: .test)
        let copy = values // e.g. the DependencyValues captured by an effect
        #expect(values.uuid().uuidString == "00000000-0000-0000-0000-000000000000")
        #expect(copy.uuid().uuidString == "00000000-0000-0000-0000-000000000001")
    }

    @Test
    func uuidLiveIsRandom() {
        let uuid = DependencyValues(context: .live).uuid
        #expect(uuid() != uuid())
    }

    @Test
    func dateConstantAndTestValue() {
        let date = Date(timeIntervalSince1970: 10)
        #expect(DateGenerator.constant(date).now == date)
        #expect(DependencyValues(context: .test).date.now == Date(timeIntervalSince1970: 1_234_567_890))
    }

    @Test
    func immediateClockDoesNotWaitButHonorsCancellation() async throws {
        let start = Date()
        try await ImmediateClock().sleep(for: 60)
        #expect(Date().timeIntervalSince(start) < 1)

        let task = Task {
            try await ImmediateClock().sleep(for: 1)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test
    func liveClockSleeps() async throws {
        let start = Date()
        try await LiveEffectClock().sleep(for: 0.05)
        #expect(Date().timeIntervalSince(start) >= 0.04)
    }

    @Test
    func clockTestValueIsImmediate() {
        #expect(DependencyValues(context: .test).continuousClock is ImmediateClock)
        #expect(DependencyValues(context: .live).continuousClock is LiveEffectClock)
    }
}
