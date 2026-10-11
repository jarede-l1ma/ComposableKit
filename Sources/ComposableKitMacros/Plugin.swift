import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct ComposableKitMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        ReducerMacro.self,
        CasePathableMacro.self,
        ObservableStateMacro.self,
    ]
}
