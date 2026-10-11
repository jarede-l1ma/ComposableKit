import Foundation
import ComposableKit

// Features used by the package tests. They also serve as syntax examples.

// MARK: - Example dependency

struct NumberFactClient: Sendable {
    var fetch: @Sendable (Int) async throws -> String
}

extension NumberFactClient: DependencyKey {
    static let liveValue = NumberFactClient { "\($0) is a number" }
    static let testValue = NumberFactClient { _ in throw UnimplementedError("NumberFactClient.fetch") }
}

extension DependencyValues {
    var numberFact: NumberFactClient {
        get { self[NumberFactClient.self] }
        set { self[NumberFactClient.self] = newValue }
    }
}

// MARK: - Counter (effects, cancellation, dependencies)

@Reducer
struct CounterFeature {
    @ObservableState
    struct State: Equatable {
        var count = 0
        var fact: String?
        var isLoading = false
    }

    enum Action: Equatable {
        case increment
        case decrement
        case factButtonTapped
        case factResponse(String)
        case factFailed(String)
        case cancelTapped
    }

    enum CancelID { case fact }

    @Dependency(\.numberFact) var numberFact

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .increment:
                state.count += 1
                return .none

            case .decrement:
                state.count -= 1
                return .none

            case .factButtonTapped:
                state.isLoading = true
                return .run { [count = state.count, numberFact] send in
                    let fact = try await numberFact.fetch(count)
                    await send(.factResponse(fact))
                } catch: { error, send in
                    await send(.factFailed("\(error)"))
                }
                .cancellable(id: CancelID.fact, cancelInFlight: true)

            case let .factResponse(fact):
                state.isLoading = false
                state.fact = fact
                return .none

            case let .factFailed(message):
                state.isLoading = false
                state.fact = message
                return .none

            case .cancelTapped:
                state.isLoading = false
                return .cancel(id: CancelID.fact)
            }
        }
    }
}

// MARK: - Row (forEach)

@Reducer
struct RowFeature {
    @ObservableState
    struct State: Equatable, Identifiable {
        let id: Int
        var isOn = false
        var ticks = 0
        var loaded: Int?
    }

    enum Action: Equatable {
        case toggle
        case startTimer
        case tick
        case load
        case loaded(Int)
    }

    /// Same id on every row: `forEach` isolates the ids per element.
    enum CancelID { case load }

    @Dependency(\.continuousClock) var clock

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .toggle:
                state.isOn.toggle()
                return .none
            case .startTimer:
                return .run { [clock] send in
                    while true {
                        try await clock.sleep(for: 1)
                        await send(.tick)
                    }
                }
            case .tick:
                state.ticks += 1
                return .none
            case .load:
                // Each row waits `id` seconds (deterministic order in tests).
                return .run { [clock, id = state.id] send in
                    try await clock.sleep(for: Double(id))
                    await send(.loaded(id))
                }
                .cancellable(id: CancelID.load, cancelInFlight: true)
            case let .loaded(value):
                state.loaded = value
                return .none
            }
        }
    }
}

// MARK: - Parent (Scope, ifLet, forEach)

@Reducer
struct ParentFeature {
    @ObservableState
    struct State: Equatable {
        var counter = CounterFeature.State()
        var detail: CounterFeature.State?
        var rows: IdentifiedArrayOf<RowFeature.State> = []
    }

    enum Action: Equatable {
        case counter(CounterFeature.Action)
        case detail(CounterFeature.Action)
        case rows(IdentifiedActionOf<RowFeature>)
        case showDetail
        case hideDetail
        case addRow(id: Int)
        case removeRow(id: Int)
    }

    var body: some ReducerOf<Self> {
        Scope(state: \.counter, action: \.counter) {
            CounterFeature()
        }
        Reduce { state, action in
            switch action {
            case .showDetail:
                state.detail = CounterFeature.State()
                return .none
            case .hideDetail:
                state.detail = nil
                return .none
            case let .addRow(id):
                state.rows.append(RowFeature.State(id: id))
                return .none
            case let .removeRow(id):
                state.rows.remove(id: id)
                return .none
            case .counter, .detail, .rows:
                return .none
            }
        }
        .ifLet(\.detail, action: \.detail) {
            CounterFeature()
        }
        .forEach(\.rows, action: \.rows) {
            RowFeature()
        }
    }
}

// MARK: - Form (bindings)

@Reducer
struct FormFeature {
    @ObservableState
    struct State: Equatable {
        var email = ""
        var acceptsTerms = false
        var isValid = false
    }

    enum Action: BindableAction, Equatable {
        case binding(BindingAction<State>)
        case submit
    }

    var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding(\.email):
                state.isValid = state.email.contains("@")
                return .none
            case .binding:
                return .none
            case .submit:
                return .none
            }
        }
    }
}

// MARK: - Search (debounce + clock)

@Reducer
struct SearchFeature {
    @ObservableState
    struct State: Equatable {
        var query = ""
        var results: [String] = []
    }

    enum Action: Equatable {
        case queryChanged(String)
        case didSearch([String])
    }

    enum CancelID { case search }

    @Dependency(\.continuousClock) var clock

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case let .queryChanged(query):
                state.query = query
                return .run { send in
                    await send(.didSearch([query.uppercased()]))
                }
                .debounce(id: CancelID.search, for: 0.3, clock: clock)
            case let .didSearch(results):
                state.results = results
                return .none
            }
        }
    }
}

// MARK: - Shared

@Reducer
struct SharedCounterFeature {
    @ObservableState
    struct State: Equatable {
        @Shared(.inMemory("tests.sharedCount")) var count = 0
    }

    enum Action {
        case increment
    }

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .increment:
                state.$count.withLock { $0 += 1 }
                return .none
            }
        }
    }
}

// MARK: - Effect sequence

@Reducer
struct SequenceFeature {
    struct State: Equatable {
        var log: [String] = []
    }

    enum Action: Equatable {
        case start
        case append(String)
    }

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .start:
                return .concatenate(
                    .run { send in await send(.append("a")) },
                    .send(.append("b")),
                    .run { send in await send(.append("c")) }
                )
            case let .append(value):
                state.log.append(value)
                return .none
            }
        }
    }
}
