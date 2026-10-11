import Foundation
import ComposableKit
import Testing

// MARK: - Support features

/// Form: the email changes through the binding (no dedicated Action).
@Reducer
private struct SignUpFeature {
    @ObservableState
    struct State: Equatable {
        var email = ""
        var isValid = false
        var emailChanges = 0
    }

    enum Action: BindableAction, Equatable {
        case binding(BindingAction<State>)
    }

    var body: some ReducerOf<Self> {
        BindingReducer()
            .onChange(of: \.email) { _, newValue in
                Reduce { state, _ in
                    state.isValid = newValue.contains("@")
                    state.emailChanges += 1
                    return .none
                }
            }
    }
}

/// Reads `date` in the reducer and inside `.run`.
@Reducer
private struct DateReaderFeature {
    @ObservableState
    struct State: Equatable {
        var fromReducer: Date?
        var fromEffect: Date?
    }

    enum Action: Equatable {
        case read
        case effectRead(Date)
    }

    @Dependency(\.date) var date

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .read:
                state.fromReducer = date.now
                return .run { send in
                    @Dependency(\.date) var dateInEffect
                    await send(.effectRead(dateInEffect.now))
                }
            case let .effectRead(value):
                state.fromEffect = value
                return .none
            }
        }
    }
}

private let overriddenDate = Date(timeIntervalSince1970: 1_000)
private let testDate = Date(timeIntervalSince1970: 1_234_567_890) // `date.testValue`

/// Two identical children: only one overrides the dependency.
@Reducer
private struct TwoReadersFeature {
    @ObservableState
    struct State: Equatable {
        var overridden = DateReaderFeature.State()
        var plain = DateReaderFeature.State()
    }

    enum Action: Equatable {
        case overridden(DateReaderFeature.Action)
        case plain(DateReaderFeature.Action)
    }

    var body: some ReducerOf<Self> {
        Scope(state: \.overridden, action: \.overridden) {
            DateReaderFeature()
                .dependency(\.date, .constant(overriddenDate))
        }
        Scope(state: \.plain, action: \.plain) {
            DateReaderFeature()
        }
    }
}

// MARK: - Tests

@MainActor
@Suite("Reducer modifiers")
struct ReducerModifiersTests {

    // _printChanges

    @Test
    func printChangesShowsTheActionAndOnlyTheChangedLines() async {
        let output = LockIsolated<[String]>([])
        let store = TestStore(initialState: Log()) {
            Reduce<Log, Act> { state, action in
                if case let .append(value) = action { state.entries.append(value) }
                return .none
            }
            ._printChanges { text in output.withValue { list in list.append(text) } }
        }

        await store.send(.append("a")) { $0.entries = ["a"] }

        // Only the lines that changed (the type header is left out), without the `dump` marker.
        #expect(output.value == [
            """
            🔹 Action: append("a")
              − entries: 0 elements
              + entries: 1 element
              +   "a"
            """,
        ])
    }

    @Test
    func printChangesSaysWhenTheStateDidNotChange() async {
        let output = LockIsolated<[String]>([])
        let store = TestStore(initialState: Log()) {
            Reduce<Log, Act> { _, _ in .none }
                ._printChanges { text in output.withValue { list in list.append(text) } }
        }

        await store.send(.stop)

        #expect(output.value == ["🔹 Action: stop\n  (no state change)"])
    }

    // onChange

    @Test
    func onChangeRunsWithOldAndNewValuesWhenTheValueChanges() async {
        let seen = LockIsolated<[[Int]]>([])
        let store = TestStore(initialState: Log()) {
            Reduce<Log, Act> { state, action in
                if case let .append(value) = action { state.entries.append(value) }
                return .none
            }
            .onChange(of: \.entries.count) { oldValue, newValue in
                Reduce { _, _ in
                    seen.withValue { list in list.append([oldValue, newValue]) }
                    return .none
                }
            }
        }

        await store.send(.append("a")) { $0.entries = ["a"] }
        await store.send(.stop) // does not change the count

        #expect(seen.value == [[0, 1]])
    }

    @Test
    func onChangeReactsToBindingChangesAndIgnoresTheSameValue() async {
        let store = TestStore(initialState: SignUpFeature.State()) {
            SignUpFeature()
        }

        await store.send(.binding(.set(\.email, "a@b.com"))) {
            $0.email = "a@b.com"
            $0.isValid = true
            $0.emailChanges = 1
        }
        await store.send(.binding(.set(\.email, "a@b.com"))) // same value: does not react
        await store.send(.binding(.set(\.email, "ab"))) {
            $0.email = "ab"
            $0.isValid = false
            $0.emailChanges = 2
        }
    }

    @Test
    func onChangeMergesTheEffectsOfTheReaction() async {
        let store = TestStore(initialState: Log()) {
            Reduce<Log, Act> { state, action in
                switch action {
                case .start:
                    state.entries.append("start")
                    return .none
                case let .append(value):
                    state.entries.append(value)
                    return .none
                default:
                    return .none
                }
            }
            .onChange(of: \.entries.first) { _, _ in
                Reduce { _, _ in .send(.append("reaction")) }
            }
        }

        await store.send(.start) { $0.entries = ["start"] }
        await store.receive(.append("reaction")) { $0.entries = ["start", "reaction"] }
    }

    // dependency

    @Test
    func dependencyOverridesTheValueInTheReducerAndInsideTheEffect() async {
        let store = TestStore(initialState: TwoReadersFeature.State()) {
            TwoReadersFeature()
        }

        await store.send(.overridden(.read)) { $0.overridden.fromReducer = overriddenDate }
        await store.receive(.overridden(.effectRead(overriddenDate))) { $0.overridden.fromEffect = overriddenDate }
    }

    @Test
    func dependencyDoesNotLeakToASiblingFeature() async {
        let store = TestStore(initialState: TwoReadersFeature.State()) {
            TwoReadersFeature()
        }

        await store.send(.plain(.read)) { $0.plain.fromReducer = testDate }
        await store.receive(.plain(.effectRead(testDate))) { $0.plain.fromEffect = testDate }
    }
}
