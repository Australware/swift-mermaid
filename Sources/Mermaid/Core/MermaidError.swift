import Foundation

public enum MermaidError: Error, Sendable, Equatable {
    /// The diagram type was recognised but is not implemented yet. The associated value is the
    /// detected type keyword (e.g. `"gantt"`). Hosts should fall back to showing the raw source.
    case unsupportedDiagramType(String)
    /// A parse failure. `line` is 1-based; 0 means "unknown / not applicable".
    case parse(message: String, line: Int)
    /// Layout could not produce a sensible result.
    case layout(message: String)
}

extension MermaidError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .unsupportedDiagramType(let type):
            return "Unsupported Mermaid diagram type: \(type)"
        case .parse(let message, let line):
            return line > 0 ? "Parse error (line \(line)): \(message)" : "Parse error: \(message)"
        case .layout(let message):
            return "Layout error: \(message)"
        }
    }
}
