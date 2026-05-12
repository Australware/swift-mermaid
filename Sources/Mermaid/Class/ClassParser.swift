import Foundation

/// Hand-written parser for the class-diagram syntax. The reference grammar is
/// `packages/mermaid/src/diagrams/class/parser/classDiagram.jison`; we cover the common subset —
/// classes (with `{ … }` member blocks or `:` member statements), relationships with all marker
/// kinds plus cardinality strings and `: label`s, `<<stereotype>>` annotations, `~Generic~` types,
/// `class X["display label"]`, and `direction`. Notes, namespaces (flattened), `style`, `classDef`,
/// `cssClass`, `click`/`link`/`callback` are parse-and-skipped.
enum ClassParser {

    static func parse(_ source: String) throws -> ClassDiagramAST {
        let lines = source.components(separatedBy: "\n")
            .enumerated()
            .map { (idx: $0.offset + 1, line: $0.element.trimmingCharacters(in: .whitespaces)) }

        guard let firstIdx = lines.firstIndex(where: { !$0.line.isEmpty }) else {
            throw MermaidError.parse(message: "Empty class diagram source", line: 0)
        }
        let header = lines[firstIdx].line.lowercased()
        guard header == "classdiagram" || header == "classdiagram-v2"
            || header.hasPrefix("classdiagram ") || header.hasPrefix("classdiagram-v2 ") else {
            throw MermaidError.parse(message: "Expected `classDiagram` header", line: lines[firstIdx].idx)
        }

        var ast = ClassDiagramAST(direction: .TB, classes: [:], classOrder: [], relations: [])

        // State for an open `class X { … }` block.
        var blockClassID: String? = nil

        for i in (firstIdx + 1)..<lines.count {
            let entry = lines[i]
            let line = entry.line
            if line.isEmpty { continue }

            // Inside a member block, everything until `}` is a member / annotation line.
            if let cid = blockClassID {
                if line.hasPrefix("}") { blockClassID = nil; continue }
                if line.hasPrefix("<<"), let ann = parseAnnotationToken(line) {
                    setAnnotation(ann, on: cid, in: &ast)
                } else {
                    addMember(line, to: cid, in: &ast)
                }
                continue
            }

            let lower = line.lowercased()

            // `direction LR|RL|TB|BT`
            if lower.hasPrefix("direction ") {
                let v = String(line.dropFirst("direction".count)).trimmingCharacters(in: .whitespaces).uppercased()
                if let d = ClassDirection(rawValue: v) { ast.direction = d }
                continue
            }

            // Statements we recognise but don't render.
            if lower.hasPrefix("note ") || lower.hasPrefix("note\"") || lower == "note"
                || lower.hasPrefix("namespace ") || line == "}"
                || lower.hasPrefix("style ") || lower.hasPrefix("classdef ") || lower.hasPrefix("cssclass ")
                || lower.hasPrefix("click ") || lower.hasPrefix("link ") || lower.hasPrefix("callback ") {
                // `namespace X {` … `}` — we just flatten: the inner `class`/relation lines parse on
                // their own, and the bare `}` line is ignored above.
                continue
            }

            // `class X`, `class X { `, `class X["label"]`, `class X~T~`, `class A, B, C`
            if lower == "class" || lower.hasPrefix("class ") {
                var rest = String(line.dropFirst("class".count)).trimmingCharacters(in: .whitespaces)
                var opensBlock = false
                if rest.hasSuffix("{") {
                    rest = String(rest.dropLast()).trimmingCharacters(in: .whitespaces)
                    opensBlock = true
                }
                if !opensBlock, !rest.contains("["), rest.contains(",") {
                    for part in rest.split(separator: ",") {
                        let (id, display) = parseClassDecl(String(part).trimmingCharacters(in: .whitespaces))
                        if !id.isEmpty { ensureClass(id, display: display, in: &ast) }
                    }
                    continue
                }
                let (id, display) = parseClassDecl(rest)
                guard !id.isEmpty else { continue }
                ensureClass(id, display: display, in: &ast)
                if opensBlock { blockClassID = id }
                continue
            }

            // `<<stereotype>> X`
            if line.hasPrefix("<<") {
                if let (ann, rest) = parseAnnotationWithTarget(line), !rest.isEmpty {
                    let (id, _) = parseClassRef(rest)
                    ensureClass(id, display: nil, in: &ast)
                    setAnnotation(ann, on: id, in: &ast)
                }
                continue
            }

            // Relationship? (contains a `--` / `..` connector, and the line isn't a `X : member`)
            if !looksLikeMemberStatement(line), let rel = parseRelation(line, in: &ast) {
                ast.relations.append(rel)
                continue
            }

            // `X : +member` / `X : +method()` / `X : <<stereotype>>`
            if let colon = firstTopLevelColon(line) {
                let lhs = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let rhs = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                let (id, display) = parseClassRef(lhs)
                guard !id.isEmpty, !rhs.isEmpty else { continue }
                ensureClass(id, display: display, in: &ast)
                if rhs.hasPrefix("<<"), let ann = parseAnnotationToken(rhs) {
                    setAnnotation(ann, on: id, in: &ast)
                } else {
                    addMember(rhs, to: id, in: &ast)
                }
                continue
            }

            // Anything else: lenient — ignore.
        }

        return ast
    }

    // MARK: - Class table helpers

    private static func ensureClass(_ id: String, display: String?, in ast: inout ClassDiagramAST) {
        if ast.classes[id] == nil {
            ast.classes[id] = ClassDef(id: id, name: display ?? id, annotation: nil, members: [], methods: [])
            ast.classOrder.append(id)
        } else if let display, ast.classes[id]?.name == id {
            // A later `class X["label"]` upgrades the display name if it was still the bare id.
            ast.classes[id]?.name = display
        }
    }

    private static func setAnnotation(_ ann: String, on id: String, in ast: inout ClassDiagramAST) {
        ensureClass(id, display: nil, in: &ast)
        ast.classes[id]?.annotation = ann
    }

    private static func addMember(_ raw: String, to id: String, in ast: inout ClassDiagramAST) {
        ensureClass(id, display: nil, in: &ast)
        let text = renderGenerics(raw.trimmingCharacters(in: .whitespaces))
        guard !text.isEmpty else { return }
        let member = ClassMember(text: text, isMethod: text.contains("("))
        if member.isMethod { ast.classes[id]?.methods.append(member) }
        else { ast.classes[id]?.members.append(member) }
    }

    // MARK: - Token parsing

    /// `X`, `X~T~`, `X["display"]`, `X~T~["display"]`, with an optional trailing `:::cssClass`.
    private static func parseClassDecl(_ s: String) -> (id: String, display: String?) {
        var text = stripCssClass(s).trimmingCharacters(in: .whitespaces)
        var display: String? = nil
        // `["display label"]` (also tolerates `[display label]`).
        if let open = text.firstIndex(of: "["), text.hasSuffix("]") {
            var inner = String(text[text.index(after: open)..<text.index(before: text.endIndex)])
            inner = inner.trimmingCharacters(in: .whitespaces)
            if inner.hasPrefix("\"") && inner.hasSuffix("\"") && inner.count >= 2 {
                inner = String(inner.dropFirst().dropLast())
            }
            display = inner
            text = String(text[..<open]).trimmingCharacters(in: .whitespaces)
        }
        let (id, generic) = splitGeneric(text)
        if display == nil, let generic { display = renderGenerics("\(id)~\(generic)~") }
        return (id, display)
    }

    /// A class reference inside a relationship / member statement: `X` or `X~T~`, optional `:::css`.
    private static func parseClassRef(_ s: String) -> (id: String, display: String?) {
        let text = stripCssClass(s).trimmingCharacters(in: .whitespaces)
        let (id, generic) = splitGeneric(text)
        return (id, generic.map { renderGenerics("\(id)~\($0)~") })
    }

    private static func splitGeneric(_ s: String) -> (String, String?) {
        guard let open = s.firstIndex(of: "~") else { return (s, nil) }
        let after = s[s.index(after: open)...]
        guard let close = after.firstIndex(of: "~") else { return (s, nil) }
        return (String(s[..<open]), String(after[..<close]))
    }

    private static func stripCssClass(_ s: String) -> String {
        guard let r = s.range(of: ":::") else { return s }
        return String(s[..<r.lowerBound])
    }

    /// `«X»`-style display for a `~Generic~` parameter list — `Square~Shape~` → `Square<Shape>`.
    static func renderGenerics(_ s: String) -> String {
        guard s.contains("~") else { return s }
        var out = ""
        var open = true
        for ch in s {
            if ch == "~" { out.append(open ? "<" : ">"); open.toggle() }
            else { out.append(ch) }
        }
        return out
    }

    /// `<<interface>>` → `"interface"`. Returns `nil` if the line doesn't open with `<<`.
    private static func parseAnnotationToken(_ s: String) -> String? {
        parseAnnotationWithTarget(s)?.0
    }

    /// `<<interface>> Shape` → `("interface", "Shape")`. The target may be empty.
    private static func parseAnnotationWithTarget(_ s: String) -> (String, String)? {
        guard s.hasPrefix("<<"), let close = s.range(of: ">>") else { return nil }
        let ann = String(s[s.index(s.startIndex, offsetBy: 2)..<close.lowerBound]).trimmingCharacters(in: .whitespaces)
        let rest = String(s[close.upperBound...]).trimmingCharacters(in: .whitespaces)
        return (ann, rest)
    }

    /// `true` if the line is `<ident> : …` (a member statement) rather than a relationship that
    /// happens to carry a `: label`.
    private static func looksLikeMemberStatement(_ line: String) -> Bool {
        guard let colon = firstTopLevelColon(line) else { return false }
        let lhs = line[..<colon].trimmingCharacters(in: .whitespaces)
        // A single identifier-ish token with no relationship connector inside it.
        return !lhs.isEmpty && !lhs.contains(" ") && findConnector(in: lhs) == nil
    }

    /// First `:` that is a real label/member separator (not part of `:::` and not inside quotes).
    private static func firstTopLevelColon(_ line: String) -> String.Index? {
        let chars = Array(line)
        var inQuote = false
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" { inQuote.toggle() }
            else if !inQuote && c == ":" {
                if i + 1 < chars.count && chars[i + 1] == ":" { i += 3; continue }   // skip `:::`
                return line.index(line.startIndex, offsetBy: i)
            }
            i += 1
        }
        return nil
    }

    // MARK: - Relationship parsing

    /// A located connector: index range plus the marker kinds and line style it implies.
    private struct Connector {
        var lo: Int                  // first char of the connector (inclusive)
        var hi: Int                  // one past the last char
        var startKind: ClassRelationKind
        var endKind: ClassRelationKind
        var lineStyle: ClassLineStyle
    }

    private static func findConnector(in line: String) -> Connector? {
        findConnector(in: Array(line))
    }

    private static func findConnector(in chars: [Character]) -> Connector? {
        // Locate the first `--` or `..` run.
        var runStart = -1
        var i = 0
        while i < chars.count - 1 {
            if (chars[i] == "-" && chars[i + 1] == "-") || (chars[i] == "." && chars[i + 1] == ".") {
                runStart = i; break
            }
            i += 1
        }
        guard runStart >= 0 else { return nil }
        let lineChar = chars[runStart]
        var lo = runStart
        while lo - 1 >= 0, chars[lo - 1] == lineChar { lo -= 1 }
        var hi = runStart
        while hi < chars.count, chars[hi] == lineChar { hi += 1 }

        func isSpace(_ idx: Int) -> Bool { idx < 0 || idx >= chars.count || chars[idx] == " " || chars[idx] == "\t" }

        // Left marker (just before `lo`).
        var startKind: ClassRelationKind = .none
        if lo - 2 >= 0, chars[lo - 1] == "|", chars[lo - 2] == "<" { startKind = .extends; lo -= 2 }
        else if lo - 1 >= 0, chars[lo - 1] == "<" { startKind = .association; lo -= 1 }
        else if lo - 1 >= 0, chars[lo - 1] == "*" { startKind = .composition; lo -= 1 }
        else if lo - 1 >= 0, chars[lo - 1] == "o", isSpace(lo - 2) { startKind = .aggregation; lo -= 1 }

        // Right marker (just after `hi`).
        var endKind: ClassRelationKind = .none
        if hi + 1 < chars.count, chars[hi] == "|", chars[hi + 1] == ">" { endKind = .extends; hi += 2 }
        else if hi < chars.count, chars[hi] == ">" { endKind = .association; hi += 1 }
        else if hi < chars.count, chars[hi] == "*" { endKind = .composition; hi += 1 }
        else if hi < chars.count, chars[hi] == "o", isSpace(hi + 1) { endKind = .aggregation; hi += 1 }

        return Connector(lo: lo, hi: hi, startKind: startKind, endKind: endKind,
                         lineStyle: lineChar == "." ? .dashed : .solid)
    }

    private static func parseRelation(_ line: String, in ast: inout ClassDiagramAST) -> ClassRelation? {
        let chars = Array(line)
        guard let conn = findConnector(in: chars) else { return nil }
        let before = String(chars[0..<conn.lo]).trimmingCharacters(in: .whitespaces)
        var after = String(chars[conn.hi...]).trimmingCharacters(in: .whitespaces)
        guard !before.isEmpty, !after.isEmpty else { return nil }

        // `before` = `id1` optionally followed by `"cardinality"`.
        let beforeTokens = tokenizeRespectingQuotes(before)
        guard let id1Tok = beforeTokens.first else { return nil }
        let (id1, _) = parseClassRef(id1Tok)
        guard !id1.isEmpty else { return nil }
        var startCard: String? = nil
        if beforeTokens.count >= 2, let q = unquote(beforeTokens[1]) { startCard = q }

        // `after` = optional `"cardinality"`, then `id2`, then optional `: label`.
        var label: String? = nil
        if let colon = firstTopLevelColon(after) {
            label = String(after[after.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            after = String(after[..<colon]).trimmingCharacters(in: .whitespaces)
        }
        let afterTokens = tokenizeRespectingQuotes(after)
        guard !afterTokens.isEmpty else { return nil }
        var idx = 0
        var endCard: String? = nil
        if let q = unquote(afterTokens[0]) { endCard = q; idx = 1 }
        guard idx < afterTokens.count else { return nil }
        let (id2, _) = parseClassRef(afterTokens[idx])
        guard !id2.isEmpty else { return nil }

        ensureClass(id1, display: nil, in: &ast)
        ensureClass(id2, display: nil, in: &ast)

        return ClassRelation(id1: id1, id2: id2,
                             startKind: conn.startKind, endKind: conn.endKind, lineStyle: conn.lineStyle,
                             label: (label?.isEmpty ?? true) ? nil : label,
                             startCardinality: startCard, endCardinality: endCard)
    }

    /// Whitespace-split, but keep `"…"` runs together (cardinality strings).
    private static func tokenizeRespectingQuotes(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var inQuote = false
        for ch in s {
            if ch == "\"" { inQuote.toggle(); cur.append(ch); continue }
            if !inQuote, ch == " " || ch == "\t" {
                if !cur.isEmpty { out.append(cur); cur = "" }
            } else { cur.append(ch) }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    private static func unquote(_ token: String) -> String? {
        guard token.hasPrefix("\""), token.hasSuffix("\""), token.count >= 2 else { return nil }
        return String(token.dropFirst().dropLast())
    }
}
