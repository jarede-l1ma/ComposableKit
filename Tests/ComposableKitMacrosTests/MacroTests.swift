import ComposableKitMacros
import SwiftSyntaxMacros
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacrosTestSupport
import XCTest

final class MacroTests: XCTestCase {
    // `conformances` simulates what the compiler passes to extension macros
    // (without it `protocols` arrives empty and no extension is generated).
    let macros: [String: MacroSpec] = [
        "Reducer": MacroSpec(type: ReducerMacro.self, conformances: ["Reducer", "_ReducerTypes"]),
        "CasePathable": MacroSpec(type: CasePathableMacro.self, conformances: ["CasePathable"]),
        "ObservableState": MacroSpec(type: ObservableStateMacro.self, conformances: ["ObservableState"]),
    ]

    func testCasePathableGeneratesCasePaths() {
        assertMacroExpansion(
            """
            @CasePathable
            enum Action {
                case tap
                case load(String)
            }
            """,
            expandedSource: """
            enum Action {
                case tap
                case load(String)

                struct AllCasePaths: Sendable {
                    init() {
                    }
                    var tap: ComposableKit.AnyCasePath<Action, Void> {
                        ComposableKit.AnyCasePath(
                            embed: { _ in
                                .tap
                            },
                            extract: {
                                if case .tap = $0 {
                                    return ()
                                };
                                return nil
                            }
                        )
                    }
                    var load: ComposableKit.AnyCasePath<Action, String> {
                        ComposableKit.AnyCasePath(
                            embed: {
                                .load($0)
                            },
                            extract: {
                                if case let .load(v0) = $0 {
                                    return v0
                                };
                                return nil
                            }
                        )
                    }
                }

                static var allCasePaths: AllCasePaths {
                    AllCasePaths()
                }
            }

            extension Action: ComposableKit.CasePathable {
            }
            """,
            macroSpecs: macros
        )
    }

    func testReducerAnnotatesStateAndAction() {
        assertMacroExpansion(
            """
            @Reducer
            struct Feature {
                struct State {}
                enum Action {}
                var body: some ReducerOf<Self> {
                    EmptyReducer()
                }
            }
            """,
            expandedSource: """
            struct Feature {
                @ComposableKit.ObservableState
                struct State {}
                @ComposableKit.CasePathable
                enum Action {}
                @ComposableKit.ReducerBuilder<Self.State, Self.Action>
                var body: some ReducerOf<Self> {
                    EmptyReducer()
                }
            }

            extension Feature: ComposableKit.Reducer, ComposableKit._ReducerTypes {
            }
            """,
            macroSpecs: ["Reducer": macros["Reducer"]!]
        )
    }

    func testReducerRejectsEnum() {
        assertMacroExpansion(
            """
            @Reducer
            enum Feature {}
            """,
            expandedSource: """
            enum Feature {}
            """,
            diagnostics: [
                DiagnosticSpec(message: "@Reducer can only be applied to a struct.", line: 1, column: 1)
            ],
            macroSpecs: ["Reducer": macros["Reducer"]!]
        )
    }

    func testCasePathableRejectsStruct() {
        assertMacroExpansion(
            """
            @CasePathable
            struct NotEnum {}
            """,
            expandedSource: """
            struct NotEnum {}
            """,
            diagnostics: [
                DiagnosticSpec(message: "@CasePathable can only be applied to an enum.", line: 1, column: 1)
            ],
            macroSpecs: ["CasePathable": macros["CasePathable"]!]
        )
    }

    func testObservableStateAddsConformance() {
        assertMacroExpansion(
            """
            @ObservableState
            struct State {}
            """,
            expandedSource: """
            struct State {}

            extension State: ComposableKit.ObservableState {
            }
            """,
            macroSpecs: ["ObservableState": macros["ObservableState"]!]
        )
    }

    func testReducerDoesNotDuplicateExistingAttributes() {
        assertMacroExpansion(
            """
            @Reducer
            struct Feature {
                @ObservableState
                struct State {}
                @CasePathable
                enum Action {}
                struct Other {}
                enum Route {}
            }
            """,
            expandedSource: """
            struct Feature {
                @ObservableState
                struct State {}
                @CasePathable
                enum Action {}
                struct Other {}
                enum Route {}
            }

            extension Feature: ComposableKit.Reducer, ComposableKit._ReducerTypes {
            }
            """,
            macroSpecs: ["Reducer": macros["Reducer"]!]
        )
    }

    // Cases with associated values (labeled, multiple, binding, public)
    // are verified by behavior in CasePathsTests and BindingTests,
    // which compile and use the generated code.
}

