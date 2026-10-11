import Foundation

// MARK: - TestStore
//
// Exhaustive, deterministic tests, like TCA's `TestStore`:
//
// ```swift
// @MainActor
// @Test func loadsData() async {
//     let store = TestStore(initialState: HomeFeature.State()) {
//         HomeFeature()
//     } withDependencies: {
//         $0.homeClient.fetchData = { .fixture() }
//     }
//
//     await store.send(.viewDidAppear) {
//         $0.isLoading = true
//     }
//     await store.receive(\.didLoad) {
//         $0.isLoading = false
//         $0.viewData = .fixture()
//     }
// }
// ```
//
// Rules (exhaustive mode):
// - Every state change must be declared in the closure.
// - Every Action received from an effect must be checked with `receive`.
// - Every effect must finish by the end of the test.

/// How strict the TestStore is.
public enum Exhaustivity: Equatable, Sendable {
    /// Every state change, received Action and effect must be checked.
    case on
    /// Checks only what the test declares; everything else is ignored.
    case off(showSkippedAssertions: Bool)

    public static let off = Self.off(showSkippedAssertions: false)
}

/// Default TestStore timeout. On a slow CI, raise it with the environment variable
/// `COMPOSABLEKIT_TEST_TIMEOUT` (seconds). With xcodebuild, the `TEST_RUNNER_` prefix
/// forwards it to the test process: `TEST_RUNNER_COMPOSABLEKIT_TEST_TIMEOUT=5 xcodebuild test ...`.
package enum TestStoreDefaults {
    package static let timeout = timeout(environment: ProcessInfo.processInfo.environment)

    package static func timeout(environment: [String: String]) -> Double {
        guard let raw = environment["COMPOSABLEKIT_TEST_TIMEOUT"], let value = Double(raw), value > 0 else {
            return 1
        }
        return value
    }
}

@MainActor
public final class TestStore<State: Equatable, Action> {
    /// Strictness (default `.on`).
    public var exhaustivity: Exhaustivity = .on

    /// Maximum time, in seconds, that `receive` and `finish` wait. Default: 1 s,
    /// or the value of `COMPOSABLEKIT_TEST_TIMEOUT`.
    public var timeout: Double = TestStoreDefaults.timeout

    private let core: RootCore<State, Action>
    private var baseline: State
    private var received: [(action: Action, state: State)] = []
    private var isAwaitingSendResult = false
    private var stateAfterSend: State?
    private let location: (fileID: StaticString, filePath: StaticString, line: UInt, column: UInt)

    /// Creates a TestStore.
    ///
    /// - Parameters:
    ///   - initialState: Initial state.
    ///   - reducer: The feature's reducer.
    ///   - prepareDependencies: Overrides dependencies (test context).
    public init<R: Reducer<State, Action>>(
        initialState: @autoclosure () -> R.State,
        @ReducerBuilder<State, Action> reducer: () -> R,
        withDependencies prepareDependencies: (inout DependencyValues) -> Void = { _ in },
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) {
        var dependencies = DependencyValues(context: .test)
        prepareDependencies(&dependencies)
        let (state, builtReducer) = DependencyValues.$_current.withValue(dependencies) {
            (initialState(), reducer())
        }
        self.core = RootCore(
            initialState: state,
            reducer: { builtReducer.reduce(into: &$0, action: $1) },
            dependencies: dependencies
        )
        self.baseline = state
        self.location = (fileID, filePath, line, column)
        core.onAction = { [weak self] action, state in
            guard let self else { return }
            if self.isAwaitingSendResult {
                self.isAwaitingSendResult = false
                self.stateAfterSend = state
            } else {
                self.received.append((action, state))
            }
        }
    }

    deinit {
        let core = self.core
        let location = self.location
        // `assumeIsolated` off the main thread crashes the whole test process:
        // report and just cancel the effects (on main).
        guard Thread.isMainThread else {
            reportIssue(
                """
                The TestStore was released off the main thread: the end-of-test \
                checks (unchecked Actions, in-flight effects) did not run.

                Keep the TestStore in the scope of a @MainActor test.
                """,
                fileID: location.fileID, filePath: location.filePath, line: location.line, column: location.column
            )
            Task { @MainActor in core.cancelAllEffects() }
            return
        }
        MainActor.assumeIsolated {
            self.completed(core: core, location: location)
        }
    }

    /// Current state.
    public var state: State {
        core.state
    }

    /// Dependencies used by the TestStore (may be changed between `send`s).
    public var dependencies: DependencyValues {
        get { core.dependencies }
        set { core.dependencies = newValue }
    }

    // MARK: send

    /// Sends an Action and checks the state change.
    ///
    /// - Parameter updateStateToExpectedResult: Mutates a copy of the previous
    ///   state into the expected state. Omit it if the Action does not change state.
    @discardableResult
    public func send(
        _ action: Action,
        assert updateStateToExpectedResult: ((_ state: inout State) throws -> Void)? = nil,
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async -> TestStoreTask {
        if !received.isEmpty {
            if exhaustivity == .on {
                reportIssue(
                    """
                    There are \(received.count) received Action(s) not checked before sending \(action):

                    \(received.map { "  • \($0.action)" }.joined(separator: "\n"))

                    Use "await store.receive(...)" for each one, or "store.exhaustivity = .off".
                    """,
                    fileID: fileID, filePath: filePath, line: line, column: column
                )
            }
            if let last = received.last { baseline = last.state }
            received.removeAll()
        }

        isAwaitingSendResult = true
        stateAfterSend = nil
        let task = core.send(action)
        let actual = stateAfterSend ?? core.state
        isAwaitingSendResult = false

        expectStateChange(
            from: baseline, to: actual, update: updateStateToExpectedResult,
            description: "send(\(action))",
            fileID: fileID, filePath: filePath, line: line, column: column
        )
        baseline = actual
        await Task.megaYield()
        return TestStoreTask(rawValue: task, timeout: timeout)
    }

    // MARK: receive

    /// Checks that an effect sent exactly this Action.
    public func receive(
        _ expectedAction: Action,
        timeout: Double? = nil,
        assert updateStateToExpectedResult: ((_ state: inout State) throws -> Void)? = nil,
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async where Action: Equatable {
        await _receive(
            matching: { $0 == expectedAction },
            description: "\(expectedAction)",
            timeout: timeout, update: updateStateToExpectedResult,
            fileID: fileID, filePath: filePath, line: line, column: column
        )
    }

    /// Checks that an effect sent an Action of the given case: `\.didLoad`.
    public func receive<Value>(
        _ casePath: CaseKeyPath<Action, Value>,
        timeout: Double? = nil,
        assert updateStateToExpectedResult: ((_ state: inout State) throws -> Void)? = nil,
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async where Action: CasePathable {
        await _receive(
            matching: { $0.is(casePath) },
            description: "\(casePath)",
            timeout: timeout, update: updateStateToExpectedResult,
            fileID: fileID, filePath: filePath, line: line, column: column
        )
    }

    /// Checks the case and the associated value: `receive(\.didFail, "error")`.
    public func receive<Value: Equatable>(
        _ casePath: CaseKeyPath<Action, Value>,
        _ value: Value,
        timeout: Double? = nil,
        assert updateStateToExpectedResult: ((_ state: inout State) throws -> Void)? = nil,
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async where Action: CasePathable {
        await _receive(
            matching: { $0[case: casePath] == value },
            description: "\(casePath) == \(value)",
            timeout: timeout, update: updateStateToExpectedResult,
            fileID: fileID, filePath: filePath, line: line, column: column
        )
    }

    private func _receive(
        matching: (Action) -> Bool,
        description: String,
        timeout: Double?,
        update: ((inout State) throws -> Void)?,
        fileID: StaticString, filePath: StaticString, line: UInt, column: UInt
    ) async {
        let deadline = Date().addingTimeInterval(timeout ?? self.timeout)
        func hasCandidate() -> Bool {
            exhaustivity == .on ? !received.isEmpty : received.contains { matching($0.action) }
        }
        while !hasCandidate() {
            if Date() >= deadline { break }
            if core.inFlightEffectCount == 0 {
                await Task.megaYield()
                if !hasCandidate() && core.inFlightEffectCount == 0 { break }
                continue
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }

        guard hasCandidate() else {
            reportIssue(
                """
                Expected to receive \(description), but no matching Action arrived\
                \(core.inFlightEffectCount > 0 ? " within \(timeout ?? self.timeout)s (effects are still in flight)" : "").
                """,
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return
        }

        let entry: (action: Action, state: State)
        if exhaustivity == .on {
            entry = received.removeFirst()
            guard matching(entry.action) else {
                reportIssue(
                    """
                    Received Action differs from the expected one.

                      Expected: \(description)
                      Received: \(entry.action)
                    """,
                    fileID: fileID, filePath: filePath, line: line, column: column
                )
                baseline = entry.state
                await settleEffects()
                return
            }
        } else {
            let index = received.firstIndex { matching($0.action) }!
            if index > 0 { baseline = received[index - 1].state }
            entry = received[index]
            received.removeFirst(index + 1)
        }

        expectStateChange(
            from: baseline, to: entry.state, update: update,
            description: "receive(\(description))",
            fileID: fileID, filePath: filePath, line: line, column: column
        )
        baseline = entry.state
        await settleEffects()
    }

    /// After a received Action, the effect that sent it still needs a few
    /// executor hops to finish (e.g. returning from the `.run`'s `catch:`).
    /// TCA guarantees this by running tests on a serial executor; here, without
    /// one, a single `megaYield` is not enough when the suite runs in parallel.
    /// Waits up to `timeout × 50` attempts of ~1 ms (~50 ms with the 1 s default)
    /// for the effects to settle — long-running effects (timers, streams) only
    /// cost that wait, without changing the result.
    private func settleEffects() async {
        await Task.megaYield()
        // ~1 ms attempts (not a wall-clock deadline): under load each wait gets
        // longer, which gives extra slack exactly when the machine is slow.
        let maxAttempts = max(1, Int(timeout * 50))
        var attempts = 0
        while core.inFlightEffectCount > 0, attempts < maxAttempts {
            try? await Task.sleep(nanoseconds: 1_000_000)
            attempts += 1
        }
    }

    // MARK: finish / skip

    /// Waits for all in-flight effects to finish.
    public func finish(
        timeout: Double? = nil,
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async {
        let deadline = Date().addingTimeInterval(timeout ?? self.timeout)
        while core.inFlightEffectCount > 0, Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        await Task.megaYield()
        if core.inFlightEffectCount > 0 {
            reportIssue(
                "Expected the effects to finish, but \(core.inFlightEffectCount) are still in flight.",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
        }
    }

    /// Discards received Actions that were not checked yet.
    public func skipReceivedActions() async {
        await Task.megaYield()
        if let last = received.last { baseline = last.state }
        received.removeAll()
    }

    /// Cancels the in-flight effects.
    public func skipInFlightEffects() async {
        core.cancelAllEffects()
        await Task.megaYield()
    }

    // MARK: Verification

    private func expectStateChange(
        from previous: State,
        to actual: State,
        update: ((inout State) throws -> Void)?,
        description: String,
        fileID: StaticString, filePath: StaticString, line: UInt, column: UInt
    ) {
        var expected: State
        switch exhaustivity {
        case .on:
            expected = previous
        case .off:
            expected = actual
        }
        do {
            try update?(&expected)
        } catch {
            reportIssue("The assertion closure threw an error: \(error)",
                        fileID: fileID, filePath: filePath, line: line, column: column)
            return
        }

        if expected != actual {
            let diff = lineDiff(expected: debugText(expected), actual: debugText(actual))
            reportIssue(
                """
                The state after \(description) is not the expected one. (− expected, + received)

                \(diff)
                """,
                fileID: fileID, filePath: filePath, line: line, column: column
            )
        } else if exhaustivity == .on, update != nil, previous == actual {
            reportIssue(
                "An assertion closure was passed for \(description), but the state did not change. Remove the closure.",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
        }
    }

    private func completed(
        core: RootCore<State, Action>,
        location: (fileID: StaticString, filePath: StaticString, line: UInt, column: UInt)
    ) {
        guard exhaustivity == .on else {
            core.cancelAllEffects()
            return
        }
        if !received.isEmpty {
            reportIssue(
                """
                The test finished with \(received.count) received Action(s) not checked:

                \(received.map { "  • \($0.action)" }.joined(separator: "\n"))
                """,
                fileID: location.fileID, filePath: location.filePath, line: location.line, column: location.column
            )
        }
        if core.inFlightEffectCount > 0 {
            reportIssue(
                """
                The test finished with \(core.inFlightEffectCount) effect(s) still in flight.

                Await them with "await store.finish()", make them cancellable, or use \
                "await store.skipInFlightEffects()".
                """,
                fileID: location.fileID, filePath: location.filePath, line: location.line, column: location.column
            )
        }
        core.cancelAllEffects()
    }
}

// MARK: - TestStoreTask

public struct TestStoreTask: Sendable {
    let rawValue: Task<Void, Never>?
    let timeout: Double

    /// Cancels the effects started by the `send`.
    public func cancel() async {
        rawValue?.cancel()
        await Task.megaYield()
    }

    /// Waits for the effects started by the `send` to finish.
    public func finish(
        timeout: Double? = nil,
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) async {
        guard let rawValue else { return }
        let limit = timeout ?? self.timeout
        let finished = LockIsolated(false)
        let waiter = Task {
            await rawValue.value
            finished.setValue(true)
        }
        let deadline = Date().addingTimeInterval(limit)
        while !finished.value, Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        if !finished.value {
            waiter.cancel()
            reportIssue(
                "The effects did not finish within \(limit)s.",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
        }
    }

    public var isCancelled: Bool {
        rawValue?.isCancelled ?? true
    }
}
