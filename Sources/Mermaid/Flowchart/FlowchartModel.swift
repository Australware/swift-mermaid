import CoreGraphics
import Foundation

// MARK: - AST

public enum FlowDirection: String, Sendable {
    case TB, BT, LR, RL
}

enum FlowNodeShape: String {
    case rect           // [text]
    case roundRect      // (text)
    case stadium        // ([text])
    case subroutine     // [[text]]
    case cylinder       // [(text)]
    case circle         // ((text))
    case doubleCircle   // (((text)))
    case rhombus        // {text}
    case hexagon        // {{text}}
    case parallelogramFwd   // [/text/]
    case parallelogramBack  // [\text\]
    case trapezoid          // [/text\]
    case trapezoidInv       // [\text/]
    case asymmetric         // >text]
}

struct FlowNode {
    var id: String
    var label: String
    var shape: FlowNodeShape
    var subgraphID: String?
}

enum FlowEdgeKind {
    case solid
    case dotted
    case thick
}

enum FlowArrow {
    case none
    case arrow
    case circle
    case cross
}

struct FlowEdge {
    var from: String
    var to: String
    var kind: FlowEdgeKind
    var arrowStart: FlowArrow
    var arrowEnd: FlowArrow
    var label: String?
    /// Mermaid's "extra dashes" length; minimum 1.
    var length: Int
}

struct FlowSubgraph {
    var id: String
    var title: String?
    var nodeIDs: [String]
    var childSubgraphIDs: [String]
    var parentID: String?
    var direction: FlowDirection?
}

struct FlowchartAST {
    var direction: FlowDirection
    var nodes: [String: FlowNode]
    /// Order of first appearance — keeps layout deterministic regardless of dictionary iteration.
    var nodeOrder: [String]
    var edges: [FlowEdge]
    var subgraphs: [String: FlowSubgraph]
    var subgraphOrder: [String]
}
