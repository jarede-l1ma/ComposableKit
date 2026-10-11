import SwiftSyntax
import SwiftSyntaxMacros

/// `@Reducer`: conforma a `Reducer` e anota `State`/`Action`.
public enum ReducerMacro: MemberAttributeMacro, ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingAttributesFor member: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AttributeSyntax] {
        if let enumDecl = member.as(EnumDeclSyntax.self),
           enumDecl.name.text == "Action",
           !enumDecl.attributes.contains(attributeNamed: "CasePathable") {
            return ["@ComposableKit.CasePathable"]
        }
        if let structDecl = member.as(StructDeclSyntax.self),
           structDecl.name.text == "State",
           !structDecl.attributes.contains(attributeNamed: "ObservableState") {
            return ["@ComposableKit.ObservableState"]
        }
        // Swift only inherits the protocol's `@ReducerBuilder` when the conformance
        // is on the main declaration. Since the conformance comes from a generated
        // extension, the attribute has to be applied here (same as TCA).
        if let variable = member.as(VariableDeclSyntax.self),
           variable.bindings.count == 1,
           variable.bindings.first?.pattern.trimmedDescription == "body",
           !variable.attributes.contains(attributeNamed: "ReducerBuilder") {
            return ["@ComposableKit.ReducerBuilder<Self.State, Self.Action>"]
        }
        return []
    }

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard declaration.is(StructDeclSyntax.self) else {
            throw MacroError("@Reducer can only be applied to a struct.")
        }
        // Explicit `_ReducerTypes`: as an implicit-only conformance (inherited from `Reducer`),
        // the compiler sometimes emits its witness table in no file of the
        // module and linking fails ("protocol witness table for X : _ReducerTypes").
        return try conformanceExtension(
            for: type,
            protocols: protocols,
            conformance: "ComposableKit.Reducer, ComposableKit._ReducerTypes"
        )
    }
}

/// `@ObservableState`: conforma a `ObservableState`.
public enum ObservableStateMacro: ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        try conformanceExtension(for: type, protocols: protocols, conformance: "ComposableKit.ObservableState")
    }
}
