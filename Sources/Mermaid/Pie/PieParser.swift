import Foundation

struct PieSlice {
    let label: String
    let value: Double
}

struct PieAST {
    var title: String?
    var showData: Bool
    var slices: [PieSlice]
}

enum PieParser {

    static func parse(_ source: String) throws -> PieAST {
        let lines = source.components(separatedBy: "\n")
            .enumerated()
            .map { (idx: $0.offset + 1, line: $0.element.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.line.isEmpty }

        guard let firstIdx = lines.firstIndex(where: { !$0.line.isEmpty }) else {
            throw MermaidError.parse(message: "Empty pie chart source", line: 0)
        }
        // Header may be `pie`, `pie title <...>`, or `pie showData`.
        let header = lines[firstIdx].line
        guard header.lowercased() == "pie" || header.lowercased().hasPrefix("pie ") else {
            throw MermaidError.parse(message: "Expected `pie` header", line: lines[firstIdx].idx)
        }

        var ast = PieAST(title: nil, showData: false, slices: [])

        // Inline modifiers after `pie`.
        let headerRest = String(header.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        if !headerRest.isEmpty {
            try parseHeaderModifiers(headerRest, into: &ast, lineNo: lines[firstIdx].idx)
        }

        for i in (firstIdx + 1)..<lines.count {
            let entry = lines[i]
            let line = entry.line
            if line.lowercased().hasPrefix("title ") {
                ast.title = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if line.lowercased() == "showdata" { ast.showData = true; continue }
            if let slice = try parseSlice(line, lineNo: entry.idx) {
                ast.slices.append(slice)
            }
        }
        return ast
    }

    private static func parseHeaderModifiers(_ s: String, into ast: inout PieAST, lineNo: Int) throws {
        var rest = s
        if rest.lowercased().hasPrefix("showdata") {
            ast.showData = true
            rest = String(rest.dropFirst("showdata".count)).trimmingCharacters(in: .whitespaces)
        }
        if rest.lowercased().hasPrefix("title ") {
            ast.title = String(rest.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        } else if !rest.isEmpty && !rest.lowercased().hasPrefix("showdata") {
            // Treat anything else after `pie ` as a title — Mermaid is lenient.
            ast.title = rest
        }
    }

    private static func parseSlice(_ line: String, lineNo: Int) throws -> PieSlice? {
        // Expected: `"label" : number`
        guard let colon = line.lastIndex(of: ":") else { return nil }
        var labelPart = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
        let valuePart = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        if labelPart.hasPrefix("\"") && labelPart.hasSuffix("\"") && labelPart.count >= 2 {
            labelPart = String(labelPart.dropFirst().dropLast())
        }
        guard let value = Double(valuePart) else {
            throw MermaidError.parse(message: "Slice value must be a number", line: lineNo)
        }
        return PieSlice(label: labelPart, value: value)
    }
}
