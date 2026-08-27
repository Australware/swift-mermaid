import Foundation

/// Hand-written parser for the entity-relationship syntax. The reference grammar is
/// `packages/mermaid/src/diagrams/er/parser/erDiagram.jison`; we cover the common subset —
/// relationships with the four symbolic cardinality tokens on either end, `--` / `..` line styles
/// and `: label`s, entity attribute blocks (`type name PK, FK "comment"`), quoted entity names,
/// `ENTITY[alias]` display names, and `direction`. `accTitle` / `accDescr` / `style` / `classDef`
/// are parse-and-skipped.
///
/// Not covered: the word-alias cardinalities (`one or zero`, `zero or more`, …). The symbolic
/// tokens are what essentially all real-world diagrams use.
enum ERParser {

    static func parse(_ source: String) throws -> ERDiagramAST {
        let lines = source.components(separatedBy: "\n")
            .enumerated()
            .map { (idx: $0.offset + 1, line: $0.element.trimmingCharacters(in: .whitespaces)) }

        guard let firstIdx = lines.firstIndex(where: { !$0.line.isEmpty }) else {
            throw MermaidError.parse(message: "Empty ER diagram source", line: 0)
        }
        let header = lines[firstIdx].line.lowercased()
        guard header == "erdiagram" || header.hasPrefix("erdiagram ") else {
            throw MermaidError.parse(message: "Expected `erDiagram` header", line: lines[firstIdx].idx)
        }

        var ast = ERDiagramAST(direction: .TB, entities: [:], entityOrder: [], relationships: [])

        // Set while an `ENTITY { … }` attribute block is open.
        var blockEntityID: String? = nil

        for i in (firstIdx + 1)..<lines.count {
            let entry = lines[i]
            let line = entry.line
            if line.isEmpty { continue }

            if let eid = blockEntityID {
                if line.hasPrefix("}") { blockEntityID = nil; continue }
                if let attr = parseAttribute(line) {
                    ast.entities[eid]?.attributes.append(attr)
                }
                continue
            }

            let lower = line.lowercased()

            if lower.hasPrefix("direction ") {
                let v = String(line.dropFirst("direction".count)).trimmingCharacters(in: .whitespaces).uppercased()
                if let d = ERDirection(rawValue: v) { ast.direction = d }
                continue
            }

            // Recognised but not rendered.
            if lower.hasPrefix("acctitle") || lower.hasPrefix("accdescr") || lower.hasPrefix("title ")
                || lower.hasPrefix("style ") || lower.hasPrefix("classdef ") || lower.hasPrefix("class ")
                || line == "}" {
                continue
            }

            // Relationship? Detected by a cardinality-flanked `--` / `..` run.
            if let rel = parseRelationship(line, in: &ast) {
                ast.relationships.append(rel)
                continue
            }

            // Otherwise: an entity declaration, optionally opening an attribute block.
            var rest = line
            var opensBlock = false
            if rest.hasSuffix("{") {
                rest = String(rest.dropLast()).trimmingCharacters(in: .whitespaces)
                opensBlock = true
            }
            let (id, alias) = parseEntityRef(rest)
            guard !id.isEmpty else { continue }
            ensureEntity(id, alias: alias, in: &ast)
            if opensBlock { blockEntityID = id }
        }

        return ast
    }

    // MARK: - Entity table helpers

    private static func ensureEntity(_ id: String, alias: String?, in ast: inout ERDiagramAST) {
        if ast.entities[id] == nil {
            ast.entities[id] = EREntity(id: id, name: alias ?? id, attributes: [])
            ast.entityOrder.append(id)
        } else if let alias, ast.entities[id]?.name == id {
            // A later `ENTITY[alias]` upgrades the display name if it was still the bare id.
            ast.entities[id]?.name = alias
        }
    }

    /// `CUSTOMER`, `"Customer Account"`, `CUSTOMER[Customer Account]`, `p["Person"]`.
    private static func parseEntityRef(_ s: String) -> (id: String, alias: String?) {
        var text = s.trimmingCharacters(in: .whitespaces)
        var alias: String? = nil
        if text.hasSuffix("]"), let open = text.firstIndex(of: "[") {
            let inner = String(text[text.index(after: open)..<text.index(before: text.endIndex)])
            alias = unquoteIfNeeded(inner.trimmingCharacters(in: .whitespaces))
            text = String(text[..<open]).trimmingCharacters(in: .whitespaces)
        }
        return (unquoteIfNeeded(text), alias)
    }

    private static func unquoteIfNeeded(_ s: String) -> String {
        guard s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") else { return s }
        return String(s.dropFirst().dropLast())
    }

    // MARK: - Attributes

    /// `string name`, `string(99) name PK`, `int id PK, FK "the comment"`.
    private static func parseAttribute(_ line: String) -> ERAttribute? {
        let tokens = tokenizeRespectingQuotes(line)
        guard tokens.count >= 2 else { return nil }
        let type = tokens[0]
        let name = tokens[1]

        var keys: [String] = []
        var comment: String? = nil
        for token in tokens.dropFirst(2) {
            if token.hasPrefix("\"") {
                comment = unquoteIfNeeded(token)
                continue
            }
            // `PK`, `FK`, `UK`, or a comma-joined run of them (`PK,FK` / `PK, FK` both arrive here
            // as one or two tokens depending on spacing).
            for part in token.split(separator: ",") {
                let key = part.trimmingCharacters(in: .whitespaces).uppercased()
                if key == "PK" || key == "FK" || key == "UK" { keys.append(key) }
            }
        }
        return ERAttribute(type: type, name: name, keys: keys, comment: comment)
    }

    // MARK: - Relationships

    private struct Connector {
        var lo: Int      // index of the first cardinality character
        var hi: Int      // one past the last cardinality character
        var lhs: ERCardinality
        var rhs: ERCardinality
        var lineStyle: ERLineStyle
    }

    /// Scan for a `--` / `..` run flanked by valid cardinality pairs. Scanning every run (rather than
    /// only the first) keeps a `--` inside a relationship label from derailing the match.
    private static func findConnector(in chars: [Character]) -> Connector? {
        var i = 0
        while i < chars.count - 1 {
            let c = chars[i]
            guard (c == "-" || c == ".") && chars[i + 1] == c else { i += 1; continue }
            var hi = i
            while hi < chars.count, chars[hi] == c { hi += 1 }

            if i - 2 >= 0, hi + 1 < chars.count,
               let lhs = lhsCardinality(chars[i - 2], chars[i - 1]),
               let rhs = rhsCardinality(chars[hi], chars[hi + 1]) {
                return Connector(lo: i - 2, hi: hi + 2, lhs: lhs, rhs: rhs,
                                 lineStyle: c == "." ? .nonIdentifying : .identifying)
            }
            i = hi
        }
        return nil
    }

    private static func lhsCardinality(_ a: Character, _ b: Character) -> ERCardinality? {
        switch (a, b) {
        case ("|", "o"): return .zeroOrOne
        case ("|", "|"): return .exactlyOne
        case ("}", "o"): return .zeroOrMore
        case ("}", "|"): return .oneOrMore
        default: return nil
        }
    }

    private static func rhsCardinality(_ a: Character, _ b: Character) -> ERCardinality? {
        switch (a, b) {
        case ("o", "|"): return .zeroOrOne
        case ("|", "|"): return .exactlyOne
        case ("o", "{"): return .zeroOrMore
        case ("|", "{"): return .oneOrMore
        default: return nil
        }
    }

    private static func parseRelationship(_ line: String, in ast: inout ERDiagramAST) -> ERRelationship? {
        let chars = Array(line)
        guard let conn = findConnector(in: chars) else { return nil }
        let before = String(chars[0..<conn.lo]).trimmingCharacters(in: .whitespaces)
        var after = String(chars[conn.hi...]).trimmingCharacters(in: .whitespaces)
        guard !before.isEmpty, !after.isEmpty else { return nil }

        var label: String? = nil
        if let colon = firstTopLevelColon(after) {
            let raw = String(after[after.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            label = unquoteIfNeeded(raw)
            after = String(after[..<colon]).trimmingCharacters(in: .whitespaces)
        }

        let (lhsID, lhsAlias) = parseEntityRef(before)
        let (rhsID, rhsAlias) = parseEntityRef(after)
        guard !lhsID.isEmpty, !rhsID.isEmpty else { return nil }

        ensureEntity(lhsID, alias: lhsAlias, in: &ast)
        ensureEntity(rhsID, alias: rhsAlias, in: &ast)

        return ERRelationship(lhsID: lhsID, rhsID: rhsID,
                              lhsCardinality: conn.lhs, rhsCardinality: conn.rhs,
                              lineStyle: conn.lineStyle,
                              label: (label?.isEmpty ?? true) ? nil : label)
    }

    // MARK: - Small shared lexing helpers

    /// First `:` that isn't inside a quoted run.
    private static func firstTopLevelColon(_ s: String) -> String.Index? {
        var inQuote = false
        for (i, ch) in s.enumerated() {
            if ch == "\"" { inQuote.toggle() }
            else if !inQuote, ch == ":" { return s.index(s.startIndex, offsetBy: i) }
        }
        return nil
    }

    /// Whitespace-split, keeping `"…"` runs together (attribute comments) with their quotes so the
    /// caller can tell a comment from a key token.
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
}
