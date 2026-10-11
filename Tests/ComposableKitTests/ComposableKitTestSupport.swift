import Foundation
import ComposableKit
import Testing

/// Routes problems detected by ComposableKit (TestStore assertions,
/// dependencies without a test value, effects with unhandled errors)
/// to Swift Testing failures, and gives each test its own `@Shared` values.
/// Copy this file, unchanged, into each module's test target.
/// Without it, tests do NOT fail.
@objc(ComposableKitTestSupport)
final class ComposableKitTestSupport: NSObject, ComposableKitTestIssueReporting {
    static func reportIssue(_ message: String, fileID: String, filePath: String, line: Int, column: Int) {
        let location = SourceLocation(
            fileID: fileID,
            filePath: filePath,
            line: max(1, line),
            column: max(1, column)
        )
        if Test.current != nil {
            Issue.record(Comment(rawValue: message), sourceLocation: location)
        } else {
            print("⚠️ [ComposableKit] \(location) — \(message)")
        }
    }

    /// The running test: each test has its own `@Shared` values
    /// (parallel tests do not see each other).
    @objc static func currentTestScope() -> String? {
        guard let test = Test.current else { return nil }
        return ([test.id.moduleName] + test.id.nameComponents).joined(separator: ".")
    }
}
