import SwiftSyntax
import SwiftSyntaxMacros

/// `@CasePathable`: generates `AllCasePaths`, `allCasePaths` and, if there is a
/// `case binding(BindingAction<...>)`, the `_bindingAction` of `BindableAction`.
public enum CasePathableMacro: MemberMacro, ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let enumDecl = declaration.as(EnumDeclSyntax.self) else {
            throw MacroError("@CasePathable can only be applied to an enum.")
        }
        let enumName = enumDecl.name.trimmedDescription
        let access = enumDecl.modifiers.accessPrefix
        var properties: [String] = []
        var bindingType: String?

        for member in enumDecl.memberBlock.members {
            guard let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
            for element in caseDecl.elements {
                let name = element.name.trimmedDescription
                let parameters = Array(element.parameterClause?.parameters ?? [])

                switch parameters.count {
                case 0:
                    properties.append("""
                        \(access)var \(name): ComposableKit.AnyCasePath<\(enumName), Void> {
                            ComposableKit.AnyCasePath(
                                embed: { _ in .\(name) },
                                extract: { if case .\(name) = $0 { return () }; return nil }
                            )
                        }
                        """)

                case 1:
                    let parameter = parameters[0]
                    let type = parameter.type.trimmedDescription
                    let label = parameter.firstName.flatMap { $0.tokenKind == .wildcard ? nil : $0.trimmedDescription }
                    let embedArgument = label.map { "\($0): $0" } ?? "$0"
                    properties.append("""
                        \(access)var \(name): ComposableKit.AnyCasePath<\(enumName), \(type)> {
                            ComposableKit.AnyCasePath(
                                embed: { .\(name)(\(embedArgument)) },
                                extract: { if case let .\(name)(v0) = $0 { return v0 }; return nil }
                            )
                        }
                        """)
                    if name == "binding", type.hasPrefix("BindingAction<") || type.hasPrefix("ComposableKit.BindingAction<") {
                        bindingType = type
                    }

                default:
                    let types = parameters.map { $0.type.trimmedDescription }
                    let tupleType = "(" + types.joined(separator: ", ") + ")"
                    let embedArguments = parameters.enumerated().map { index, parameter in
                        let label = parameter.firstName.flatMap { $0.tokenKind == .wildcard ? nil : $0.trimmedDescription }
                        return label.map { "\($0): $0.\(index)" } ?? "$0.\(index)"
                    }
                    let bindings = (0..<parameters.count).map { "v\($0)" }
                    properties.append("""
                        \(access)var \(name): ComposableKit.AnyCasePath<\(enumName), \(tupleType)> {
                            ComposableKit.AnyCasePath(
                                embed: { .\(name)(\(embedArguments.joined(separator: ", "))) },
                                extract: { if case let .\(name)(\(bindings.joined(separator: ", "))) = $0 { return (\(bindings.joined(separator: ", "))) }; return nil }
                            )
                        }
                        """)
                }
            }
        }

        // Lines after the first need the indentation of the interpolation point.
        let indentedProperties = properties
            .joined(separator: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .joined(separator: "\n    ")
        var decls: [DeclSyntax] = [
            """
            \(raw: access)struct AllCasePaths: Sendable {
                \(raw: access)init() {}
                \(raw: indentedProperties)
            }
            """,
            "\(raw: access)static var allCasePaths: AllCasePaths { AllCasePaths() }",
        ]
        if let bindingType {
            decls.append("""
                \(raw: access)var _bindingAction: \(raw: bindingType)? {
                    if case let .binding(v0) = self { return v0 }
                    return nil
                }
                """)
        }
        return decls
    }

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        // The non-enum error is already reported by the MemberMacro.
        guard declaration.is(EnumDeclSyntax.self) else { return [] }
        return try conformanceExtension(for: type, protocols: protocols, conformance: "ComposableKit.CasePathable")
    }
}
