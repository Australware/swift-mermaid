import CoreGraphics
import Foundation

/// Top-level entry point. `Mermaid.render(source)` parses, lays out, and renders to a `MermaidScene`.
public enum Mermaid {

    /// Layout backend selection for flowchart-family diagrams.
    public enum LayoutBackend: Sendable {
        /// Hand-rolled Sugiyama-style layered layout. The default — no external dependency.
        case builtin
        /// `SwiftDagre` (lukilabs/dagre-swift): network-simplex ranking, barycenter ordering,
        /// Brandes–Köpf x-coords, real compound-graph (subgraph) layout, edge-label dummy nodes.
        case dagre
    }

    /// Parse → layout → render.
    ///
    /// - Parameters:
    ///   - source: The raw Mermaid source (the contents of a ```` ```mermaid ```` fenced block).
    ///   - theme: Caller's preferred theme. Overridden by an in-source `%%{init: {'theme': ...}}%%`
    ///     directive *only* when the caller passed `.default` — explicit dark mode from the host wins.
    ///   - layout: Which flowchart layout backend to use. Defaults to the value of the
    ///     `MERMAID_DAGRE` environment variable (any non-empty value → `.dagre`), else `.builtin`.
    ///
    /// - Throws: `MermaidError.unsupportedDiagramType` for diagram types not yet implemented;
    ///   `MermaidError.parse` for syntax errors; `MermaidError.layout` if layout fails.
    public static func render(_ source: String,
                              theme: MermaidTheme = .default,
                              layout: LayoutBackend = .default) throws -> MermaidScene {
        let pre = DiagramPreprocessor.process(source, requestedTheme: theme)
        let effective = pre.theme ?? theme

        switch pre.type {
        case .flowchart, .state:
            // State diagrams reuse the flowchart pipeline: `StateParser` lowers the state syntax
            // into a `FlowchartAST`, then layout + rendering are shared.
            let ast: FlowchartAST
            var stateDiagram: StateDiagram? = nil
            if pre.type == .state {
                let sd = try StateParser.parse(pre.body)
                stateDiagram = sd
                ast = sd.ast
            } else {
                ast = try FlowchartParser.parse(pre.body)
            }
            var positioned: PositionedFlowchart
            switch layout {
            case .builtin:
                positioned = FlowchartLayout.layout(ast)
            case .dagre:
                do {
                    positioned = try FlowchartLayoutDagre.layout(ast)
                } catch {
                    // Defensive: if dagre throws on a malformed graph, fall back to the built-in
                    // layout rather than failing the whole render.
                    positioned = FlowchartLayout.layout(ast)
                }
            }
            if let sd = stateDiagram {
                positioned = StatePostLayout.clipCompositeEdges(positioned, diagram: sd)
            }
            return FlowchartRenderer.render(positioned, theme: effective)

        case .sequence:
            let ast = try SequenceParser.parse(pre.body)
            return SequenceRenderer.render(ast, theme: effective)

        case .classDiagram:
            let ast = try ClassParser.parse(pre.body)
            let positioned = ClassLayout.layout(ast)
            return ClassRenderer.render(positioned, theme: effective)

        case .pie:
            let ast = try PieParser.parse(pre.body)
            return PieRenderer.render(ast, theme: effective)

        case .architecture:
            let ast = try ArchitectureParser.parse(pre.body)
            let positioned = ArchitectureLayout.layout(ast)
            return ArchitectureRenderer.render(positioned, theme: effective)

        default:
            throw MermaidError.unsupportedDiagramType(pre.typeKeyword)
        }
    }
}

extension Mermaid.LayoutBackend {
    /// Default flowchart layout backend. `.dagre` (a vendored copy of lukilabs/dagre-swift) gives
    /// noticeably better results than the hand-rolled fallback on real-world charts — see the
    /// `try-dagre-swift` evaluation. Set `MERMAID_DAGRE=0` to force the hand-rolled backend.
    public static var `default`: Mermaid.LayoutBackend {
        if let value = ProcessInfo.processInfo.environment["MERMAID_DAGRE"], value == "0" {
            return .builtin
        }
        return .dagre
    }
}
