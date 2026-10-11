// MARK: - Reducer
//
// Same contract as TCA. Implement `body` (composition, the common case) or
// `reduce(into:action:)` (a "leaf" reducer). Use the `@Reducer` macro.

/// Just a reducer's `State`/`Action` types. It exists so `ReducerOf<Self>` does not
/// depend on the full `Reducer` conformance: in `var body: some ReducerOf<Self>`
/// Swift is still inferring `Body`, and requiring `Self: Reducer` there causes a
/// "circular reference" when the feature is used from another file.
public protocol _ReducerTypes {
    associatedtype State
    associatedtype Action
}

public protocol Reducer<State, Action>: _ReducerTypes {
    associatedtype State
    associatedtype Action
    /// `Never` for "leaf" reducers that only implement `reduce(into:action:)`.
    associatedtype Body

    /// The feature's logic: applies `action` to `state` and returns the effects.
    func reduce(into state: inout State, action: Action) -> Effect<Action>

    /// Internal dispatch point (same as TCA). Having an unconstrained default
    /// `reduce` and forwarding to `body` in this requirement is what lets
    /// Swift infer `Body` from `var body: some ReducerOf<Self>`.
    func _reduce(into state: inout State, action: Action) -> Effect<Action>

    /// Reducer composition (`Reduce`, `Scope`, `BindingReducer`, `.ifLet`...).
    @ReducerBuilder<State, Action>
    var body: Body { get }
}

extension Reducer {
    public func _reduce(into state: inout State, action: Action) -> Effect<Action> {
        reduce(into: &state, action: action)
    }

    public func reduce(into state: inout State, action: Action) -> Effect<Action> {
        _reduce(into: &state, action: action)
    }
}

extension Reducer where Body == Never {
    public var body: Body {
        fatalError("'\(Self.self)' has no 'body'. Implement 'body' or 'reduce(into:action:)'.")
    }
}

extension Reducer where Body: Reducer<State, Action> {
    @inlinable
    public func _reduce(into state: inout Body.State, action: Body.Action) -> Effect<Body.Action> {
        body._reduce(into: &state, action: action)
    }
}

public typealias ReducerOf<R: _ReducerTypes> = Reducer<R.State, R.Action>

// MARK: - Reduce

/// A reducer built from a closure. This is where the feature's logic lives.
public struct Reduce<State, Action>: Reducer {
    @usableFromInline
    let reduce: (inout State, Action) -> Effect<Action>

    public init(_ reduce: @escaping (_ state: inout State, _ action: Action) -> Effect<Action>) {
        self.reduce = reduce
    }

    public init<R: Reducer>(_ reducer: R) where R.State == State, R.Action == Action {
        self.reduce = { reducer.reduce(into: &$0, action: $1) }
    }

    @inlinable
    public func reduce(into state: inout State, action: Action) -> Effect<Action> {
        reduce(&state, action)
    }
}

// MARK: - EmptyReducer

public struct EmptyReducer<State, Action>: Reducer {
    public init() {}

    public func reduce(into state: inout State, action: Action) -> Effect<Action> {
        .none
    }
}

// MARK: - CombineReducers

/// Groups reducers to apply an operator (e.g. `.ifLet`) to all of them.
public struct CombineReducers<State, Action, Reducers: Reducer>: Reducer
where Reducers.State == State, Reducers.Action == Action {
    let reducers: Reducers

    public init(@ReducerBuilder<State, Action> _ build: () -> Reducers) {
        self.reducers = build()
    }

    public func reduce(into state: inout State, action: Action) -> Effect<Action> {
        reducers.reduce(into: &state, action: action)
    }
}

// MARK: - ReducerBuilder

@resultBuilder
public enum ReducerBuilder<State, Action> {
    public static func buildBlock() -> EmptyReducer<State, Action> {
        EmptyReducer()
    }

    public static func buildExpression<R: Reducer>(_ expression: R) -> R
    where R.State == State, R.Action == Action {
        expression
    }

    public static func buildPartialBlock<R: Reducer>(first: R) -> R
    where R.State == State, R.Action == Action {
        first
    }

    public static func buildPartialBlock<R0: Reducer, R1: Reducer>(
        accumulated: R0, next: R1
    ) -> _SequenceReducer<R0, R1>
    where R0.State == State, R0.Action == Action, R1.State == State, R1.Action == Action {
        _SequenceReducer(r0: accumulated, r1: next)
    }

    public static func buildOptional<R: Reducer>(_ wrapped: R?) -> _OptionalReducer<R>
    where R.State == State, R.Action == Action {
        _OptionalReducer(wrapped: wrapped)
    }

    public static func buildEither<R0: Reducer, R1: Reducer>(first reducer: R0) -> _ConditionalReducer<R0, R1>
    where R0.State == State, R0.Action == Action, R1.State == State, R1.Action == Action {
        .first(reducer)
    }

    public static func buildEither<R0: Reducer, R1: Reducer>(second reducer: R1) -> _ConditionalReducer<R0, R1>
    where R0.State == State, R0.Action == Action, R1.State == State, R1.Action == Action {
        .second(reducer)
    }

    public static func buildArray<R: Reducer>(_ reducers: [R]) -> _ArrayReducer<R>
    where R.State == State, R.Action == Action {
        _ArrayReducer(reducers: reducers)
    }

    public static func buildLimitedAvailability<R: Reducer>(_ wrapped: R) -> Reduce<State, Action>
    where R.State == State, R.Action == Action {
        Reduce(wrapped)
    }
}

public struct _SequenceReducer<R0: Reducer, R1: Reducer>: Reducer
where R0.State == R1.State, R0.Action == R1.Action {
    let r0: R0
    let r1: R1

    public func reduce(into state: inout R0.State, action: R0.Action) -> Effect<R0.Action> {
        let e0 = r0.reduce(into: &state, action: action)
        let e1 = r1.reduce(into: &state, action: action)
        return .merge(e0, e1)
    }
}

public struct _OptionalReducer<Wrapped: Reducer>: Reducer {
    let wrapped: Wrapped?

    public func reduce(into state: inout Wrapped.State, action: Wrapped.Action) -> Effect<Wrapped.Action> {
        wrapped?.reduce(into: &state, action: action) ?? .none
    }
}

public enum _ConditionalReducer<R0: Reducer, R1: Reducer>: Reducer
where R0.State == R1.State, R0.Action == R1.Action {
    case first(R0)
    case second(R1)

    public func reduce(into state: inout R0.State, action: R0.Action) -> Effect<R0.Action> {
        switch self {
        case let .first(r0): r0.reduce(into: &state, action: action)
        case let .second(r1): r1.reduce(into: &state, action: action)
        }
    }
}

public struct _ArrayReducer<R: Reducer>: Reducer {
    let reducers: [R]

    public func reduce(into state: inout R.State, action: R.Action) -> Effect<R.Action> {
        .merge(reducers.map { $0.reduce(into: &state, action: action) })
    }
}
