import Foundation
import SwiftUI

// MARK: - Effect
//
// Same model as TCA: the Reducer *declares* effects and the Store runs them.
//
// ```swift
// case .viewDidAppear:
//     state.isLoading = true
//     return .run { [homeClient] send in
//         let response = try await homeClient.fetchData()
//         await send(.didLoad(HomeMapper.map(response)))
//     } catch: { error, send in
//         await send(.didFail(error.localizedDescription))
//     }
//     .cancellable(id: CancelID.fetch, cancelInFlight: true)
// ```

public struct Effect<Action> {
    @usableFromInline
    indirect enum Operation {
        case none
        case send(Action)
        case run(priority: TaskPriority?, operation: @Sendable (Send<Action>) async -> Void)
        case merge([Effect<Action>])
        case concatenate([Effect<Action>])
        case cancellable(id: _CancelID, cancelInFlight: Bool, effect: Effect<Action>)
        case cancel(id: _CancelID)
    }

    @usableFromInline
    let operation: Operation

    @usableFromInline
    init(operation: Operation) {
        self.operation = operation
    }
}

// @unchecked Sendable: immutable; the `AnyHashable` is only built from
// `Hashable & Sendable` values (the `init` requires it) or arrays of them (`namespaced`).
/// Cancellation identifier (any `Hashable & Sendable`).
public struct _CancelID: Hashable, @unchecked Sendable {
    let id: AnyHashable

    init(_ id: some Hashable & Sendable) {
        self.id = AnyHashable(id)
    }

    private init(raw id: AnyHashable) {
        self.id = id
    }

    /// The same id, inside a child's namespace (`forEach`/`ifLet`).
    func namespaced(_ namespace: AnyHashable) -> _CancelID {
        _CancelID(raw: AnyHashable([namespace, id]))
    }
}

// MARK: - Construtores

extension Effect {
    /// No effect.
    public static var none: Self {
        Self(operation: .none)
    }

    /// Dispatches an Action back to the Store, synchronously.
    ///
    /// Prefer calling shared logic directly in the reducer; use `.send` when
    /// the Action needs to go through the cycle (e.g. to notify the parent).
    public static func send(_ action: Action) -> Self {
        Self(operation: .send(action))
    }

    /// Runs asynchronous work. Send as many Actions as you want with `send`.
    ///
    /// - Parameters:
    ///   - priority: The Task priority.
    ///   - operation: Asynchronous work. Unhandled errors are reported,
    ///     except `CancellationError`.
    ///   - handler: Optional. Handles errors thrown by `operation`.
    public static func run(
        priority: TaskPriority? = nil,
        operation: @escaping @Sendable (_ send: Send<Action>) async throws -> Void,
        catch handler: (@Sendable (_ error: any Error, _ send: Send<Action>) async -> Void)? = nil,
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) -> Self {
        Self(operation: .run(priority: priority) { send in
            do {
                try await operation(send)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                if let handler {
                    await handler(error, send)
                } else {
                    reportIssue(
                        """
                        An "Effect.run" threw an unhandled error: \(error)

                        Handle the error with "do/catch" inside "run" or pass "catch:".
                        """,
                        fileID: fileID, filePath: filePath, line: line, column: column
                    )
                }
            }
        })
    }

    /// Runs the effects in parallel.
    public static func merge(_ effects: Self...) -> Self {
        merge(effects)
    }

    /// Runs the effects in parallel.
    public static func merge(_ effects: some Sequence<Self>) -> Self {
        let effects = effects.filter { !$0.isNone }
        switch effects.count {
        case 0: return .none
        case 1: return effects[0]
        default: return Self(operation: .merge(effects))
        }
    }

    /// Runs the effects in sequence: each starts when the previous one finishes.
    public static func concatenate(_ effects: Self...) -> Self {
        concatenate(effects)
    }

    /// Runs the effects in sequence: each starts when the previous one finishes.
    public static func concatenate(_ effects: some Sequence<Self>) -> Self {
        let effects = effects.filter { !$0.isNone }
        switch effects.count {
        case 0: return .none
        case 1: return effects[0]
        default: return Self(operation: .concatenate(effects))
        }
    }

    public func merge(with other: Self) -> Self {
        .merge(self, other)
    }

    public func concatenate(with other: Self) -> Self {
        .concatenate(self, other)
    }

    // MARK: Cancelamento

    /// Makes the effect cancellable by `id`.
    ///
    /// - Parameter cancelInFlight: If `true`, cancels any in-flight effect
    ///   with the same `id` before starting this one (e.g. tapping "Try
    ///   again" twice in a row does not fire two requests).
    public func cancellable(id: some Hashable & Sendable, cancelInFlight: Bool = false) -> Self {
        if isNone && !cancelInFlight { return self }
        return Self(operation: .cancellable(id: _CancelID(id), cancelInFlight: cancelInFlight, effect: self))
    }

    /// Cancels the in-flight effects with `id`.
    public static func cancel(id: some Hashable & Sendable) -> Self {
        Self(operation: .cancel(id: _CancelID(id)))
    }

    // MARK: Debounce

    /// Waits `seconds` before running the effect; a new effect with the same
    /// `id` cancels the previous one. Use the dependency's `clock` for
    /// deterministic tests (`TestClock`).
    public func debounce(
        id: some Hashable & Sendable,
        for seconds: Double,
        clock: any EffectClock
    ) -> Self {
        guard !isNone else { return self }
        return Self.concatenate(
            .run { _ in try await clock.sleep(for: seconds) },
            self
        )
        .cancellable(id: id, cancelInFlight: true)
    }

    // MARK: Transformation

    /// Transforms the Actions the effect produces (used in composition).
    public func map<T>(_ transform: @escaping @Sendable (Action) -> T) -> Effect<T> {
        switch operation {
        case .none:
            return .none
        case let .send(action):
            return .send(transform(action))
        case let .run(priority, operation):
            return Effect<T>(operation: .run(priority: priority) { send in
                await operation(Send { action in send(transform(action)) })
            })
        case let .merge(effects):
            return Effect<T>(operation: .merge(effects.map { $0.map(transform) }))
        case let .concatenate(effects):
            return Effect<T>(operation: .concatenate(effects.map { $0.map(transform) }))
        case let .cancellable(id, cancelInFlight, effect):
            return Effect<T>(operation: .cancellable(id: id, cancelInFlight: cancelInFlight, effect: effect.map(transform)))
        case let .cancel(id):
            return Effect<T>(operation: .cancel(id: id))
        }
    }

    /// Puts the effect's cancellation ids in a child's namespace: two rows
    /// of a `forEach` with `CancelID.fetch` do not cancel each other
    /// (as in TCA). Ids of nested children compose the namespaces.
    func namespaced(_ namespace: AnyHashable) -> Self {
        switch operation {
        case .none, .send, .run:
            return self
        case let .merge(effects):
            return Self(operation: .merge(effects.map { $0.namespaced(namespace) }))
        case let .concatenate(effects):
            return Self(operation: .concatenate(effects.map { $0.namespaced(namespace) }))
        case let .cancellable(id, cancelInFlight, effect):
            return Self(operation: .cancellable(
                id: id.namespaced(namespace),
                cancelInFlight: cancelInFlight,
                effect: effect.namespaced(namespace)
            ))
        case let .cancel(id):
            return Self(operation: .cancel(id: id.namespaced(namespace)))
        }
    }

    var isNone: Bool {
        if case .none = operation { return true }
        return false
    }

    var isSend: Bool {
        if case .send = operation { return true }
        return false
    }
}

// MARK: - Send

/// Sends Actions back to the Store from an `Effect.run`.
///
/// ```swift
/// return .run { send in
///     await send(.didLoad(data))
/// }
/// ```
/// Actions sent after the effect was cancelled are dropped.
@MainActor
public struct Send<Action>: Sendable {
    let send: @MainActor @Sendable (Action) -> Void

    public nonisolated init(send: @escaping @MainActor @Sendable (Action) -> Void) {
        self.send = send
    }

    public func callAsFunction(_ action: Action) {
        guard !Task.isCancelled else { return }
        send(action)
    }

    /// Sends the Action inside `withAnimation`, as in TCA:
    /// `await send(.didLoad(viewData), animation: .default)`.
    public func callAsFunction(_ action: Action, animation: Animation?) {
        guard !Task.isCancelled else { return }
        withAnimation(animation) {
            send(action)
        }
    }
}
