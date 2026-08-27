import Foundation

/// Hand-written parser for the `gitGraph` syntax. The reference grammar is
/// `packages/mermaid/src/diagrams/git/parser/gitGraph.jison`; we cover `commit`, `branch`,
/// `checkout` / `switch`, `merge`, and `cherry-pick`, each with their `id:` / `tag:` / `type:` /
/// `order:` / `parent:` options, plus the `gitGraph LR:` direction header.
///
/// The deprecated `options … end` block and `accTitle` / `accDescr` are parse-and-skipped. The
/// `mainBranchName` config is not honoured — `%%{init}%%` directives are stripped before parsing.
enum GitGraphParser {

    static let defaultBranch = "main"

    static func parse(_ source: String) throws -> GitGraphAST {
        let lines = source.components(separatedBy: "\n")
            .enumerated()
            .map { (idx: $0.offset + 1, line: $0.element.trimmingCharacters(in: .whitespaces)) }

        guard let firstIdx = lines.firstIndex(where: { !$0.line.isEmpty }) else {
            throw MermaidError.parse(message: "Empty gitGraph source", line: 0)
        }

        // Header: `gitGraph`, `gitGraph:`, `gitGraph TB:` — the trailing colon is optional.
        var header = lines[firstIdx].line
        if header.hasSuffix(":") { header = String(header.dropLast()) }
        let headerTokens = header.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let keyword = headerTokens.first, keyword.lowercased() == "gitgraph" else {
            throw MermaidError.parse(message: "Expected `gitGraph` header", line: lines[firstIdx].idx)
        }
        var direction = GitGraphDirection.LR
        if headerTokens.count >= 2, let d = GitGraphDirection(rawValue: headerTokens[1].uppercased()) {
            direction = d
        }

        var branches: [GitBranch] = [GitBranch(name: defaultBranch, order: 0)]
        var branchExists: Set<String> = [defaultBranch]
        var heads: [String: String] = [:]          // branch → head commit id
        var commits: [GitCommit] = []
        var commitIDs: Set<String> = []
        var current = defaultBranch
        var inOptionsBlock = false

        func appendCommit(_ commit: GitCommit, line: Int) throws {
            guard !commitIDs.contains(commit.id) else {
                throw MermaidError.parse(message: "Duplicate commit id `\(commit.id)`", line: line)
            }
            commitIDs.insert(commit.id)
            heads[commit.branch] = commit.id
            commits.append(commit)
        }

        for i in (firstIdx + 1)..<lines.count {
            let entry = lines[i]
            let line = entry.line
            if line.isEmpty { continue }

            let lower = line.lowercased()
            if inOptionsBlock { if lower == "end" { inOptionsBlock = false }; continue }
            if lower == "options" { inOptionsBlock = true; continue }
            if lower.hasPrefix("acctitle") || lower.hasPrefix("accdescr") { continue }

            let (keyword, rest) = splitFirstToken(line)
            switch keyword.lowercased() {

            case "commit":
                let opts = parseOptions(rest)
                let seq = commits.count
                let id = opts["id"] ?? "\(seq)-\(current)"
                try appendCommit(GitCommit(id: id, label: opts["id"], branch: current,
                                           parents: heads[current].map { [$0] } ?? [],
                                           type: commitType(opts["type"]) ?? .normal,
                                           tag: opts["tag"], seq: seq),
                                 line: entry.idx)

            case "branch":
                let (name, tail) = splitFirstToken(rest)
                let branch = unquote(name)
                guard !branch.isEmpty else { continue }
                guard !branchExists.contains(branch) else {
                    throw MermaidError.parse(message: "Branch `\(branch)` already exists", line: entry.idx)
                }
                let order = parseOptions(tail)["order"].flatMap(Double.init)
                    // Unordered branches keep declaration order but stay below any explicit `order: 1+`.
                    ?? Double(branches.count) / 1000
                branches.append(GitBranch(name: branch, order: order))
                branchExists.insert(branch)
                heads[branch] = heads[current]     // the branch point
                current = branch                   // `branch` also checks out

            case "checkout", "switch":
                let branch = unquote(splitFirstToken(rest).0)
                guard branchExists.contains(branch) else {
                    throw MermaidError.parse(message: "Cannot checkout unknown branch `\(branch)`", line: entry.idx)
                }
                current = branch

            case "merge":
                let (nameToken, tail) = splitFirstToken(rest)
                let source = unquote(nameToken)
                guard branchExists.contains(source) else {
                    throw MermaidError.parse(message: "Cannot merge unknown branch `\(source)`", line: entry.idx)
                }
                guard source != current else {
                    throw MermaidError.parse(message: "Cannot merge branch `\(source)` into itself", line: entry.idx)
                }
                let opts = parseOptions(tail)
                let seq = commits.count
                let id = opts["id"] ?? "\(seq)-merge-\(source)"
                var parents: [String] = []
                if let head = heads[current] { parents.append(head) }
                if let sourceHead = heads[source] { parents.append(sourceHead) }
                try appendCommit(GitCommit(id: id, label: opts["id"], branch: current, parents: parents,
                                           type: .merge, tag: opts["tag"], seq: seq),
                                 line: entry.idx)

            case "cherry-pick", "cherrypick":
                let opts = parseOptions(rest)
                guard let sourceID = opts["id"], commitIDs.contains(sourceID) else {
                    throw MermaidError.parse(message: "cherry-pick needs `id:` of an existing commit", line: entry.idx)
                }
                let seq = commits.count
                var parents: [String] = []
                if let head = heads[current] { parents.append(head) }
                parents.append(sourceID)
                try appendCommit(GitCommit(id: "\(seq)-cherry-\(sourceID)", label: sourceID, branch: current,
                                           parents: parents, type: .cherryPick, tag: opts["tag"], seq: seq),
                                 line: entry.idx)

            default:
                continue   // lenient: unknown statements are ignored
            }
        }

        return GitGraphAST(direction: direction, branches: branches, commits: commits)
    }

    // MARK: - Token helpers

    private static func commitType(_ raw: String?) -> GitCommitType? {
        switch raw?.uppercased() {
        case "NORMAL": return .normal
        case "REVERSE": return .reverse
        case "HIGHLIGHT": return .highlight
        default: return nil
        }
    }

    /// Split off the first whitespace-delimited token, returning it and the untouched remainder.
    private static func splitFirstToken(_ s: String) -> (String, String) {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard let space = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return (trimmed, "") }
        return (String(trimmed[..<space]),
                String(trimmed[space...]).trimmingCharacters(in: .whitespaces))
    }

    private static func unquote(_ s: String) -> String {
        guard s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") else { return s }
        return String(s.dropFirst().dropLast())
    }

    /// `id: "Alpha" tag:"v1" type: HIGHLIGHT` → `["id": "Alpha", "tag": "v1", "type": "HIGHLIGHT"]`.
    /// Keys are lowercased; the space after `:` is optional, and values may be bare or quoted.
    private static func parseOptions(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        var sc = Scanner(string: s)
        while !sc.isAtEnd {
            sc.skipSpaces()
            guard let key = sc.readIdentifier() else { sc.advance(); continue }
            sc.skipSpaces()
            guard sc.peek() == ":" else { continue }
            sc.advance()
            sc.skipSpaces()
            if let quoted = sc.readQuotedString() {
                out[key.lowercased()] = quoted
            } else {
                var value = ""
                while let c = sc.peek(), c != " ", c != "\t" { value.append(c); sc.advance() }
                out[key.lowercased()] = value
            }
        }
        return out
    }
}
