import CoreGraphics
import Foundation

// stateDiagram-v2 reuses the flowchart pipeline: `StateParser` lowers state syntax into a
// `FlowchartAST` (states → nodes, transitions → edges, composite states → subgraphs), which then
// flows through the regular flowchart layout and renderer. The only state-specific work after
// parsing is re-clipping edges that originally pointed at a composite state (see below).

struct StateDiagram {
    var ast: FlowchartAST
    /// Edges whose original source/target was a composite state. Layout can't route to a cluster
    /// directly, so the parser redirects such edges to a representative leaf node inside the
    /// composite; this map (keyed by the *redirected* endpoint pair) remembers the composite ids so
    /// the route can be clipped back to the cluster border after layout.
    var compositeEnds: [StateEdgeKey: StateCompositeEnds]
}

struct StateEdgeKey: Hashable {
    var from: String
    var to: String
}

struct StateCompositeEnds {
    var fromComposite: String?
    var toComposite: String?
}

enum StatePostLayout {

    /// Re-clip edges that originally referenced a composite state so the arrow stops at the
    /// cluster border instead of running through it to the representative inner node.
    static func clipCompositeEdges(_ flow: PositionedFlowchart,
                                   diagram: StateDiagram) -> PositionedFlowchart {
        guard !diagram.compositeEnds.isEmpty else { return flow }
        let rects: [String: CGRect] = Dictionary(uniqueKeysWithValues: flow.subgraphs.map { ($0.id, $0.rect) })

        var edges = flow.edges
        for i in edges.indices {
            let key = StateEdgeKey(from: edges[i].from, to: edges[i].to)
            guard let ends = diagram.compositeEnds[key] else { continue }
            var pts = edges[i].points
            if let toC = ends.toComposite, let rect = rects[toC] {
                clipTail(&pts, to: rect)
            }
            if let fromC = ends.fromComposite, let rect = rects[fromC] {
                pts.reverse()
                clipTail(&pts, to: rect)
                pts.reverse()
            }
            guard pts.count >= 2 else { continue }
            edges[i].points = pts
            if edges[i].labelPoint != nil {
                edges[i].labelPoint = FlowchartLayout.midpoint(of: pts)
            }
        }
        return PositionedFlowchart(size: flow.size, direction: flow.direction,
                                   nodes: flow.nodes, edges: edges, subgraphs: flow.subgraphs)
    }

    /// Drop trailing points inside `rect` and anchor the new last point on its border.
    private static func clipTail(_ pts: inout [CGPoint], to rect: CGRect) {
        while pts.count > 1, rect.contains(pts[pts.count - 1]) { pts.removeLast() }
        guard let outside = pts.last, !rect.contains(outside) else { return }
        pts.append(rect.borderIntersection(towards: outside))
    }
}
