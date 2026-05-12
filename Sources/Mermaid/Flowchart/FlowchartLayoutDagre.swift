import CoreGraphics
import Foundation
import MermaidLayoutDagre

/// Alternative flowchart layout backend that delegates to `SwiftDagre`. Selected at runtime when
/// the `MERMAID_DAGRE` env var is set (or when the umbrella API asks for it explicitly). The output
/// shape (`PositionedFlowchart`) is identical to the hand-rolled `FlowchartLayout.layout` so the
/// renderer doesn't care which path produced it.
///
/// We translate to dagre's vocabulary, run `SwiftDagreLayout.layout`, and read the computed
/// `x`/`y`/`points` back. Self-loops are still routed by the hand-rolled helper because dagre routes
/// them through internal dummies that are awkward to consume here.
enum FlowchartLayoutDagre {

    static func layout(_ ast: FlowchartAST) throws -> PositionedFlowchart {
        // 1. Pre-measure every node so we can hand widths/heights to dagre.
        let measured = FlowchartLayout.measureNodes(ast)

        // 2. Build the dagre graph. Compound mode is only enabled when subgraphs exist so we don't
        //    pay for it on simple charts.
        let g: DagreGraph = Graph(
            options: GraphOptions(directed: true, multigraph: true, compound: !ast.subgraphs.isEmpty)
        )
        let opts = LayoutOptions()
        opts.rankdir = dagreDir(ast.direction)
        opts.nodesep = Double(FlowchartLayout.nodeSep)
        opts.ranksep = Double(FlowchartLayout.rankSep)
        opts.marginx = Double(FlowchartLayout.outerMargin)
        opts.marginy = Double(FlowchartLayout.outerMargin)
        g.setGraph(opts)

        for node in measured {
            let label = DagreNodeLabel(width: Double(node.rect.width), height: Double(node.rect.height))
            _ = g.setNode(node.id, label: label)
        }

        // 3. Subgraph (compound) nodes — dagre clusters. Cluster widths/heights come out as bounding
        //    boxes after layout, so we feed in zeros.
        if !ast.subgraphs.isEmpty {
            for sgID in ast.subgraphOrder {
                _ = g.setNode(sgID, label: DagreNodeLabel(width: 0, height: 0))
            }
            for sgID in ast.subgraphOrder {
                guard let sg = ast.subgraphs[sgID] else { continue }
                for child in sg.nodeIDs { _ = try? g.setParent(child, parent: sgID) }
                for child in sg.childSubgraphIDs { _ = try? g.setParent(child, parent: sgID) }
            }
        }

        // 4. Edges. Self-loops are routed manually below; tag every other edge with its AST index in
        //    the `name` so we can round-trip back through `g.edge(EdgeId(...))`.
        for (i, edge) in ast.edges.enumerated() where edge.from != edge.to {
            let label = DagreEdgeLabel(minlen: max(1, edge.length), weight: 1)
            if let text = edge.label, !text.isEmpty {
                let sz = TextMeasure.layout(text, font: FlowchartLayout.edgeLabelFont).size
                label.width = Double(sz.width + 12)
                label.height = Double(sz.height + 8)
            }
            _ = try g.setEdge(edge.from, edge.to, label: label, name: "e\(i)")
        }

        // 5. Run the layout. This mutates `g` in place — node labels get `x`/`y`, edge labels get
        //    `points` and `x`/`y`.
        try SwiftDagreLayout.layout(g, options: opts)

        // 6. Read positioned nodes back. Dagre returns the centre; we keep our originally measured
        //    width/height so node visuals look the same as the hand-rolled path.
        var positioned: [PositionedNode] = []
        positioned.reserveCapacity(measured.count)
        for src in measured {
            guard let dl = g.node(src.id) else { continue }
            let rect = CGRect(center: CGPoint(x: CGFloat(dl.x), y: CGFloat(dl.y)), size: src.rect.size)
            positioned.append(PositionedNode(id: src.id, rect: rect, label: src.label,
                                             shape: src.shape, subgraphID: src.subgraphID))
        }
        let positionedByID: [String: PositionedNode] = Dictionary(uniqueKeysWithValues: positioned.map { ($0.id, $0) })

        // 7. Edge routes. Self-loops use the same helper the hand-rolled layout uses.
        var routes: [EdgeRoute] = []
        for (i, edge) in ast.edges.enumerated() {
            if edge.from == edge.to {
                if let node = positionedByID[edge.from] {
                    routes.append(FlowchartLayout.makeSelfLoop(node: node, edge: edge))
                }
                continue
            }
            let edgeID = EdgeId(v: edge.from, w: edge.to, name: "e\(i)")
            guard let dl = g.edge(edgeID),
                  let src = positionedByID[edge.from],
                  let dst = positionedByID[edge.to] else { continue }

            // Dagre's `points` already span from the source-node border to the target-node border,
            // but it doesn't always clip cleanly to a non-rectangular shape (rhombus, circle, …).
            // Re-clip the endpoints to be safe.
            var pts = dl.points.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }
            if pts.count >= 2 {
                pts[0] = src.rect.borderIntersection(towards: pts[1])
                pts[pts.count - 1] = dst.rect.borderIntersection(towards: pts[pts.count - 2])
            } else {
                pts = [src.rect.center, dst.rect.center]
                pts[0] = src.rect.borderIntersection(towards: pts[1])
                pts[1] = dst.rect.borderIntersection(towards: pts[0])
            }

            var labelPoint: CGPoint? = nil
            var labelSize: CGSize = .zero
            if let text = edge.label, !text.isEmpty {
                labelPoint = CGPoint(x: CGFloat(dl.x), y: CGFloat(dl.y))
                labelSize = TextMeasure.layout(text, font: FlowchartLayout.edgeLabelFont).size
            }

            routes.append(EdgeRoute(from: edge.from, to: edge.to, points: pts,
                                    kind: edge.kind, arrowStart: edge.arrowStart,
                                    arrowEnd: edge.arrowEnd, label: edge.label,
                                    labelPoint: labelPoint, labelSize: labelSize))
        }

        // 8. Subgraphs are real compound nodes in dagre — read their bounding rect right off the
        //    graph. Title height is reserved like the hand-rolled path.
        var depthOf: [String: Int] = [:]
        func depth(_ id: String) -> Int {
            if let d = depthOf[id] { return d }
            let d = (ast.subgraphs[id]?.parentID).map { depth($0) + 1 } ?? 0
            depthOf[id] = d
            return d
        }
        var subs: [PositionedSubgraph] = []
        for id in ast.subgraphOrder {
            guard let sg = ast.subgraphs[id], let dl = g.node(id) else { continue }
            let titleBlock = sg.title.map { TextMeasure.layout($0, font: FlowchartLayout.subgraphTitleFont).size } ?? .zero
            let titleHeight = titleBlock.height > 0 ? titleBlock.height + FlowchartLayout.subgraphTitlePadding : 0
            // Dagre already pads the cluster bbox above the topmost child for compound-graph border
            // dummies, so we render the title inside that pad and use the rect as-is. (The hand-rolled
            // layout grows the rect upward by `titleHeight`; doing that here pushes the title above
            // the canvas top, which dagre sized to the cluster's own bounds.)
            let cx = CGFloat(dl.x), cy = CGFloat(dl.y)
            let w = CGFloat(dl.width), h = CGFloat(dl.height)
            let rect = CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
            subs.append(PositionedSubgraph(id: id, title: sg.title, rect: rect,
                                           titleHeight: titleHeight, depth: depth(id)))
        }

        // 9. Canvas size. Dagre writes the overall width/height back onto `LayoutOptions`.
        let size = CGSize(width: CGFloat(opts.width), height: CGFloat(opts.height))

        // Guard against zero-size if dagre didn't populate it (edge cases on tiny graphs).
        let finalSize: CGSize
        if size.width > 0, size.height > 0 {
            finalSize = size
        } else {
            var minX = CGFloat.infinity, minY = CGFloat.infinity
            var maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
            for n in positioned {
                minX = min(minX, n.rect.minX); minY = min(minY, n.rect.minY)
                maxX = max(maxX, n.rect.maxX); maxY = max(maxY, n.rect.maxY)
            }
            finalSize = CGSize(width: (maxX - minX) + 32, height: (maxY - minY) + 32)
        }

        return PositionedFlowchart(size: finalSize, direction: ast.direction,
                                   nodes: positioned, edges: routes, subgraphs: subs)
    }

    private static func dagreDir(_ d: FlowDirection) -> LayoutOptions.RankDirection {
        switch d {
        case .TB: return .topBottom
        case .BT: return .bottomTop
        case .LR: return .leftRight
        case .RL: return .rightLeft
        }
    }
}
