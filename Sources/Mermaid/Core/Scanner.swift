import Foundation

/// Lightweight character-based scanner for the hand-written parsers. Indexes by `Int` over the
/// scanner's own `Character` array so all positions stay O(1).
struct Scanner {
    let chars: [Character]
    var position: Int = 0

    init(string: String) {
        self.chars = Array(string)
    }

    var isAtEnd: Bool { position >= chars.count }

    var remaining: String { String(chars[position..<chars.count]) }

    func peek(offset: Int = 0) -> Character? {
        let idx = position + offset
        return idx < chars.count ? chars[idx] : nil
    }

    func peekString(_ s: String) -> Bool {
        let chs = Array(s)
        guard position + chs.count <= chars.count else { return false }
        for (i, c) in chs.enumerated() {
            if chars[position + i] != c { return false }
        }
        return true
    }

    mutating func advance(by count: Int = 1) {
        position = min(chars.count, position + count)
    }

    mutating func skipSpaces() {
        while position < chars.count, chars[position] == " " || chars[position] == "\t" {
            position += 1
        }
    }

    /// An identifier: a letter / underscore followed by letters / digits / `_` / `-`. Mermaid IDs
    /// allow `-` but not as a leading char. Some of Mermaid's identifiers contain `.`; we accept it.
    mutating func readIdentifier() -> String? {
        guard position < chars.count else { return nil }
        let c = chars[position]
        guard c.isLetter || c == "_" else { return nil }
        var end = position + 1
        while end < chars.count {
            let ch = chars[end]
            if ch.isLetter || ch.isNumber || ch == "_" || ch == "-" || ch == "." {
                end += 1
            } else { break }
        }
        let id = String(chars[position..<end])
        position = end
        return id
    }

    mutating func readQuotedString() -> String? {
        guard position < chars.count, chars[position] == "\"" else { return nil }
        position += 1
        var out = ""
        while position < chars.count, chars[position] != "\"" {
            if chars[position] == "\\", position + 1 < chars.count {
                out.append(chars[position + 1])
                position += 2
            } else {
                out.append(chars[position])
                position += 1
            }
        }
        if position < chars.count { position += 1 }   // closing quote
        return out
    }

    /// If the next character starts a shape group, consume it and return the shape + inner text.
    /// Supports: `[text]`, `(text)`, `{text}`, `[(text)]`, `((text))`, `(((text)))`, `[[text]]`,
    /// `{{text}}`, `[/text/]`, `[\text\]`, `[/text\]`, `[\text/]`, `>text]`.
    mutating func readBracketGroup() -> (FlowNodeShape, String)? {
        guard position < chars.count else { return nil }
        let c0 = chars[position]
        let c1 = position + 1 < chars.count ? chars[position + 1] : Character(" ")
        let c2 = position + 2 < chars.count ? chars[position + 2] : Character(" ")
        // Try the longest openers first.
        // (((text)))
        if c0 == "(" && c1 == "(" && c2 == "(" {
            return readGroup(open: ["(", "(", "("], close: [")", ")", ")"], shape: .doubleCircle)
        }
        // ((text))
        if c0 == "(" && c1 == "(" {
            return readGroup(open: ["(", "("], close: [")", ")"], shape: .circle)
        }
        // ([text])
        if c0 == "(" && c1 == "[" {
            return readGroup(open: ["(", "["], close: ["]", ")"], shape: .stadium)
        }
        // [[text]]
        if c0 == "[" && c1 == "[" {
            return readGroup(open: ["[", "["], close: ["]", "]"], shape: .subroutine)
        }
        // [(text)]
        if c0 == "[" && c1 == "(" {
            return readGroup(open: ["[", "("], close: [")", "]"], shape: .cylinder)
        }
        // [/text/], [/text\], [\text/], [\text\]
        if c0 == "[" && c1 == "/" {
            // Slash forward open — could close with `/]` (parallelogram) or `\]` (trapezoid).
            return readSlashGroup(forward: true)
        }
        if c0 == "[" && c1 == "\\" {
            return readSlashGroup(forward: false)
        }
        // {{text}}
        if c0 == "{" && c1 == "{" {
            return readGroup(open: ["{", "{"], close: ["}", "}"], shape: .hexagon)
        }
        // [text]
        if c0 == "[" {
            return readGroup(open: ["["], close: ["]"], shape: .rect)
        }
        // (text)
        if c0 == "(" {
            return readGroup(open: ["("], close: [")"], shape: .roundRect)
        }
        // {text}
        if c0 == "{" {
            return readGroup(open: ["{"], close: ["}"], shape: .rhombus)
        }
        // >text]
        if c0 == ">" {
            return readGroup(open: [">"], close: ["]"], shape: .asymmetric)
        }
        return nil
    }

    private mutating func readGroup(open: [Character], close: [Character], shape: FlowNodeShape) -> (FlowNodeShape, String)? {
        let save = position
        // Consume opener.
        for c in open {
            guard position < chars.count, chars[position] == c else { position = save; return nil }
            position += 1
        }
        // Read text until the closer sequence.
        var text = ""
        while position < chars.count {
            // Quoted strings inside labels: `"..."`
            if chars[position] == "\"" {
                position += 1
                while position < chars.count, chars[position] != "\"" {
                    text.append(chars[position]); position += 1
                }
                if position < chars.count { position += 1 }
                continue
            }
            if matchAhead(close) { break }
            text.append(chars[position])
            position += 1
        }
        // Consume closer.
        for c in close {
            guard position < chars.count, chars[position] == c else { position = save; return nil }
            position += 1
        }
        return (shape, text.trimmingCharacters(in: .whitespaces))
    }

    private mutating func readSlashGroup(forward: Bool) -> (FlowNodeShape, String)? {
        // [/text/]  forward-forward → parallelogramFwd
        // [/text\]  forward-back     → trapezoid
        // [\text\]  back-back        → parallelogramBack
        // [\text/]  back-forward     → trapezoidInv
        let save = position
        position += 2     // consume `[/` or `[\`
        var text = ""
        // Read until we see `/]` or `\]`.
        while position < chars.count {
            if chars[position] == "\"" {
                position += 1
                while position < chars.count, chars[position] != "\"" {
                    text.append(chars[position]); position += 1
                }
                if position < chars.count { position += 1 }
                continue
            }
            if (chars[position] == "/" || chars[position] == "\\"),
               position + 1 < chars.count, chars[position + 1] == "]" {
                let endChar = chars[position]
                position += 2
                let shape: FlowNodeShape
                switch (forward, endChar == "/") {
                case (true, true):   shape = .parallelogramFwd
                case (true, false):  shape = .trapezoid
                case (false, false): shape = .parallelogramBack
                case (false, true):  shape = .trapezoidInv
                }
                return (shape, text.trimmingCharacters(in: .whitespaces))
            }
            text.append(chars[position])
            position += 1
        }
        position = save
        return nil
    }

    private func matchAhead(_ seq: [Character]) -> Bool {
        guard position + seq.count <= chars.count else { return false }
        for (i, c) in seq.enumerated() where chars[position + i] != c { return false }
        return true
    }

    /// Read characters making up the inline edge-label body. Stops when the next character starts
    /// the second half of the edge operator (`-` for solid/dotted, `=` for thick) followed by more
    /// of the same. Pragmatic and lenient.
    mutating func readUntilEdgeSecondHalf() -> String {
        var out = ""
        while !isAtEnd {
            let ch = chars[position]
            // Heuristic: a run of `-` or `=` or `.` of length ≥ 2 starts the second half.
            if ch == "-" || ch == "=" || ch == "." {
                // Look ahead to see if this is a real edge tail.
                var run = 0
                var p = position
                while p < chars.count, (chars[p] == ch || (ch == "-" && (chars[p] == "." || chars[p] == "-"))) {
                    run += 1; p += 1
                }
                if run >= 2 || (ch == "." && run >= 1) { break }
            }
            out.append(ch)
            position += 1
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}
