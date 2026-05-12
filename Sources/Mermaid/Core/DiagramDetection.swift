import Foundation

/// Recognised diagram type keywords. Only the first few are implemented; the rest are detected so we
/// can throw `.unsupportedDiagramType` cleanly instead of crashing.
enum DiagramType: String {
    case flowchart
    case sequence
    case state
    case classDiagram = "class"
    case pie
    case er
    case gantt
    case gitGraph
    case journey
    case mindmap
    case timeline
    case quadrant
    case requirement
    case c4
    case sankey
    case xychart
    case block
    case architecture
    case unknown
}

struct Preprocessed {
    /// Source with comments / frontmatter / `%%{init}%%` removed. Line numbers are *not* preserved
    /// exactly, but blank lines are kept where directives were, so reported lines stay close.
    var body: String
    /// `theme` value pulled from `%%{init: {...}}%%` or YAML frontmatter, if any.
    var theme: MermaidTheme?
    /// The raw first significant token (used for `unsupportedDiagramType` messages).
    var typeKeyword: String
    var type: DiagramType
}

enum DiagramPreprocessor {

    static func process(_ source: String, requestedTheme: MermaidTheme) -> Preprocessed {
        var lines = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var theme: MermaidTheme? = nil

        // 1. Leading YAML frontmatter: a line that is exactly "---", up to the next "---".
        lines = stripFrontmatter(lines, theme: &theme)

        // 2. Line comments (`%% …`) and `%%{init: …}%%` directives. Mermaid's comment syntax is a
        //    line that starts (after whitespace) with `%%`. `%%{ … }%%` may span one line.
        var cleaned: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("%%{") {
                if let parsed = parseInitDirective(trimmed) { theme = theme ?? parsed }
                cleaned.append("")
                continue
            }
            if trimmed.hasPrefix("%%") {
                cleaned.append("")
                continue
            }
            cleaned.append(line)
        }

        let body = cleaned.joined(separator: "\n")
        let (keyword, type) = detectType(body)
        return Preprocessed(body: body,
                            theme: requestedTheme == .default ? theme : requestedTheme,
                            typeKeyword: keyword,
                            type: type)
    }

    private static func stripFrontmatter(_ lines: [String], theme: inout MermaidTheme?) -> [String] {
        var idx = 0
        while idx < lines.count, lines[idx].trimmingCharacters(in: .whitespaces).isEmpty { idx += 1 }
        guard idx < lines.count, lines[idx].trimmingCharacters(in: .whitespaces) == "---" else {
            return lines
        }
        var end = idx + 1
        while end < lines.count, lines[end].trimmingCharacters(in: .whitespaces) != "---" { end += 1 }
        guard end < lines.count else { return lines }   // unterminated → leave it alone
        // Scan the frontmatter for `theme:` (possibly nested under `config:`).
        for i in (idx + 1)..<end {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if let r = t.range(of: "theme:") {
                let value = t[r.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                theme = theme ?? MermaidTheme(rawValue: value)
            }
        }
        // Replace the whole block with blanks to keep line numbers approximately stable.
        var out = lines
        for i in idx...end { out[i] = "" }
        return out
    }

    /// Very small extractor: we only care about the `theme` value, so a regex is enough — no JSON.
    private static func parseInitDirective(_ line: String) -> MermaidTheme? {
        // Forms: %%{init: {'theme':'dark'}}%%  or  %%{ "theme": "dark" }%%  etc.
        guard let r = line.range(of: "theme") else { return nil }
        let rest = line[r.upperBound...]
        // skip spaces, ':', quotes
        var value = ""
        var started = false
        for ch in rest {
            if !started {
                if ch == ":" || ch == " " || ch == "'" || ch == "\"" { continue }
                if ch == "}" || ch == "," { break }
                started = true
                value.append(ch)
            } else {
                if ch.isLetter || ch.isNumber { value.append(ch) } else { break }
            }
        }
        return MermaidTheme(rawValue: value)
    }

    /// Mirrors Mermaid's `detectType`: after preprocessing, the first significant token decides.
    static func detectType(_ body: String) -> (keyword: String, type: DiagramType) {
        // First non-empty, non-directive line.
        let firstLine = body.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? ""

        // The keyword is the leading run of letters/digits/hyphens.
        let keyword = String(firstLine.prefix { $0.isLetter || $0.isNumber || $0 == "-" })
        let lower = keyword.lowercased()

        switch lower {
        case "flowchart", "graph", "flowchart-elk":
            return (keyword, .flowchart)
        case "sequencediagram":
            return (keyword, .sequence)
        case "statediagram", "statediagram-v2":
            return (keyword, .state)
        case "classdiagram", "classdiagram-v2":
            return (keyword, .classDiagram)
        case "pie":
            return (keyword, .pie)
        case "erdiagram":
            return (keyword, .er)
        case "gantt":
            return (keyword, .gantt)
        case "gitgraph":
            return (keyword, .gitGraph)
        case "journey":
            return (keyword, .journey)
        case "mindmap":
            return (keyword, .mindmap)
        case "timeline":
            return (keyword, .timeline)
        case "quadrantchart":
            return (keyword, .quadrant)
        case "requirementdiagram":
            return (keyword, .requirement)
        case "sankey-beta":
            return (keyword, .sankey)
        case "xychart-beta":
            return (keyword, .xychart)
        case "block-beta":
            return (keyword, .block)
        case "architecture-beta", "architecture":
            return (keyword, .architecture)
        case "c4context", "c4container", "c4component", "c4dynamic", "c4deployment":
            return (keyword, .c4)
        default:
            return (keyword.isEmpty ? firstLine : keyword, .unknown)
        }
    }
}
