import Foundation

/// Hand-written parser for `architecture-beta`. Reference: Mermaid's `architecture` diagram grammar
/// (`packages/mermaid/src/diagrams/architecture/architecture.jison`). We cover groups, services,
/// junctions, and edges (with side specifiers, arrowheads, and the `{group}` boundary marker), and
/// parse-and-skip anything else.
enum ArchitectureParser {

    static func parse(_ source: String) throws -> ArchitectureAST {
        let lines = source.components(separatedBy: "\n")
            .enumerated()
            .map { (idx: $0.offset + 1, text: $0.element.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.text.isEmpty }

        guard let header = lines.first?.text.lowercased(),
              header == "architecture-beta" || header == "architecture" else {
            throw MermaidError.parse(message: "Expected `architecture-beta` header",
                                     line: lines.first?.idx ?? 0)
        }

        var ast = ArchitectureAST()

        for entry in lines.dropFirst() {
            let line = entry.text
            let lower = line.lowercased()

            if lower.hasPrefix("group ") {
                try parseGroup(String(line.dropFirst(6)), lineNo: entry.idx, ast: &ast)
            } else if lower.hasPrefix("service ") {
                try parseService(String(line.dropFirst(8)), lineNo: entry.idx, ast: &ast, junction: false)
            } else if lower.hasPrefix("junction ") {
                try parseService(String(line.dropFirst(9)), lineNo: entry.idx, ast: &ast, junction: true)
            } else if let edge = try parseEdge(line, lineNo: entry.idx) {
                ast.edges.append(edge)
            }
            // else: unrecognised line — parse-and-skip.
        }

        if ast.isEmpty {
            throw MermaidError.parse(message: "Architecture diagram has no services or groups", line: 0)
        }
        return ast
    }

    // MARK: - Declarations

    /// `group {id}(icon)[title]` optionally `in {parent}`. Icon/title both optional in practice.
    private static func parseGroup(_ rest: String, lineNo: Int, ast: inout ArchitectureAST) throws {
        var sc = Scanner(string: rest)
        sc.skipSpaces()
        guard let id = sc.readIdentifier() else {
            throw MermaidError.parse(message: "`group` requires an id", line: lineNo)
        }
        let (icon, title) = readIconAndTitle(&sc, defaultTitle: id)
        let parent = readInClause(&sc)
        if ast.groups[id] == nil {
            ast.groups[id] = ArchGroup(id: id, title: title, icon: icon, parentID: parent)
            ast.groupOrder.append(id)
        }
    }

    /// `service {id}(icon)[title]` optionally `in {parent}`. For junctions there's no icon/title.
    private static func parseService(_ rest: String, lineNo: Int, ast: inout ArchitectureAST, junction: Bool) throws {
        var sc = Scanner(string: rest)
        sc.skipSpaces()
        guard let id = sc.readIdentifier() else {
            throw MermaidError.parse(message: "`\(junction ? "junction" : "service")` requires an id", line: lineNo)
        }
        let icon: ArchIcon
        let title: String
        if junction {
            icon = .generic
            title = ""
        } else {
            (icon, title) = readIconAndTitle(&sc, defaultTitle: id)
        }
        let parent = readInClause(&sc)
        if ast.services[id] == nil {
            ast.services[id] = ArchService(id: id, title: title, icon: icon,
                                           groupID: parent, isJunction: junction)
            ast.serviceOrder.append(id)
        }
    }

    /// Reads `(icon)[title]` (either or both may be absent) from the scanner.
    private static func readIconAndTitle(_ sc: inout Scanner, defaultTitle: String) -> (ArchIcon, String) {
        var icon: ArchIcon = .generic
        var title = defaultTitle
        // (icon)  — may be `(database)` or `("aws:lambda")`; custom packs → generic.
        sc.skipSpaces()
        if sc.peek() == "(" {
            sc.advance()
            var raw = ""
            while let ch = sc.peek(), ch != ")" { raw.append(ch); sc.advance() }
            if sc.peek() == ")" { sc.advance() }
            raw = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            icon = raw.contains(":") ? .generic : ArchIcon(name: raw)
        }
        // [title]
        sc.skipSpaces()
        if sc.peek() == "[" {
            sc.advance()
            var raw = ""
            while let ch = sc.peek(), ch != "]" { raw.append(ch); sc.advance() }
            if sc.peek() == "]" { sc.advance() }
            title = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        }
        return (icon, title)
    }

    /// Reads a trailing `in {parent}` clause if present.
    private static func readInClause(_ sc: inout Scanner) -> String? {
        sc.skipSpaces()
        guard sc.peekString("in ") || sc.peekString("in\t") else { return nil }
        sc.advance(by: 2)
        sc.skipSpaces()
        return sc.readIdentifier()
    }

    // MARK: - Edges

    /// `{id}{group}?:{side} {arrow} {side}:{id}{group}?` — e.g. `db:L -- R:server`,
    /// `server{group}:B --> T:subnet{group}`. Returns nil if the line isn't an edge.
    private static func parseEdge(_ line: String, lineNo: Int) throws -> ArchEdge? {
        var sc = Scanner(string: line)
        sc.skipSpaces()
        guard let lhs = readEdgeEnd(&sc, sideAfterColon: true) else { return nil }
        sc.skipSpaces()
        guard let arrow = readArrow(&sc) else { return nil }
        sc.skipSpaces()
        guard let rhs = readEdgeEnd(&sc, sideAfterColon: false) else {
            throw MermaidError.parse(message: "Architecture edge is missing its right-hand side", line: lineNo)
        }
        return ArchEdge(lhs: lhs, rhs: rhs, arrowLhs: arrow.lhs, arrowRhs: arrow.rhs)
    }

    /// Two endpoint shapes: lhs is `id{group}?:side`, rhs is `side:id{group}?`.
    private static func readEdgeEnd(_ sc: inout Scanner, sideAfterColon: Bool) -> ArchEdgeEnd? {
        if sideAfterColon {
            guard let id = sc.readIdentifier() else { return nil }
            var viaGroup = false
            if sc.peekString("{group}") { sc.advance(by: 7); viaGroup = true }
            guard sc.peek() == ":" else { return nil }
            sc.advance()
            guard let side = readSide(&sc) else { return nil }
            return ArchEdgeEnd(id: id, side: side, viaGroup: viaGroup)
        } else {
            guard let side = readSide(&sc) else { return nil }
            guard sc.peek() == ":" else { return nil }
            sc.advance()
            guard let id = sc.readIdentifier() else { return nil }
            var viaGroup = false
            if sc.peekString("{group}") { sc.advance(by: 7); viaGroup = true }
            return ArchEdgeEnd(id: id, side: side, viaGroup: viaGroup)
        }
    }

    private static func readSide(_ sc: inout Scanner) -> ArchSide? {
        guard let ch = sc.peek() else { return nil }
        let s = String(ch).uppercased()
        guard let side = ArchSide(rawValue: s) else { return nil }
        sc.advance()
        return side
    }

    /// `--`, `-->`, `<--`, `<-->` (any number of interior dashes).
    private static func readArrow(_ sc: inout Scanner) -> (lhs: Bool, rhs: Bool)? {
        let save = sc.position
        var lhs = false
        if sc.peek() == "<" { lhs = true; sc.advance() }
        var dashes = 0
        while sc.peek() == "-" { dashes += 1; sc.advance() }
        guard dashes >= 1 else { sc.position = save; return nil }
        var rhs = false
        if sc.peek() == ">" { rhs = true; sc.advance() }
        // `--` with no arrows still needs at least 2 dashes to avoid eating stray hyphens.
        if !lhs && !rhs && dashes < 2 { sc.position = save; return nil }
        return (lhs, rhs)
    }
}
