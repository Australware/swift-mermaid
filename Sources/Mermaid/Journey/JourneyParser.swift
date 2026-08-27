import Foundation

// MARK: - AST

struct JourneyTask {
    let name: String
    /// Mermaid's 1–5 satisfaction score. `nil` when the source omitted or mis-typed it.
    let score: Int?
    let actors: [String]
}

struct JourneySection {
    let name: String
    var tasks: [JourneyTask]
}

struct JourneyAST {
    var title: String?
    var sections: [JourneySection]
    /// Every distinct actor, in first-appearance order — this fixes their colour assignment.
    var actors: [String]
}

// MARK: - Parser

/// Hand-written parser for the user-journey syntax. The reference grammar is
/// `packages/mermaid/src/diagrams/user-journey/parser/journey.jison`. The whole language is
/// `title`, `section`, and `taskName: score: actor, actor` lines; `accTitle` / `accDescr` are
/// parse-and-skipped.
enum JourneyParser {

    static func parse(_ source: String) throws -> JourneyAST {
        let lines = source.components(separatedBy: "\n")
            .enumerated()
            .map { (idx: $0.offset + 1, line: $0.element.trimmingCharacters(in: .whitespaces)) }

        guard let firstIdx = lines.firstIndex(where: { !$0.line.isEmpty }) else {
            throw MermaidError.parse(message: "Empty journey source", line: 0)
        }
        let header = lines[firstIdx].line.lowercased()
        guard header == "journey" || header.hasPrefix("journey ") else {
            throw MermaidError.parse(message: "Expected `journey` header", line: lines[firstIdx].idx)
        }

        var ast = JourneyAST(title: nil, sections: [], actors: [])

        for i in (firstIdx + 1)..<lines.count {
            let line = lines[i].line
            if line.isEmpty { continue }
            let lower = line.lowercased()

            if lower.hasPrefix("acctitle") || lower.hasPrefix("accdescr") { continue }

            if lower == "title" || lower.hasPrefix("title ") {
                ast.title = String(line.dropFirst("title".count)).trimmingCharacters(in: .whitespaces)
                continue
            }

            if lower == "section" || lower.hasPrefix("section ") {
                let name = String(line.dropFirst("section".count)).trimmingCharacters(in: .whitespaces)
                ast.sections.append(JourneySection(name: name, tasks: []))
                continue
            }

            guard let task = parseTask(line) else { continue }
            // Tasks written before any `section` land in an unnamed leading section, which the
            // renderer draws without a band label.
            if ast.sections.isEmpty { ast.sections.append(JourneySection(name: "", tasks: [])) }
            ast.sections[ast.sections.count - 1].tasks.append(task)
            for actor in task.actors where !ast.actors.contains(actor) { ast.actors.append(actor) }
        }

        return ast
    }

    /// `Make tea: 5: Me, Cat` → name, score, actors. Both trailing fields are optional.
    private static func parseTask(_ line: String) -> JourneyTask? {
        guard let firstColon = line.firstIndex(of: ":") else { return nil }
        let name = String(line[..<firstColon]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }

        let rest = String(line[line.index(after: firstColon)...])
        let scorePart: String
        var actors: [String] = []
        if let secondColon = rest.firstIndex(of: ":") {
            scorePart = String(rest[..<secondColon])
            actors = String(rest[rest.index(after: secondColon)...])
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        } else {
            scorePart = rest
        }
        return JourneyTask(name: name,
                           score: Int(scorePart.trimmingCharacters(in: .whitespaces)),
                           actors: actors)
    }
}
