import Foundation
@testable import ComposableKit
import Testing

@MainActor
@Suite("Effect")
struct EffectTests {

    private func store(
        _ reduce: @escaping (inout Log, Act) -> Effect<Act>,
        dependencies: @escaping (inout DependencyValues) -> Void = { _ in }
    ) -> TestStore<Log, Act> {
        TestStore(
            initialState: Log(),
            reducer: { Reduce(reduce) },
            withDependencies: dependencies
        )
    }

    // MARK: none / send

    @Test
    func noneProducesNoAction() async {
        let store = store { _, _ in .none }
        await store.send(.start)
        await store.finish()
    }

    @Test
    func sendDispatchesSynchronouslyAfterTheCurrentAction() async {
        let store = store { state, action in
            switch action {
            case .start: return .send(.append("a"))
            case let .append(value): state.entries.append(value); return .none
            default: return .none
            }
        }

        await store.send(.start)
        await store.receive(.append("a")) { $0.entries = ["a"] }
    }

    @Test
    func chainedSendsAreProcessedInFIFOOrder() async {
        let store = store { state, action in
            switch action {
            case .start:
                return .merge(.send(.append("b")), .send(.append("c")))
            case let .append(value):
                state.entries.append(value)
                return value == "b" ? .send(.append("d")) : .none
            default:
                return .none
            }
        }

        await store.send(.start)
        await store.receive(.append("b")) { $0.entries = ["b"] }
        await store.receive(.append("c")) { $0.entries = ["b", "c"] }
        await store.receive(.append("d")) { $0.entries = ["b", "c", "d"] }
    }

    // MARK: run

    @Test
    func runCanSendMultipleActions() async {
        let store = store { state, action in
            switch action {
            case .start:
                return .run { send in
                    await send(.append("1"))
                    await send(.append("2"))
                }
            case let .append(value): state.entries.append(value); return .none
            default: return .none
            }
        }

        await store.send(.start)
        await store.receive(.append("1")) { $0.entries = ["1"] }
        await store.receive(.append("2")) { $0.entries = ["1", "2"] }
    }

    @Test
    func runWithoutCatchReportsUnhandledError() async {
        struct Boom: Error {}
        await withKnownIssue {
            let store = store { _, action in
                action == .start ? .run { _ in throw Boom() } : .none
            }
            await store.send(.start)
            await store.finish()
        } matching: { issue($0, contains: "unhandled error") }
    }

    @Test
    func runIgnoresCancellationError() async {
        let store = store { _, action in
            action == .start ? .run { _ in throw CancellationError() } : .none
        }
        await store.send(.start)
        await store.finish()
    }

    @Test
    func actionsSentAfterCancellationAreDropped() async {
        let clock = TestClock()
        let store = store { _, action in
            switch action {
            case .start:
                return .run { send in
                    try? await clock.sleep(for: 1) // swallows the cancellation
                    await send(.append("late"))
                }
                .cancellable(id: "x")
            case .stop:
                return .cancel(id: "x")
            default:
                return .none
            }
        }

        await store.send(.start)
        await store.send(.stop)
        await clock.advance(by: 1)
        await store.finish()
    }

    // MARK: merge / concatenate

    @Test
    func mergeRunsInParallel() async {
        let clock = TestClock()
        let store = store { state, action in
            switch action {
            case .start:
                return .merge(
                    .run { send in try await clock.sleep(for: 2); await send(.append("slow")) },
                    .run { send in try await clock.sleep(for: 1); await send(.append("fast")) }
                )
            case let .append(value): state.entries.append(value); return .none
            default: return .none
            }
        }

        await store.send(.start)
        await clock.advance(by: 1)
        await store.receive(.append("fast")) { $0.entries = ["fast"] }
        await clock.advance(by: 1)
        await store.receive(.append("slow")) { $0.entries = ["fast", "slow"] }
    }

    @Test
    func sendWithAnimationDeliversTheAction() async {
        let store = store { state, action in
            switch action {
            case .start:
                return .run { send in await send(.append("animated"), animation: .default) }
            case let .append(value): state.entries.append(value); return .none
            default: return .none
            }
        }

        await store.send(.start)
        await store.receive(.append("animated")) { $0.entries = ["animated"] }
    }

    @Test
    func sendWithAnimationAfterCancellationIsDropped() async {
        let clock = TestClock()
        let store = store { state, action in
            switch action {
            case .start:
                return .run { send in
                    try await clock.sleep(for: 1)
                    await send(.append("late"), animation: .default)
                }
                .cancellable(id: "anim")
            case .stop: return .cancel(id: "anim")
            case let .append(value): state.entries.append(value); return .none
            default: return .none
            }
        }

        await store.send(.start)
        await store.send(.stop)
        await clock.advance(by: 1)
        await store.finish() // no receive: the animated Action does not arrive after cancellation
    }

    @Test
    func concatenateWaitsForEachEffect() async {
        let clock = TestClock()
        let store = store { state, action in
            switch action {
            case .start:
                return .concatenate(
                    .run { send in try await clock.sleep(for: 2); await send(.append("first")) },
                    .run { send in await send(.append("second")) }
                )
            case let .append(value): state.entries.append(value); return .none
            default: return .none
            }
        }

        await store.send(.start)
        await clock.advance(by: 2)
        await store.receive(.append("first")) { $0.entries = ["first"] }
        await store.receive(.append("second")) { $0.entries = ["first", "second"] }
    }

    @Test
    func cancellingConcatenateStopsRemainingEffects() async {
        let clock = TestClock()
        let store = store { _, action in
            switch action {
            case .start:
                return .concatenate(
                    .run { _ in try await clock.sleep(for: 1) },
                    .run { send in await send(.append("must not arrive")) }
                )
                .cancellable(id: "seq")
            case .stop:
                return .cancel(id: "seq")
            default:
                return .none
            }
        }

        await store.send(.start)
        await store.send(.stop)
        await clock.advance(by: 1)
        await store.finish()
    }

    @Test
    func mergeAndConcatenateDropNoneEffects() {
        #expect(Effect<Act>.merge(.none, .none).isNone)
        #expect(Effect<Act>.concatenate([]).isNone)
        #expect(Effect<Act>.merge(.none, .send(.start)).isSend)
        #expect(Effect<Act>.none.merge(with: .none).isNone)
        #expect(Effect<Act>.none.concatenate(with: .none).isNone)
    }

    // MARK: cancellable / cancel

    @Test
    func cancelInFlightFalseKeepsBothEffects() async {
        let clock = TestClock()
        let store = store { state, action in
            switch action {
            case let .value(n):
                return .run { send in try await clock.sleep(for: 1); await send(.append("\(n)")) }
                    .cancellable(id: "id")
            case let .append(value): state.entries.append(value); return .none
            default: return .none
            }
        }

        await store.send(.value(1))
        await store.send(.value(2))
        await clock.advance(by: 1)
        await store.receive(.append("1")) { $0.entries = ["1"] }
        await store.receive(.append("2")) { $0.entries = ["1", "2"] }
    }

    @Test
    func cancelUnknownIdIsNoOp() async {
        let store = store { _, _ in .cancel(id: "nothing") }
        await store.send(.stop)
    }

    @Test
    func cancellableNoneIsNone() {
        #expect(Effect<Act>.none.cancellable(id: "x").isNone)
        #expect(!Effect<Act>.none.cancellable(id: "x", cancelInFlight: true).isNone)
    }

    @Test
    func cancelledIdCanBeReused() async {
        let clock = TestClock()
        let store = store { state, action in
            switch action {
            case .start:
                return .run { send in try await clock.sleep(for: 1); await send(.append("ok")) }
                    .cancellable(id: "id")
            case .stop:
                return .cancel(id: "id")
            case let .append(value): state.entries.append(value); return .none
            default: return .none
            }
        }

        await store.send(.start)
        await store.send(.stop)
        await store.send(.start)
        await clock.advance(by: 1)
        await store.receive(.append("ok")) { $0.entries = ["ok"] }
    }

    // MARK: debounce

    @Test
    func debounceOnlyRunsLastEffect() async {
        let clock = TestClock()
        let store = store { state, action in
            switch action {
            case let .value(n):
                return .send(.append("\(n)")).debounce(id: "d", for: 0.5, clock: clock)
            case let .append(value): state.entries.append(value); return .none
            default: return .none
            }
        }

        await store.send(.value(1))
        await clock.advance(by: 0.4)
        await store.send(.value(2))
        await clock.advance(by: 0.4)
        await store.send(.value(3))
        await clock.advance(by: 0.5)
        await store.receive(.append("3")) { $0.entries = ["3"] }
    }

    @Test
    func debounceOfNoneIsNone() {
        #expect(Effect<Act>.none.debounce(id: "d", for: 1, clock: ImmediateClock()).isNone)
    }

    // MARK: map

    @Test
    func mapTransformsActionsOfEveryOperation() async {
        enum Parent: Equatable, Sendable { case child(Act) }
        let clock = TestClock()
        let store = TestStore(initialState: Log()) {
            Reduce<Log, Parent> { state, action in
                switch action {
                case .child(.start):
                    let child: Effect<Act> = .merge(
                        .send(.append("send")),
                        .run { send in await send(.append("run")) },
                        .concatenate(.run { send in try await clock.sleep(for: 1); await send(.append("seq")) }),
                        .run { _ in try await clock.sleep(for: 10) }.cancellable(id: "c"),
                        .cancel(id: "c")
                    )
                    return child.map(Parent.child)
                case let .child(.append(value)):
                    state.entries.append(value)
                    return .none
                case .child:
                    return .none
                }
            }
        }

        await store.send(.child(.start))
        await store.receive(.child(.append("send"))) { $0.entries = ["send"] }
        await store.receive(.child(.append("run"))) { $0.entries = ["send", "run"] }
        await clock.advance(by: 1)
        await store.receive(.child(.append("seq"))) { $0.entries = ["send", "run", "seq"] }
        await store.finish()
    }

    // MARK: Send

    @Test
    func runPriorityIsAccepted() async {
        let store = store { state, action in
            switch action {
            case .start:
                return .run(priority: .high) { send in await send(.append("p")) }
            case let .append(value): state.entries.append(value); return .none
            default: return .none
            }
        }
        await store.send(.start)
        await store.receive(.append("p")) { $0.entries = ["p"] }
    }
}
