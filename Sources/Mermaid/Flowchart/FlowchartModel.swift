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

    // State-diagram shapes. stateDiagram-v2 reuses the flowchart pipeline (see `StateParser`), so
    // its extra node kinds live in the shared shape enum.
    case stateStart         // [*] as a transition source — small filled disc
    case stateEnd           // [*] as a transition target — ringed disc
    case stateChoice        // <<choice>> — small empty diamond
    case stateForkJoin      // <<fork>> / <<join>> — thick bar perpendicular to the flow
    case note               // `note left of` / `note right of` box
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
    /// Participates in layout but is never drawn — used to place state-diagram notes next to
    /// their target state.
    case invisible
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
