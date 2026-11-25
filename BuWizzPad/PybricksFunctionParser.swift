import Foundation

enum PybricksFunctionParser {
    /// Wyciąga nazwy funkcji zdefiniowanych przez `def nazwa(...)`.
    /// Pomija funkcje pomocnicze runtime (te z preludium pybricks/).
    static func extractFunctionNames(from code: String,
                                     excluding excluded: Set<String> = []) -> [String] {
        let pattern = #"^\s*def\s+([A-Za-z_][A-Za-z0-9_]*)\s*\("#
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.anchorsMatchLines]) else { return [] }
        let range = NSRange(code.startIndex..<code.endIndex, in: code)
        var names: [String] = []
        regex.enumerateMatches(in: code, options: [], range: range) { match, _, _ in
            guard let m = match, let r = Range(m.range(at: 1), in: code) else { return }
            let name = String(code[r])
            if !excluded.contains(name) && !names.contains(name) {
                names.append(name)
            }
        }
        return names
    }

    /// Czy w kodzie istnieje `while True:` na poziomie modułu (poza `def`).
    static func hasTopLevelWhileTrue(_ code: String) -> Bool {
        var depth = 0
        for rawLine in code.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.drop(while: { $0 == " " || $0 == "\t" })
            let indent = rawLine.count - line.count
            if line.hasPrefix("def ") || line.hasPrefix("async def ") {
                depth = indent + 1
            } else if !line.isEmpty && indent == 0 {
                depth = 0
            }
            if depth == 0, line.hasPrefix("while True") {
                return true
            }
        }
        return false
    }
}
