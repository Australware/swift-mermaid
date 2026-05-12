import Foundation

enum SequenceParser {

    static func parse(_ source: String) throws -> SequenceAST {
        let lines = source.components(separatedBy: "\n").enumerated()
            .map { (idx: $0.offset + 1, raw: $0.element) }
            .filter { !$0.raw.trimmingCharacters(in: .whitespaces).isEmpty }

        guard let firstIdx = lines.firstIndex(where: { !$0.raw.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            throw MermaidError.parse(message: "Empty sequence diagram", line: 0)
        }
        let header = lines[firstIdx].raw.trimmingCharacters(in: .whitespaces)
        guard header.lowercased() == "sequencediagram" else {
            throw MermaidError.parse(message: "Expected `sequenceDiagram` header", line: lines[firstIdx].idx)
        }

        var ast = SequenceAST(actors: [], actorIndex: [:], statements: [], autonumber: false)
        var groupStack: [GroupFrame] = []

        // Drop everything up to and including the header.
        var pos = firstIdx + 1

        while pos < lines.count {
            let entry = lines[pos]
            pos += 1
            let line = entry.raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            try handleLine(line, lineNo: entry.idx, ast: &ast, groupStack: &groupStack)
        }

        // Flush any unclosed groups silently.
        while !groupStack.isEmpty {
            let top = groupStack.removeLast()
            appendStatement(top.toStatement(), to: &ast, in: &groupStack)
        }
        return ast
    }

    // MARK: - Group bookkeeping

    private enum GroupKind {
        case loop, opt
        case alt(branches: [(label: String, body: [SequenceStatement])])
        case par(branches: [(label: String, body: [SequenceStatement])])
    }

    private struct GroupFrame {
        var kind: GroupKind
        var currentLabel: String
        var currentBody: [SequenceStatement]

        func toStatement() -> SequenceStatement {
            switch kind {
            case .loop:
                return .loop(label: currentLabel, body: currentBody)
            case .opt:
                return .opt(label: currentLabel, body: currentBody)
            case .alt(let branches):
                return .alt(branches: branches + [(currentLabel, currentBody)])
            case .par(let branches):
                return .par(branches: branches + [(currentLabel, currentBody)])
            }
        }
    }

    private static func appendStatement(_ s: SequenceStatement, to ast: inout SequenceAST, in stack: inout [GroupFrame]) {
        if !stack.isEmpty {
            stack[stack.count - 1].currentBody.append(s)
        } else {
            ast.statements.append(s)
        }
    }

    // MARK: - Line dispatcher

    private static func handleLine(_ line: String, lineNo: Int, ast: inout SequenceAST, groupStack: inout [GroupFrame]) throws {
        let lower = line.lowercased()

        if lower == "autonumber" || lower.hasPrefix("autonumber ") {
            ast.autonumber = true
            return
        }

        // participant / actor
        if let (kind, rest) = matchKeyword(line, ["participant", "actor"]) {
            try parseParticipant(rest, kindString: kind, ast: &ast, lineNo: lineNo)
            return
        }

        // activate / deactivate
        if lower.hasPrefix("activate ") {
            let id = String(line.dropFirst("activate ".count)).trimmingCharacters(in: .whitespaces)
            ensureActor(id, ast: &ast)
            appendStatement(.activate(id), to: &ast, in: &groupStack)
            return
        }
        if lower.hasPrefix("deactivate ") {
            let id = String(line.dropFirst("deactivate ".count)).trimmingCharacters(in: .whitespaces)
            ensureActor(id, ast: &ast)
            appendStatement(.deactivate(id), to: &ast, in: &groupStack)
            return
        }

        // Note ...
        if lower.hasPrefix("note ") {
            let note = try parseNote(line, lineNo: lineNo, ast: &ast)
            appendStatement(.note(note), to: &ast, in: &groupStack)
            return
        }

        // Group frames
        if lower.hasPrefix("loop") {
            let label = afterKeyword(line, keyword: "loop")
            groupStack.append(GroupFrame(kind: .loop, currentLabel: label, currentBody: []))
            return
        }
        if lower.hasPrefix("opt") {
            let label = afterKeyword(line, keyword: "opt")
            groupStack.append(GroupFrame(kind: .opt, currentLabel: label, currentBody: []))
            return
        }
        if lower.hasPrefix("alt") {
            let label = afterKeyword(line, keyword: "alt")
            groupStack.append(GroupFrame(kind: .alt(branches: []), currentLabel: label, currentBody: []))
            return
        }
        if lower.hasPrefix("else") {
            let label = afterKeyword(line, keyword: "else")
            guard let top = groupStack.last, case let .alt(branches) = top.kind else { return }
            var newBranches = branches
            newBranches.append((top.currentLabel, top.currentBody))
            groupStack[groupStack.count - 1].kind = .alt(branches: newBranches)
            groupStack[groupStack.count - 1].currentLabel = label
            groupStack[groupStack.count - 1].currentBody = []
            return
        }
        if lower.hasPrefix("par") {
            let label = afterKeyword(line, keyword: "par")
            groupStack.append(GroupFrame(kind: .par(branches: []), currentLabel: label, currentBody: []))
            return
        }
        if lower.hasPrefix("and ") {
            let label = afterKeyword(line, keyword: "and")
            guard let top = groupStack.last, case let .par(branches) = top.kind else { return }
            var newBranches = branches
            newBranches.append((top.currentLabel, top.currentBody))
            groupStack[groupStack.count - 1].kind = .par(branches: newBranches)
            groupStack[groupStack.count - 1].currentLabel = label
            groupStack[groupStack.count - 1].currentBody = []
            return
        }
        if lower == "end" {
            if let frame = groupStack.popLast() {
                appendStatement(frame.toStatement(), to: &ast, in: &groupStack)
            }
            return
        }

        // Skip-only directives (box, critical, break, rect, links, ...): tolerate, no-op.
        let skipPrefixes = ["box", "critical", "break", "rect", "links", "link", "properties", "details", "create", "destroy"]
        for prefix in skipPrefixes where lower.hasPrefix(prefix) {
            return
        }

        // Message: `A -> B : text`
        if let message = try parseMessage(line, ast: &ast) {
            appendStatement(.message(message), to: &ast, in: &groupStack)
            return
        }
        // Unrecognised line → ignore (parse-and-skip)
    }

    // MARK: - Specific parsers

    private static func parseParticipant(_ rest: String, kindString: String, ast: inout SequenceAST, lineNo: Int) throws {
        // Forms: `Alice`, `A as Alice`, `"Alice"`.
        var s = rest.trimmingCharacters(in: .whitespaces)
        var id: String = ""
        var label: String = ""
        if s.hasPrefix("\"") {
            var sc = Scanner(string: s)
            id = sc.readQuotedString() ?? ""
            sc.skipSpaces()
            s = sc.remaining
        } else {
            var sc = Scanner(string: s)
            id = sc.readIdentifier() ?? ""
            sc.skipSpaces()
            s = sc.remaining
        }
        if s.lowercased().hasPrefix("as ") {
            label = String(s.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            label = label.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        } else {
            label = id
        }
        if id.isEmpty {
            throw MermaidError.parse(message: "Participant requires an id", line: lineNo)
        }
        ensureActor(id, label: label, kind: kindString == "actor" ? .actor : .participant, ast: &ast)
    }

    private static func ensureActor(_ id: String, label: String? = nil, kind: SequenceActorKind = .participant, ast: inout SequenceAST) {
        if ast.actorIndex[id] != nil { return }
        let actor = SequenceActor(id: id, label: label ?? id, kind: kind)
        ast.actorIndex[id] = ast.actors.count
        ast.actors.append(actor)
    }

    private static func parseNote(_ line: String, lineNo: Int, ast: inout SequenceAST) throws -> SequenceNote {
        // `Note left of A: text`, `Note right of A: text`, `Note over A,B: text`.
        let body = String(line.dropFirst("Note".count)).trimmingCharacters(in: .whitespaces)
        guard let colon = body.firstIndex(of: ":") else {
            throw MermaidError.parse(message: "Malformed `Note` line", line: lineNo)
        }
        let placement = String(body[..<colon]).trimmingCharacters(in: .whitespaces)
        let text = String(body[body.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        let lower = placement.lowercased()
        if lower.hasPrefix("left of") {
            let id = String(placement.dropFirst("left of".count)).trimmingCharacters(in: .whitespaces)
            ensureActor(id, ast: &ast)
            return SequenceNote(text: text, placement: .leftOf(id))
        }
        if lower.hasPrefix("right of") {
            let id = String(placement.dropFirst("right of".count)).trimmingCharacters(in: .whitespaces)
            ensureActor(id, ast: &ast)
            return SequenceNote(text: text, placement: .rightOf(id))
        }
        if lower.hasPrefix("over") {
            let ids = placement.dropFirst("over".count)
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            for id in ids { ensureActor(id, ast: &ast) }
            return SequenceNote(text: text, placement: .over(ids))
        }
        throw MermaidError.parse(message: "Unknown note placement: \(placement)", line: lineNo)
    }

    private static func parseMessage(_ line: String, ast: inout SequenceAST) throws -> SequenceMessage? {
        // Find ` arrow ` between two identifiers. Arrows: `->`, `-->`, `->>`, `-->>`, `-x`, `--x`, `-)`, `--)`.
        // Then `:` then text.
        let arrowRegex = #"(\-?\->\>?|\-\->\>?|\-\-?x|\-\-?\))"#
        guard let range = line.range(of: arrowRegex, options: .regularExpression) else { return nil }
        let leftRaw = String(line[..<range.lowerBound])
        let rest = String(line[range.upperBound...])
        let arrowToken = String(line[range])

        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let rightRaw = String(rest[..<colon]).trimmingCharacters(in: .whitespaces)
        let text = String(rest[rest.index(after: colon)...]).trimmingCharacters(in: .whitespaces)

        // Parse `+`/`-` shorthand on either side of the arrow.
        let leftTrim = leftRaw.trimmingCharacters(in: .whitespaces)
        var deactivates = false
        if leftTrim.hasSuffix("-") {
            // Probably part of the operator, ignore. The `+`/`-` shorthand attaches to the *right* side
            // typically (after the arrow) → handled below.
        }
        _ = deactivates

        var leftID = leftTrim
        // `B-->>-A` means: deactivate B after sending.
        // We'll parse trailing `-` on the left as part of the arrow operator already (handled by regex
        // by being greedy), so the practical short-hands we accept are: `A->>+B: …` (activate B),
        // `B-->>-A: …` (deactivate B).
        let rightIDTrim = rightRaw
        var rightID = rightIDTrim
        var activates = false
        if rightID.hasPrefix("+") {
            activates = true
            rightID = String(rightID.dropFirst()).trimmingCharacters(in: .whitespaces)
        } else if rightID.hasPrefix("-") {
            deactivates = true
            rightID = String(rightID.dropFirst()).trimmingCharacters(in: .whitespaces)
        }

        // Strip any quotes.
        leftID = leftID.trimmingCharacters(in: CharacterSet(charactersIn: " \""))
        rightID = rightID.trimmingCharacters(in: CharacterSet(charactersIn: " \""))

        guard !leftID.isEmpty, !rightID.isEmpty else { return nil }

        let dashes = arrowToken.filter { $0 == "-" }.count
        let dashed = dashes >= 2
        let head: SequenceArrowHead
        if arrowToken.hasSuffix(">>") { head = .solid }
        else if arrowToken.hasSuffix(">") { head = .open }
        else if arrowToken.hasSuffix("x") { head = .cross }
        else if arrowToken.hasSuffix(")") { head = .async }
        else { head = .solid }

        ensureActor(leftID, ast: &ast)
        ensureActor(rightID, ast: &ast)

        return SequenceMessage(fromID: leftID, toID: rightID, text: text,
                               arrow: dashed ? .dashed : .solid, head: head,
                               activates: activates, deactivates: deactivates)
    }

    // MARK: - Helpers

    private static func matchKeyword(_ line: String, _ keywords: [String]) -> (String, String)? {
        let lower = line.lowercased()
        for kw in keywords {
            if lower == kw || lower.hasPrefix(kw + " ") {
                let rest = String(line.dropFirst(kw.count)).trimmingCharacters(in: .whitespaces)
                return (kw, rest)
            }
        }
        return nil
    }

    private static func afterKeyword(_ line: String, keyword: String) -> String {
        guard line.count > keyword.count else { return "" }
        let lower = line.lowercased()
        guard lower.hasPrefix(keyword) else { return line }
        return String(line.dropFirst(keyword.count)).trimmingCharacters(in: .whitespaces)
    }
}
