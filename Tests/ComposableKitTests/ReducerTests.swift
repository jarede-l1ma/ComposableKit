import Foundation
import ComposableKit
import Testing

// MARK: - Test reducers

/// "Leaf" reducer: only implements `reduce(into:action:)` (Body == Never).
struct LeafReducer: Reducer {
    func reduce(into state: inout Log, action: Act) -> Effect<Act> {
        if case let .append(value) = action { state.entries.append("leaf:\(value)") }
        return .none
    }
}

/// Reducer that records the execution order.
struct Tagging: Reducer {
    let tag: String
    func reduce(into state: inout Log, action: Act) -> Effect<Act> {
        if case .start = action { state.entries.append(tag) }
        return .none
    }
}

struct BuilderFeature: Reducer {
    var useFirst: Bool
    var includeOptional: Bool
    var tags: [String]

    var body: some ReducerOf<Self> {
        Tagging(tag: "start")
        if useFirst {
            Tagging(tag: "if")
        } else {
            Tagging(tag: "else")
        }
        if includeOptional {
            Tagging(tag: "optional")
        }
        for tag in tags {
            Tagging(tag: tag)
        }
        CombineReducers {
            Tagging(tag: "combined1")
            Tagging(tag: "combined2")
        }
        EmptyReducer()
        if #available(iOS 15, macOS 13, *) {
            Tagging(tag: "available")
        }
    }

    typealias State = Log
    typealias Action = Act
}

@MainActor
@Suite("Reducer / ReducerBuilder")
struct ReducerTests {
    @Test
    func leafReducerWithoutBody() {
        var state = Log()
        let effect = LeafReducer().reduce(into: &state, action: .append("x"))
        #expect(state.entries == ["leaf:x"])
        _ = effect
    }

    @Test
    func reduceClosureAndReduceWrappingReducer() {
        var state = Log()
        _ = Reduce<Log, Act> { state, _ in state.entries.append("closure"); return .none }
            .reduce(into: &state, action: .start)
        _ = Reduce(LeafReducer()).reduce(into: &state, action: .append("y"))
        #expect(state.entries == ["closure", "leaf:y"])
    }

    @Test
    func builderRunsReducersInDeclarationOrder() {
        var state = Log()
        _ = BuilderFeature(useFirst: true, includeOptional: true, tags: ["for1", "for2"])
            .reduce(into: &state, action: .start)
        #expect(state.entries == ["start", "if", "optional", "for1", "for2", "combined1", "combined2", "available"])
    }

    @Test
    func builderElseAndMissingOptional() {
        var state = Log()
        _ = BuilderFeature(useFirst: false, includeOptional: false, tags: [])
            .reduce(into: &state, action: .start)
        #expect(state.entries == ["start", "else", "combined1", "combined2", "available"])
    }

    @Test
    func emptyReducerDoesNothing() {
        var state = Log(entries: ["x"])
        _ = EmptyReducer<Log, Act>().reduce(into: &state, action: .start)
        #expect(state.entries == ["x"])
    }

    @Test
    func effectsOfAllReducersInBodyAreMerged() async {
        let store = TestStore(initialState: Log()) {
            Reduce<Log, Act> { _, action in action == .start ? .send(.append("a")) : .none }
            Reduce<Log, Act> { _, action in action == .start ? .send(.append("b")) : .none }
            Reduce<Log, Act> { state, action in
                if case let .append(value) = action { state.entries.append(value) }
                return .none
            }
        }

        await store.send(.start)
        await store.receive(.append("a")) { $0.entries = ["a"] }
        await store.receive(.append("b")) { $0.entries = ["a", "b"] }
    }
}
