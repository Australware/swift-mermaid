import Foundation

/// Hand-written parser for `stateDiagram` / `stateDiagram-v2`. The reference grammar is
/// `packages/mermaid/src/diagrams/state/parser/stateDiagram.jison`. Output is a `FlowchartAST`
/// (plus composite-edge bookkeeping) so state diagrams reuse the flowchart layout + renderer:
///
///   - simple states            → round-rect nodes
///   - `[*]`                    → per-scope start / end marker nodes
///   - `<<choice>>`             → small diamond; `<<fork>>` / `<<join>>` → thick bar
///   - `state X { … }`          → subgraph (cluster); transitions touching a composite are
///                                redirected to a leaf inside it and re-clipped after layout
///   - `note left/right of X`   → note node tied to `X` with an invisible edge
///
/// Unsupported syntax (`classDef`, `class`, `style`, `hide empty description`, `:::class`,
/// concurrency `--` separators, …) is parsed-and-skipped, never fatal.
enum StateParser {

    static func parse(_ source: String) throws -> StateDiagram {
        var st = ParserState()
        let lines = source.components(separatedBy: "\n")
        var headerSeen = false

        for (idx, raw) in lines.enumerated() {
            let lineNo = idx + 1
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            // Block-form note body: accumulate until `end note`.
            if st.pendingNote != nil {
                if line.lowercased() == "end note" {
                    st.flushPendingNote()
                } else {
                    st.pendingNote?.lines.append(line)
                }
                continue
            }

            if !headerSeen {
                var scanner = Scanner(string: line)
                let kw = scanner.readIdentifier()?.lowercased()
                guard kw == "statediagram" || kw == "statediagram-v2" else {
                    throw MermaidError.parse(message: "Expected `stateDiagram-v2`", line: lineNo)
                }
                headerSeen = true
                continue
            }

            try parseStatement(line, state: &st, line: lineNo)
        }

        if !headerSeen {
            throw MermaidError.parse(message: "Empty state diagram source", line: 0)
        }
        st.flushPendingNote()                                // unterminated `note … end note`
        while !st.scopeStack.isEmpty { st.scopeStack.removeLast() }   // unclosed composites

        return finalize(st)
    }

    // MARK: - State

    private struct PendingNote {
        var targetID: String?     // nil → discard on flush (unparsable position)
        var side: NoteSide
        var lines: [String]
    }

    private enum NoteSide {
        case left, right
    }

    private struct ParserState {
        var direction: FlowDirection = .TB
        var nodes: [String: FlowNode] = [:]
        var nodeOrder: [String] = []
        var edges: [FlowEdge] = []
        var subgraphs: [String: FlowSubgraph] = [:]
        var subgraphOrder: [String] = []
        /// Stack of composite-state ids currently open (`state X { … }`).
        var scopeStack: [String] = []
        var noteCounter = 0
        var pendingNote: PendingNote? = nil

        var currentScope: String? { scopeStack.last }

        mutating func ensureNode(_ id: String, shape: FlowNodeShape = .roundRect, label: String? = nil) {
            let current = currentScope
            if nodes[id] == nil {
                nodes[id] = FlowNode(id: id, label: label ?? id, shape: shape, subgraphID: current)
                nodeOrder.append(id)
                if let parent = current {
                    subgraphs[parent]?.nodeIDs.append(id)
                }
            }
        }

        /// The scope-local node backing a `[*]` reference. `asSource` picks the start marker,
        /// otherwise the end marker; the same scope reuses the same node.
        mutating func starNode(asSource: Bool) -> String {
            let scope = currentScope ?? ""
            let id = (asSource ? "__start_" : "__end_") + scope
            ensureNode(id, shape: asSource ? .stateStart : .stateEnd, label: "")
            return id
        }

        mutating func appendDescription(_ id: String, _ text: String) {
            ensureNode(id)
            guard let node = nodes[id] else { return }
            nodes[id]?.label = (node.label == id) ? text : node.label + "\n" + text
        }

        mutating func addNote(target: String, side: NoteSide, text: String) {
            guard !text.isEmpty else { return }
            ensureNode(target)
            noteCounter += 1
            let id = "__note\(noteCounter)"
            ensureNode(id, shape: .note, label: text)
            // Invisible edge: places the note on the rank before (left of) or after (right of)
            // its target without drawing a connector.
            let from = side == .left ? id : target
            let to = side == .left ? target : id
            edges.append(FlowEdge(from: from, to: to, kind: .invisible,
                                  arrowStart: .none, arrowEnd: .none, label: nil, length: 1))
        }

        mutating func flushPendingNote() {
            guard let pending = pendingNote else { return }
            pendingNote = nil
            guard let target = pending.targetID else { return }
            addNote(target: target, side: pending.side,
                    text: pending.lines.joined(separator: "\n"))
        }
    }

    // MARK: - Statements

    private static func parseStatement(_ stmt: String, state: inout ParserState, line lineNo: Int) throws {
        var s = stmt
        if s.hasSuffix(";") { s = String(s.dropLast()).trimmingCharacters(in: .whitespaces) }
        if s.isEmpty { return }

        // Close of a composite block. Anything after the `}` is parsed as its own statement.
        if s.hasPrefix("}") {
            if !state.scopeStack.isEmpty { state.scopeStack.removeLast() }
            let rest = String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { try parseStatement(rest, state: &state, line: lineNo) }
            return
        }

        // Concurrency region separator inside a composite — regions aren't rendered separately
        // yet; their states still lay out inside the composite.
        if s == "--" { return }

        let firstWord = s.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)?.lowercased() ?? ""

        // Skip-only directives. `accTitle:` / `accDescr:` keep their colon in the first word.
        let skipWords: Set<String> = ["classdef", "class", "style", "hide", "scale"]
        if skipWords.contains(firstWord) || firstWord.hasPrefix("acctitle") || firstWord.hasPrefix("accdescr") {
            return
        }

        if firstWord == "direction" {
            let parts = s.split(whereSeparator: { $0.isWhitespace })
            if parts.count >= 2, let dir = FlowDirection(rawValue: String(parts[1]).uppercased()) {
                if let current = state.currentScope {
                    state.subgraphs[current]?.direction = dir
                } else {
                    state.direction = dir
                }
            }
            return
        }
        if firstWord == "note" {
            parseNote(s, state: &state)
            return
        }
        if firstWord == "state" {
            try parseStateDecl(s, state: &state, line: lineNo)
            return
        }

        try parseTransitionOrState(s, state: &state, line: lineNo)
    }

    /// `state "desc" as id` | `state id <<choice|fork|join>>` | `state id {` (composite, possibly
    /// with a description/alias form) — with an optional trailing `{` opening a composite block.
    private static func parseStateDecl(_ stmt: String, state: inout ParserState, line lineNo: Int) throws {
        var scanner = Scanner(string: stmt)
        _ = scanner.readIdentifier()          // consume "state"
        scanner.skipSpaces()

        var id: String? = nil
        var label: String? = nil
        var shape: FlowNodeShape = .roundRect

        if scanner.peek() == "\"" {
            label = scanner.readQuotedString()
            scanner.skipSpaces()
            let save = scanner.position
            if scanner.readIdentifier()?.lowercased() == "as" {
                scanner.skipSpaces()
                id = scanner.readIdentifier()
            } else {
                scanner.position = save
            }
        } else {
            id = scanner.readIdentifier()
            scanner.skipSpaces()
            if scanner.peekString("<<") {
                scanner.advance(by: 2)
                var stereo = ""
                while !scanner.isAtEnd, !scanner.peekString(">>") {
                    stereo.append(scanner.peek() ?? " ")
                    scanner.advance()
                }
                if scanner.peekString(">>") { scanner.advance(by: 2) }
                switch stereo.trimmingCharacters(in: .whitespaces).lowercased() {
                case "choice": shape = .stateChoice
                case "fork", "join": shape = .stateForkJoin
                default: break                       // unknown stereotype → plain state
                }
                if shape != .roundRect { label = "" }
            }
        }

        guard let id else { return }          // `state "text"` with no alias — nothing to anchor
        scanner.skipSpaces()

        if scanner.peek() == "{" {
            // Composite state → subgraph. A node with the same id may already exist from an
            // earlier transition; `finalize` migrates it.
            scanner.advance()
            if state.subgraphs[id] == nil {
                state.subgraphs[id] = FlowSubgraph(id: id, title: label ?? id,
                                                   nodeIDs: [], childSubgraphIDs: [],
                                                   parentID: state.currentScope, direction: nil)
                state.subgraphOrder.append(id)
                if let parent = state.currentScope {
                    state.subgraphs[parent]?.childSubgraphIDs.append(id)
                }
            }
            state.scopeStack.append(id)
            let rest = scanner.remaining.trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { try parseStatement(rest, state: &state, line: lineNo) }
            return
        }

        state.ensureNode(id, shape: shape, label: label)
        // Re-declaration of a node created earlier (e.g. by a transition): upgrade in place.
        if let existing = state.nodes[id], existing.shape == .roundRect {
            if shape != .roundRect {
                state.nodes[id]?.shape = shape
                state.nodes[id]?.label = label ?? ""
            } else if let label, existing.label == id {
                state.nodes[id]?.label = label
            }
        }
    }

    /// `note right of X : text` (inline) or `note left of X` … `end note` (block).
    private static func parseNote(_ stmt: String, state: inout ParserState) {
        var scanner = Scanner(string: stmt)
        _ = scanner.readIdentifier()          // consume "note"
        scanner.skipSpaces()
        let sideWord = scanner.readIdentifier()?.lowercased()
        scanner.skipSpaces()
        let ofWord = scanner.readIdentifier()?.lowercased()
        guard let sideWord, ofWord == "of",
              let side: NoteSide = sideWord == "left" ? .left : (sideWord == "right" ? .right : nil) else {
            // Unrecognised form (e.g. `note on link`). If it has no inline `:`, swallow the block.
            if !stmt.contains(":") {
                state.pendingNote = PendingNote(targetID: nil, side: .right, lines: [])
            }
            return
        }
        scanner.skipSpaces()
        guard let target = scanner.readIdentifier() else { return }
        scanner.skipSpaces()
        if scanner.peek() == ":" {
            scanner.advance()
            let text = scanner.remaining.trimmingCharacters(in: .whitespaces)
            state.addNote(target: target, side: side, text: text)
        } else {
            state.pendingNote = PendingNote(targetID: target, side: side, lines: [])
        }
    }

    /// `A --> B`, `A --> B : label`, `[*] --> A`, `A --> [*]`, a bare state id, or `A : description`.
    private static func parseTransitionOrState(_ stmt: String, state: inout ParserState, line lineNo: Int) throws {
        var scanner = Scanner(string: stmt)
        guard let lhs = readRef(&scanner) else { return }   // tolerate unknown lines

        scanner.skipSpaces()
        if scanner.peekString("-->") {
            scanner.advance(by: 3)
            scanner.skipSpaces()
            guard let rhs = readRef(&scanner) else {
                throw MermaidError.parse(message: "Transition has no destination", line: lineNo)
            }
            var label: String? = nil
            scanner.skipSpaces()
            if scanner.peek() == ":" {
                scanner.advance()
                let text = scanner.remaining.trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { label = text }
            }
            let from: String
            let to: String
            switch lhs {
            case .star: from = state.starNode(asSource: true)
            case .id(let id): state.ensureNode(id); from = id
            }
            switch rhs {
            case .star: to = state.starNode(asSource: false)
            case .id(let id): state.ensureNode(id); to = id
            }
            state.edges.append(FlowEdge(from: from, to: to, kind: .solid,
                                        arrowStart: .none, arrowEnd: .arrow,
                                        label: label, length: 1))
            return
        }

        // `A : description` or a bare declaration.
        guard case .id(let id) = lhs else { return }        // a lone `[*]` means nothing
        if scanner.peek() == ":" {
            scanner.advance()
            let text = scanner.remaining.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { state.appendDescription(id, text) }
        } else {
            state.ensureNode(id)
        }
    }

    private enum Ref {
        case star            // [*]
        case id(String)
    }

    private static func readRef(_ scanner: inout Scanner) -> Ref? {
        scanner.skipSpaces()
        if scanner.peekString("[*]") {
            scanner.advance(by: 3)
            return .star
        }
        guard let id = scanner.readIdentifier() else { return nil }
        // Strip `:::className` shorthand.
        if scanner.peekString(":::") {
            scanner.advance(by: 3)
            _ = scanner.readIdentifier()
        }
        return .id(id)
    }

    // MARK: - Finalize

    /// Resolve composite states: drop shadow nodes that turned out to be composites, and redirect
    /// edges touching a composite to a representative leaf inside it (remembered for post-layout
    /// re-clipping to the cluster border).
    private static func finalize(_ st: ParserState) -> StateDiagram {
        var st = st

        for sgID in st.subgraphOrder {
            guard let shadow = st.nodes[sgID] else { continue }
            // A colon-description on the composite becomes its title.
            if shadow.label != sgID, st.subgraphs[sgID]?.title == sgID {
                st.subgraphs[sgID]?.title = shadow.label
            }
            st.nodes[sgID] = nil
            st.nodeOrder.removeAll { $0 == sgID }
            for key in st.subgraphs.keys {
                st.subgraphs[key]?.nodeIDs.removeAll { $0 == sgID }
            }
        }

        func representative(_ sgID: String) -> String? {
            guard let sg = st.subgraphs[sgID] else { return nil }
            if let first = sg.nodeIDs.first { return first }
            for child in sg.childSubgraphIDs {
                if let rep = representative(child) { return rep }
            }
            return nil
        }

        var compositeEnds: [StateEdgeKey: StateCompositeEnds] = [:]
        var edges: [FlowEdge] = []
        edges.reserveCapacity(st.edges.count)
        for var edge in st.edges {
            var ends = StateCompositeEnds(fromComposite: nil, toComposite: nil)
            if st.subgraphs[edge.from] != nil {
                guard let rep = representative(edge.from) else { continue }   // empty composite
                ends.fromComposite = edge.from
                edge.from = rep
            }
            if st.subgraphs[edge.to] != nil {
                guard let rep = representative(edge.to) else { continue }
                ends.toComposite = edge.to
                edge.to = rep
            }
            if ends.fromComposite != nil || ends.toComposite != nil {
                compositeEnds[StateEdgeKey(from: edge.from, to: edge.to)] = ends
            }
            edges.append(edge)
        }

        let ast = FlowchartAST(direction: st.direction,
                               nodes: st.nodes,
                               nodeOrder: st.nodeOrder,
                               edges: edges,
                               subgraphs: st.subgraphs,
                               subgraphOrder: st.subgraphOrder)
        return StateDiagram(ast: ast, compositeEnds: compositeEnds)
    }
}
