import Foundation
import ComposableKit
import Testing

/// Simulates a real client: a few executor hops (e.g. an actor) before the `sleep`.
private actor Hop {
    func touch() {}
}

@MainActor
@Suite("TestStore · determinism")
struct DeterminismTests {
    /// Guards against the "advance before sleep" race: if the test's `clock.advance`
    /// runs before the effect reaches its `sleep`, the advance is lost and the
    /// response never arrives. Today the `megaYield` in `send`/`advance` covers 300
    /// executor hops (also verified with a saturated CPU); this test fails if a
    /// change to TestStore/TestClock reintroduces the race.
    @Test(arguments: 1...20)
    func advanceAfterEffectWithExecutorHopsDeliversResponse(_ run: Int) async {
        let clock = TestClock()
        let hop = Hop()
        let store = TestStore(initialState: Log()) {
            Reduce<Log, Act> { state, action in
                switch action {
                case .start:
                    return .run { send in
                        for _ in 0..<300 { await hop.touch() }
                        try await clock.sleep(for: 1)
                        await send(.append("ok"))
                    }
                case let .append(value):
                    state.entries.append(value)
                    return .none
                default:
                    return .none
                }
            }
        }

        await store.send(.start)
        await clock.advance(by: 1)
        await store.receive(.append("ok")) { $0.entries = ["ok"] }
    }

    /// Regression for the "advance before sleep" race (reproduced with the Thread
    /// Sanitizer: 11 of 15 suite runs failed in `concatenateWaitsForEachEffect`).
    /// Here the delay is forced: the effect takes ~20 real ms to reach its `sleep`
    /// (the only `Task.sleep` allowed in tests: it simulates a slow machine).
    @Test
    func advanceWaitsForASleepThatRegistersLate() async {
        let clock = TestClock()
        let store = TestStore(initialState: Log()) {
            Reduce<Log, Act> { state, action in
                switch action {
                case .start:
                    return .run { send in
                        try await Task.sleep(nanoseconds: 20_000_000)
                        try await clock.sleep(for: 1)
                        await send(.append("ok"))
                    }
                case let .append(value):
                    state.entries.append(value)
                    return .none
                default:
                    return .none
                }
            }
        }

        await store.send(.start)
        await clock.advance(by: 1)
        await store.receive(.append("ok")) { $0.entries = ["ok"] }
    }
}
