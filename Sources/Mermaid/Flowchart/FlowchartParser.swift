import Foundation

/// Hand-written recursive-descent parser for the flowchart / graph syntax. The reference grammar is
/// `packages/mermaid/src/diagrams/flowchart/parser/flow.jison`; we cover the v1 subset listed in §7 of
/// the spec and `parse-and-skip` anything else rather than bailing.
enum FlowchartParser {

    static func parse(_ source: String) throws -> FlowchartAST {
        var state = ParserState()
        let rawLines = source.components(separatedBy: "\n")
        var i = 0
        // Header: first non-empty significant line. Anything before it is allowed (blank, eaten
        // directives) — but the very first significant token must be `flowchart` or `graph`.
        var headerSeen = false

        while i < rawLines.count {
            // Multi-line `subgraph ... end` blocks are handled within the line loop.
            // We also need to support multiple statements separated by `;` on one line.
            let lineNumber = i + 1
            let lineRaw = rawLines[i]
            i += 1

            // Drop trailing comments (`%% ...`) per-line. Mermaid only allows %% at line start, but
            // tolerating trailing comments is harmless.
            let line = stripTrailingComment(lineRaw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            // Split on `;` at top level (outside brackets/quotes) — multiple statements per line.
            let statements = splitTopLevel(line, separator: ";")
            for stmt in statements {
                let s = stmt.trimmingCharacters(in: .whitespaces)
                if s.isEmpty { continue }

                if !headerSeen {
                    try parseHeader(s, state: &state, line: lineNumber)
                    headerSeen = true
                    continue
                }
                try parseStatement(s, state: &state, line: lineNumber)
            }
        }

        if !headerSeen {
            throw MermaidError.parse(message: "Empty flowchart source", line: 0)
        }

        // Close any unclosed subgraphs silently (Mermaid throws — we're tolerant).
        while !state.subgraphStack.isEmpty { state.subgraphStack.removeLast() }

        return FlowchartAST(
            direction: state.direction,
            nodes: state.nodes,
            nodeOrder: state.nodeOrder,
            edges: state.edges,
            subgraphs: state.subgraphs,
            subgraphOrder: state.subgraphOrder
        )
    }

    // MARK: - State

    private struct ParserState {
        var direction: FlowDirection = .TB
        var nodes: [String: FlowNode] = [:]
        var nodeOrder: [String] = []
        var edges: [FlowEdge] = []
        var subgraphs: [String: FlowSubgraph] = [:]
        var subgraphOrder: [String] = []
        var subgraphStack: [String] = []
        var subgraphAutoCounter: Int = 0

        var currentSubgraph: String? { subgraphStack.last }

        mutating func ensureNode(_ id: String) {
            // Copy `currentSubgraph` first so we don't have overlapping reads/writes on `self`.
            let current = currentSubgraph
            if nodes[id] == nil {
                nodes[id] = FlowNode(id: id, label: id, shape: .rect, subgraphID: current)
                nodeOrder.append(id)
                if let parent = current {
                    subgraphs[parent]?.nodeIDs.append(id)
                }
            } else if let current, nodes[id]?.subgraphID == nil {
                nodes[id]?.subgraphID = current
                subgraphs[current]?.nodeIDs.append(id)
            }
        }

        mutating func setShape(_ id: String, shape: FlowNodeShape, label: String) {
            ensureNode(id)
            // First non-default shape definition wins. Subsequent references with only an ID don't
            // overwrite an already-set label.
            if nodes[id]?.shape == .rect, nodes[id]?.label == id {
                nodes[id]?.shape = shape
                nodes[id]?.label = label
            } else if !label.isEmpty, nodes[id]?.label == id {
                nodes[id]?.label = label
            }
        }
    }

    // MARK: - Header

    private static func parseHeader(_ line: String, state: inout ParserState, line lineNo: Int) throws {
        var scanner = Scanner(string: line)
        guard let kw = scanner.readIdentifier()?.lowercased() else {
            throw MermaidError.parse(message: "Expected `flowchart` or `graph`", line: lineNo)
        }
        guard kw == "flowchart" || kw == "graph" || kw == "flowchart-elk" else {
            throw MermaidError.parse(message: "Expected `flowchart` or `graph`, got `\(kw)`", line: lineNo)
        }
        scanner.skipSpaces()
        if let dirToken = scanner.readIdentifier() {
            state.direction = FlowDirection(rawValue: dirToken.uppercased()) ?? state.direction
        }
        scanner.skipSpaces()
        // After the direction may come a `;` and the first statement; the caller already split.
        let rest = scanner.remaining.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty {
            try parseStatement(rest, state: &state, line: lineNo)
        }
    }

    // MARK: - Statements

    private static func parseStatement(_ stmt: String, state: inout ParserState, line lineNo: Int) throws {
        // Strip `:::class` shorthand from the end of a node ref / line (parse-and-skip).
        var s = stmt

        // Skip-only directives.
        let firstWord = s.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)?.lowercased() ?? ""
        let skipKeywords: Set<String> = [
            "classdef", "class", "style", "linkstyle", "click",
            "acctitle", "accdescr", "default", "interpolate"
        ]
        if skipKeywords.contains(firstWord) { return }

        // subgraph / end / direction
        if firstWord == "subgraph" {
            try parseSubgraphHeader(s, state: &state, line: lineNo)
            return
        }
        if firstWord == "end" {
            if let id = state.subgraphStack.popLast() {
                // Attach to parent's child list now that we know its boundary.
                if let parent = state.subgraphStack.last {
                    state.subgraphs[parent]?.childSubgraphIDs.append(id)
                    state.subgraphs[id]?.parentID = parent
                }
            }
            return
        }
        if firstWord == "direction" {
            let parts = s.split(whereSeparator: { $0.isWhitespace })
            if parts.count >= 2, let dir = FlowDirection(rawValue: String(parts[1]).uppercased()) {
                if let current = state.currentSubgraph {
                    state.subgraphs[current]?.direction = dir
                } else {
                    state.direction = dir
                }
            }
            return
        }

        // Strip `:::className` shorthand wherever it appears.
        s = stripTripleColonClass(s)

        try parseEdgeChain(s, state: &state, line: lineNo)
    }

    private static func parseSubgraphHeader(_ stmt: String, state: inout ParserState, line lineNo: Int) throws {
        // Forms:
        //   subgraph id
        //   subgraph id [Title]
        //   subgraph "Title"
        //   subgraph id ["Long title"]
        var scanner = Scanner(string: stmt)
        _ = scanner.readIdentifier()    // consume "subgraph"
        scanner.skipSpaces()

        var id: String? = nil
        var title: String? = nil

        // Quoted title-only form: `subgraph "Title"`.
        if scanner.peek() == "\"" {
            title = scanner.readQuotedString()
        } else {
            id = scanner.readIdentifier()
            scanner.skipSpaces()
            if scanner.peek() == "[" {
                let (_, text) = scanner.readBracketGroup() ?? (.rect, "")
                title = text
            } else if scanner.peek() == "\"" {
                title = scanner.readQuotedString()
            }
        }

        let assignedID: String
        if let id { assignedID = id } else {
            state.subgraphAutoCounter += 1
            assignedID = "__subgraph\(state.subgraphAutoCounter)"
        }
        if state.subgraphs[assignedID] == nil {
            state.subgraphs[assignedID] = FlowSubgraph(id: assignedID, title: title ?? id,
                                                       nodeIDs: [], childSubgraphIDs: [],
                                                       parentID: state.currentSubgraph,
                                                       direction: nil)
            state.subgraphOrder.append(assignedID)
        }
        state.subgraphStack.append(assignedID)
    }

    // MARK: - Edge chain `A --> B --> C`, with `&` fan-in/out.

    private static func parseEdgeChain(_ stmt: String, state: inout ParserState, line lineNo: Int) throws {
        var scanner = Scanner(string: stmt)
        // Each "ref group" is one or more node refs joined by `&`.
        guard let leftGroup = try parseNodeGroup(&scanner, state: &state, line: lineNo) else { return }

        var previousGroup: [String] = leftGroup
        // After the first group, look for an edge. If absent, this is a node-only statement.
        while true {
            scanner.skipSpaces()
            if scanner.isAtEnd { break }
            guard let edge = parseEdgeToken(&scanner) else {
                // Unknown trailing content — be tolerant and stop.
                break
            }
            scanner.skipSpaces()
            guard let rightGroup = try parseNodeGroup(&scanner, state: &state, line: lineNo) else {
                throw MermaidError.parse(message: "Edge has no destination", line: lineNo)
            }
            for from in previousGroup {
                for to in rightGroup {
                    state.edges.append(FlowEdge(
                        from: from, to: to,
                        kind: edge.kind,
                        arrowStart: edge.arrowStart,
                        arrowEnd: edge.arrowEnd,
                        label: edge.label,
                        length: edge.length
                    ))
                }
            }
            previousGroup = rightGroup
        }
    }

    /// A node group: one or more node refs joined by `&`.
    private static func parseNodeGroup(_ scanner: inout Scanner, state: inout ParserState, line lineNo: Int) throws -> [String]? {
        var ids: [String] = []
        scanner.skipSpaces()
        guard let first = try parseNodeRef(&scanner, state: &state, line: lineNo) else { return nil }
        ids.append(first)
        while true {
            let save = scanner.position
            scanner.skipSpaces()
            if scanner.peek() == "&" {
                scanner.advance()
                scanner.skipSpaces()
                guard let next = try parseNodeRef(&scanner, state: &state, line: lineNo) else {
                    scanner.position = save
                    break
                }
                ids.append(next)
            } else {
                scanner.position = save
                break
            }
        }
        return ids
    }

    /// A single node ref: an identifier optionally followed by a shape group.
    private static func parseNodeRef(_ scanner: inout Scanner, state: inout ParserState, line lineNo: Int) throws -> String? {
        scanner.skipSpaces()
        guard let id = scanner.readIdentifier() else { return nil }
        state.ensureNode(id)
        if let (shape, text) = scanner.readBracketGroup() {
            state.setShape(id, shape: shape, label: text)
        }
        // Skip any trailing `:::className` shorthand.
        if scanner.peekString(":::") {
            scanner.advance(by: 3)
            _ = scanner.readIdentifier()
        }
        return id
    }

    // MARK: - Edge tokeniser

    private struct EdgeMatch {
        var kind: FlowEdgeKind
        var arrowStart: FlowArrow
        var arrowEnd: FlowArrow
        var length: Int
        var label: String?
    }

    /// Recognises `-->`, `---`, `-.->`, `==>`, `--o`, `--x`, `<-->`, with optional inline label
    /// (`-- text -->`, `-. text .->`, `== text ==>`) and pipe label (`-->|text|`).
    private static func parseEdgeToken(_ scanner: inout Scanner) -> EdgeMatch? {
        let start = scanner.position
        // First half: optional arrow start, then a run that starts a known operator.
        guard let firstHalf = readEdgeHalf(&scanner, isStart: true) else {
            scanner.position = start
            return nil
        }
        // If `firstHalf` ends with a terminator (>, o, x), the edge is complete (no inline label).
        if firstHalf.endsWithTerminator {
            // Optional pipe label right after.
            let label = readPipeLabel(&scanner)
            return EdgeMatch(kind: firstHalf.kind,
                             arrowStart: firstHalf.arrowStart,
                             arrowEnd: firstHalf.arrowEnd,
                             length: firstHalf.length,
                             label: label)
        }
        // Otherwise it might be the leading half of an inline-label form: `--`, `==`, `-.`.
        // Skip whitespace, read the label (a run of non-edge characters), then the closing half.
        let labelStart = scanner.position
        scanner.skipSpaces()
        let labelText = scanner.readUntilEdgeSecondHalf()
        scanner.skipSpaces()
        guard let secondHalf = readEdgeHalf(&scanner, isStart: false) else {
            // Wasn't an inline-label edge — could be a `---` plain open. Re-check firstHalf: if it
            // is a valid open edge on its own, accept it.
            scanner.position = labelStart
            if firstHalf.kind == .solid && firstHalf.length >= 1 && firstHalf.arrowEnd == .none && firstHalf.arrowStart == .none {
                let label = readPipeLabel(&scanner)
                return EdgeMatch(kind: firstHalf.kind,
                                 arrowStart: .none, arrowEnd: .none,
                                 length: firstHalf.length, label: label)
            }
            scanner.position = start
            return nil
        }
        // Inline label form: combine halves. Length is the larger of the two halves' lengths.
        return EdgeMatch(kind: firstHalf.kind,
                         arrowStart: firstHalf.arrowStart,
                         arrowEnd: secondHalf.arrowEnd,
                         length: max(firstHalf.length, secondHalf.length),
                         label: labelText.isEmpty ? nil : labelText)
    }

    private struct EdgeHalf {
        var kind: FlowEdgeKind
        var arrowStart: FlowArrow
        var arrowEnd: FlowArrow
        var length: Int
        var endsWithTerminator: Bool
    }

    private static func readEdgeHalf(_ scanner: inout Scanner, isStart: Bool) -> EdgeHalf? {
        let save = scanner.position
        var arrowStart: FlowArrow = .none
        var arrowEnd: FlowArrow = .none
        // Optional start arrow `<` (only when at the very beginning).
        if isStart, scanner.peek() == "<" {
            arrowStart = .arrow
            scanner.advance()
        }
        // Determine kind from the body character.
        let c = scanner.peek()
        var kind: FlowEdgeKind
        if c == "-" {
            // Could be solid or dotted depending on what follows.
            // Look ahead: dashes, then possibly dots, then dashes/end.
            // Try dotted first: `-` `.`+ `-`? (the second half pattern is `.`+ `-`)
            kind = .solid
        } else if c == "=" {
            kind = .thick
        } else {
            scanner.position = save
            return nil
        }

        var totalDashes = 0      // count of `-` characters (or `=` for thick)
        var totalDots = 0
        let bodyChar: Character = (kind == .thick) ? "=" : "-"

        // Read the body. For solid/thick: a run of bodyChars, possibly interrupted by `.`s for dotted.
        // We allow at most one interior dot-run.
        var sawDot = false
        while true {
            let ch = scanner.peek()
            if ch == bodyChar {
                totalDashes += 1
                scanner.advance()
            } else if ch == "." && kind != .thick {
                kind = .dotted
                sawDot = true
                totalDots += 1
                scanner.advance()
            } else {
                break
            }
        }

        if totalDashes == 0 && !sawDot {
            scanner.position = save
            return nil
        }
        // Need at least two body characters (e.g. `--`, `==`, `-.`) to count as an edge half/edge.
        if totalDashes + totalDots < 2 {
            scanner.position = save
            return nil
        }

        // Optional end terminator: `>`, `o`, `x`.
        var endsWithTerminator = false
        switch scanner.peek() {
        case ">": arrowEnd = .arrow; scanner.advance(); endsWithTerminator = true
        case "o": arrowEnd = .circle; scanner.advance(); endsWithTerminator = true
        case "x": arrowEnd = .cross; scanner.advance(); endsWithTerminator = true
        default: break
        }

        // The next char must be whitespace or non-identifier — otherwise we mis-parsed.
        let after = scanner.peek()
        if let a = after, !a.isWhitespace, a != "|", !endsWithTerminator {
            // Could be the leading part of an inline label form — that's OK if length > 0 dashes.
            // We only reject if the run was just a single `-` followed by an identifier (e.g. "A-B").
        }

        // Length calculation (Mermaid convention):
        //  - dotted: length = number of dots
        //  - solid arrow `-->`: length = dashes - 1
        //  - solid open `---`: length = dashes - 2
        //  - thick mirrors solid
        let length: Int
        switch kind {
        case .dotted:
            length = max(1, totalDots)
        case .solid, .thick:
            if endsWithTerminator {
                length = max(1, totalDashes - 1)
            } else {
                length = max(1, totalDashes - 2)
            }
        }

        return EdgeHalf(kind: kind, arrowStart: arrowStart, arrowEnd: arrowEnd,
                        length: length, endsWithTerminator: endsWithTerminator)
    }

    private static func readPipeLabel(_ scanner: inout Scanner) -> String? {
        let save = scanner.position
        scanner.skipSpaces()
        guard scanner.peek() == "|" else { scanner.position = save; return nil }
        scanner.advance()
        var out = ""
        while !scanner.isAtEnd, let ch = scanner.peek(), ch != "|" {
            out.append(ch)
            scanner.advance()
        }
        if scanner.peek() == "|" { scanner.advance() }
        return out.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Helpers

    private static func stripTrailingComment(_ line: String) -> String {
        // `%% ...` comments: only honoured at start-of-line per Mermaid. Preprocessing already
        // removed those. But we also tolerate a stray `%%` mid-line in case the source authored it.
        if let r = line.range(of: " %%") { return String(line[..<r.lowerBound]) }
        return line
    }

    private static func splitTopLevel(_ s: String, separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var depthRound = 0, depthSquare = 0, depthBrace = 0
        var inQuotes = false
        for ch in s {
            if ch == "\"" { inQuotes.toggle(); current.append(ch); continue }
            if !inQuotes {
                switch ch {
                case "(": depthRound += 1
                case ")": depthRound = max(0, depthRound - 1)
                case "[": depthSquare += 1
                case "]": depthSquare = max(0, depthSquare - 1)
                case "{": depthBrace += 1
                case "}": depthBrace = max(0, depthBrace - 1)
                default: break
                }
                if ch == separator, depthRound == 0, depthSquare == 0, depthBrace == 0 {
                    parts.append(current)
                    current = ""
                    continue
                }
            }
            current.append(ch)
        }
        parts.append(current)
        return parts
    }

    private static func stripTripleColonClass(_ s: String) -> String {
        guard let range = s.range(of: ":::") else { return s }
        // Erase from ":::" up to the next whitespace or end.
        var result = String(s[..<range.lowerBound])
        let tail = s[range.upperBound...]
        if let wsIdx = tail.firstIndex(where: { $0.isWhitespace }) {
            result.append(contentsOf: tail[wsIdx...])
        }
        return result
    }
}
