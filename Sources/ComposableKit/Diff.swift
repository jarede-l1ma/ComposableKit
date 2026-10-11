/// Textual representation of a value (via `dump`).
func debugText(_ value: Any) -> String {
    var output = ""
    dump(value, to: &output, indent: 0)
    return output
}

/// Simple line-by-line diff (LCS): "−" = expected, "+" = received.
func lineDiff(expected: String, actual: String) -> String {
    let a = expected.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let b = actual.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var lcs = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
    for i in stride(from: a.count - 1, through: 0, by: -1) {
        for j in stride(from: b.count - 1, through: 0, by: -1) {
            lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
        }
    }
    var i = 0, j = 0
    var lines: [String] = []
    while i < a.count && j < b.count {
        if a[i] == b[j] {
            lines.append("  " + a[i]); i += 1; j += 1
        } else if lcs[i + 1][j] >= lcs[i][j + 1] {
            lines.append("− " + a[i]); i += 1
        } else {
            lines.append("+ " + b[j]); j += 1
        }
    }
    while i < a.count { lines.append("− " + a[i]); i += 1 }
    while j < b.count { lines.append("+ " + b[j]); j += 1 }
    return lines.joined(separator: "\n")
}
