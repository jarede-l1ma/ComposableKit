import Foundation
import ComposableKit
import Testing

// Helpers shared by the package tests.

/// Minimal state for ad-hoc reducers.
struct Log: Equatable, Sendable {
    var entries: [String] = []
}

/// Generic Action for ad-hoc reducers.
@CasePathable
enum Act: Equatable, Sendable {
    case start
    case stop
    case append(String)
    case value(Int)
}

/// `true` if the issue contains `text` in any comment.
func issue(_ issue: Issue, contains text: String) -> Bool {
    issue.comments.contains { $0.rawValue.contains(text) } || "\(issue)".contains(text)
}

extension TestStore {
    /// Shorthand for `exhaustivity = .off` in tests.
    func nonExhaustive() -> Self {
        exhaustivity = .off
        return self
    }
}
