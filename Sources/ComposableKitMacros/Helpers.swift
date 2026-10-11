import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

struct MacroError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

extension AttributeListSyntax {
    /// `true` if the list already contains the `name` attribute (with or without module).
    func contains(attributeNamed name: String) -> Bool {
        contains { element in
            guard case let .attribute(attribute) = element else { return false }
            let text = attribute.attributeName.trimmedDescription
            return text == name || text.hasSuffix(".\(name)")
        }
    }
}

extension DeclModifierListSyntax {
    /// Access modifier to repeat on generated members ("public ", "package " or "").
    var accessPrefix: String {
        for modifier in self {
            switch modifier.name.tokenKind {
            case .keyword(.public), .keyword(.open):
                return "public "
            case .keyword(.package):
                return "package "
            default:
                continue
            }
        }
        return ""
    }
}

func conformanceExtension(
    for type: some TypeSyntaxProtocol,
    protocols: [TypeSyntax],
    conformance: String
) throws -> [ExtensionDeclSyntax] {
    guard !protocols.isEmpty else { return [] }
    let decl: DeclSyntax = "extension \(type.trimmed): \(raw: conformance) {}"
    guard let ext = decl.as(ExtensionDeclSyntax.self) else { return [] }
    return [ext]
}
