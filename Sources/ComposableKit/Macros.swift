// MARK: - Macros
//
// Same syntax as TCA (Point-Free):
//
// ```swift
// @Reducer
// struct CounterFeature {
//     @ObservableState
//     struct State: Equatable { var count = 0 }
//     enum Action { case increment }
//     var body: some ReducerOf<Self> {
//         Reduce { state, action in
//             switch action {
//             case .increment:
//                 state.count += 1
//                 return .none
//             }
//         }
//     }
// }
// ```

/// Conforms the struct to `Reducer`, applies `@CasePathable` to `enum Action`
/// and `@ObservableState` to `struct State`.
@attached(memberAttribute)
@attached(extension, conformances: Reducer, _ReducerTypes)
public macro Reducer() = #externalMacro(module: "ComposableKitMacros", type: "ReducerMacro")

/// Generates the enum's case paths (`\.case`) and the `CasePathable` conformance.
/// If the enum has `case binding(BindingAction<...>)`, it also generates
/// `BindableAction` support.
@attached(member, names: named(AllCasePaths), named(allCasePaths), named(_bindingAction))
@attached(extension, conformances: CasePathable)
public macro CasePathable() = #externalMacro(module: "ComposableKitMacros", type: "CasePathableMacro")

/// Marks the state as observable by the `Store`.
///
/// On iOS 15/16 observation uses `ObservableObject` (the View redraws when
/// its Store's state changes; equal values are ignored). The syntax matches
/// TCA so that switching to `Observation` (iOS 17+) can happen entirely
/// inside the package.
@attached(extension, conformances: ObservableState)
public macro ObservableState() = #externalMacro(module: "ComposableKitMacros", type: "ObservableStateMacro")

/// Conformance added by `@ObservableState`.
public protocol ObservableState {}
