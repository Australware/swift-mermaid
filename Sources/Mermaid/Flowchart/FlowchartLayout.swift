import CoreGraphics
import Foundation

// MARK: - Positioned model

struct PositionedNode {
    let id: String
    /// Centre + size in points.
    var rect: CGRect
    let label: String
    let shape: FlowNodeShape
    let subgraphID: String?
}

struct EdgeRoute {
    let from: String
    let to: String
    /// Polyline including endpoints clipped to each node's border.
    var points: [CGPoint]
    let kind: FlowEdgeKind
    let arrowStart: FlowArrow
    let arrowEnd: FlowArrow
    let label: String?
    /// Centre point for the optional edge label.
    var labelPoint: CGPoint?
    var labelSize: CGSize
}

struct PositionedSubgraph {
    let id: String
    let title: String?
    var rect: CGRect
    /// Vertical space reserved at the top for the title.
    var titleHeight: CGFloat
    let depth: Int
}

struct PositionedFlowchart {
    let size: CGSize
    let direction: FlowDirection
    let nodes: [PositionedNode]
    let edges: [EdgeRoute]
    let subgraphs: [PositionedSubgraph]
}

// MARK: - Layout

enum FlowchartLayout {

    // Spacing constants (in points). Mermaid uses ~50 for both by default.
    static let nodeSep: CGFloat = 50
    static let rankSep: CGFloat = 50
    static let nodePaddingH: CGFloat = 18
    static let nodePaddingV: CGFloat = 12
    static let nodeFont = FontSpec(family: FontSpec.defaultFamily, size: 16)
    static let edgeLabelFont = FontSpec(family: FontSpec.defaultFamily, size: 13)
    static let subgraphTitleFont = FontSpec(family: FontSpec.defaultFamily, size: 16, weight: .bold)
    static let subgraphPadding: CGFloat = 16
    static let subgraphTitlePadding: CGFloat = 8
    static let outerMargin: CGFloat = 16

    static func layout(_ ast: FlowchartAST) -> PositionedFlowchart {
        // Step 1: measure each node and decide its size based on shape + label.
        var nodes = measureNodes(ast)

        // Step 2: build adjacency over real edges; self-loops are routed separately.
        let realEdges = ast.edges.filter { $0.from != $0.to }
        let selfLoops = ast.edges.filter { $0.from == $0.to }
        let adjacency = buildAdjacency(nodes: ast.nodeOrder, edges: realEdges)

        // Step 3: cycle break (DFS).
        let reversed = breakCycles(nodes: ast.nodeOrder, adjacency: adjacency)

        // Step 4: rank by longest path. Edge lengths come from `FlowEdge.length`.
        let ranks = assignRanks(nodes: ast.nodeOrder, edges: realEdges, reversed: reversed)

        // Step 5: insert virtual nodes for edges spanning multiple ranks. Each virtual node sits on
        //   an intermediate rank between source and target.
        var virtualNodes: [String: VirtualNode] = [:]
        var rankMembers: [Int: [String]] = [:]
        for id in ast.nodeOrder { rankMembers[ranks[id] ?? 0, default: []].append(id) }
        let routedEdges = expandEdges(realEdges, reversed: reversed, ranks: ranks,
                                      rankMembers: &rankMembers, virtualNodes: &virtualNodes)

        // Step 6: crossing reduction via barycentre sweeps.
        reduceCrossings(rankMembers: &rankMembers, routedEdges: routedEdges)

        // Step 7: x-coordinate assignment (simple: place each rank left-to-right with nodeSep).
        let positions = assignCoordinates(nodes: &nodes, virtualNodes: virtualNodes,
                                          rankMembers: rankMembers, ranks: ranks,
                                          direction: ast.direction)

        // Step 8: build edge routes from each `routedEdge`'s chain of (real or virtual) node centres.
        var routes = buildRoutes(routedEdges: routedEdges, nodes: nodes, virtualPoints: positions.virtualCenters,
                                 ast: ast)
        // Add self-loop routes back in.
        for edge in selfLoops {
            if let node = nodes.first(where: { $0.id == edge.from }) {
                routes.append(makeSelfLoop(node: node, edge: edge))
            }
        }

        // Step 9: compute subgraph bounding boxes.
        let subs = computeSubgraphBoxes(ast: ast, nodes: nodes)

        // Step 10: shift everything by the outer margin and compute the overall canvas size, taking
        //   subgraphs into account.
        let (finalNodes, finalRoutes, finalSubs, size) = finalize(nodes: nodes, routes: routes,
                                                                  subgraphs: subs)

        // Step 11: rotate the (TB-laid-out) coordinates into the requested direction. Subgraph rects
        // are rebuilt from rotated node positions so they actually contain their members.
        let rotated = rotate(direction: ast.direction,
                             flowchart: PositionedFlowchart(size: size, direction: ast.direction,
                                                            nodes: finalNodes, edges: finalRoutes,
                                                            subgraphs: finalSubs))
        return rebuildSubgraphs(ast: ast, flowchart: rotated)
    }

    // MARK: - Helpers

    private struct VirtualNode {
        let id: String
        let rank: Int
        /// The original edge this dummy belongs to.
        let edgeIndex: Int
    }

    private struct RoutedEdge {
        var sourceID: String
        var targetID: String
        /// Chain of (real or virtual) node IDs from source to target, *inclusive*.
        var chain: [String]
        var originalIndex: Int
        var reversed: Bool
        var label: String?
        var kind: FlowEdgeKind
        var arrowStart: FlowArrow
        var arrowEnd: FlowArrow
        var length: Int
    }

    static func measureNodes(_ ast: FlowchartAST) -> [PositionedNode] {
        var out: [PositionedNode] = []
        out.reserveCapacity(ast.nodeOrder.count)
        for id in ast.nodeOrder {
            guard let node = ast.nodes[id] else { continue }
            let block = TextMeasure.layout(node.label, font: nodeFont)
            let labelSize = block.size
            var w = labelSize.width + nodePaddingH * 2
            var h = labelSize.height + nodePaddingV * 2
            // Shapes with a fixed size independent of their (empty) label skip the minimum-size
            // clamp below.
            var fixedSize: CGSize? = nil
            // Shape-specific size adjustments.
            switch node.shape {
            case .circle, .doubleCircle:
                let d = max(w, h)
                w = d; h = d
            case .rhombus:
                w += labelSize.height * 0.5
                h += labelSize.width * 0.25
            case .hexagon, .parallelogramFwd, .parallelogramBack, .trapezoid, .trapezoidInv:
                w += labelSize.height
            case .stadium:
                w += labelSize.height
            case .cylinder:
                // The two cap ellipses eat ~2·ry of vertical room; give the label its own space.
                w += 12
                h += 24
            case .subroutine, .asymmetric:
                w += 12
            case .stateStart, .stateEnd:
                fixedSize = CGSize(width: 14, height: 14)
            case .stateChoice:
                fixedSize = CGSize(width: 32, height: 32)
            case .stateForkJoin:
                // The bar runs perpendicular to the flow direction.
                let horizontalFlow = (ast.direction == .LR || ast.direction == .RL)
                fixedSize = horizontalFlow ? CGSize(width: 8, height: 70)
                                           : CGSize(width: 70, height: 8)
            case .rect, .roundRect, .note:
                break
            }
            if let fixed = fixedSize {
                w = fixed.width; h = fixed.height
            } else {
                // Minimum size so single-character labels don't look pinched.
                w = max(w, 60); h = max(h, 36)
            }
            let rect = CGRect(origin: .zero, size: CGSize(width: w.rounded(), height: h.rounded()))
            out.append(PositionedNode(id: id, rect: rect, label: node.label, shape: node.shape,
                                      subgraphID: node.subgraphID))
        }
        return out
    }

    private static func buildAdjacency(nodes: [String], edges: [FlowEdge]) -> [String: [String]] {
        var adj: [String: [String]] = [:]
        for n in nodes { adj[n] = [] }
        for e in edges { adj[e.from, default: []].append(e.to) }
        return adj
    }

    /// DFS-based cycle break: any edge that lands on a node already on the recursion stack is
    /// considered a back edge and gets marked reversed.
    private static func breakCycles(nodes: [String], adjacency: [String: [String]]) -> Set<EdgeKey> {
        var visited: Set<String> = []
        var onStack: Set<String> = []
        var reversed: Set<EdgeKey> = []
        func dfs(_ u: String) {
            visited.insert(u); onStack.insert(u)
            for v in adjacency[u] ?? [] {
                if !visited.contains(v) {
                    dfs(v)
                } else if onStack.contains(v) {
                    reversed.insert(EdgeKey(from: u, to: v))
                }
            }
            onStack.remove(u)
        }
        for n in nodes where !visited.contains(n) { dfs(n) }
        return reversed
    }

    private struct EdgeKey: Hashable {
        let from: String
        let to: String
    }

    /// Longest-path layering using lengths from edges (`length` ≥ 1).
    private static func assignRanks(nodes: [String], edges: [FlowEdge], reversed: Set<EdgeKey>) -> [String: Int] {
        // Build directed adjacency with reversal applied.
        var inDeg: [String: Int] = Dictionary(uniqueKeysWithValues: nodes.map { ($0, 0) })
        var outs: [String: [(target: String, length: Int)]] = [:]
        for e in edges {
            let key = EdgeKey(from: e.from, to: e.to)
            let from = reversed.contains(key) ? e.to : e.from
            let to = reversed.contains(key) ? e.from : e.to
            outs[from, default: []].append((to, max(1, e.length)))
            inDeg[to, default: 0] += 1
        }
        // Topological sort (Kahn's). Ties broken by first-appearance order for determinism.
        var queue: [String] = nodes.filter { (inDeg[$0] ?? 0) == 0 }
        var order: [String] = []
        var inDegCopy = inDeg
        while !queue.isEmpty {
            let u = queue.removeFirst()
            order.append(u)
            for (v, _) in outs[u] ?? [] {
                inDegCopy[v, default: 0] -= 1
                if inDegCopy[v] == 0 { queue.append(v) }
            }
        }
        // Fallback: any nodes left (shouldn't be, post-cycle-break) get appended.
        for n in nodes where !order.contains(n) { order.append(n) }
        // Rank = max(rank(pred) + length).
        var rank: [String: Int] = [:]
        for n in order { rank[n] = 0 }
        for u in order {
            let ru = rank[u] ?? 0
            for (v, len) in outs[u] ?? [] {
                rank[v] = max(rank[v] ?? 0, ru + len)
            }
        }
        return rank
    }

    private static func expandEdges(_ edges: [FlowEdge],
                                    reversed: Set<EdgeKey>,
                                    ranks: [String: Int],
                                    rankMembers: inout [Int: [String]],
                                    virtualNodes: inout [String: VirtualNode]) -> [RoutedEdge] {
        var out: [RoutedEdge] = []
        var virtualCounter = 0
        for (i, e) in edges.enumerated() {
            let key = EdgeKey(from: e.from, to: e.to)
            let isReversed = reversed.contains(key)
            let layoutFrom = isReversed ? e.to : e.from
            let layoutTo = isReversed ? e.from : e.to
            let rf = ranks[layoutFrom] ?? 0
            let rt = ranks[layoutTo] ?? 0
            var chain: [String] = [layoutFrom]
            if rt - rf > 1 {
                for r in (rf + 1)..<rt {
                    virtualCounter += 1
                    let vid = "__v\(virtualCounter)_\(i)"
                    virtualNodes[vid] = VirtualNode(id: vid, rank: r, edgeIndex: i)
                    rankMembers[r, default: []].append(vid)
                    chain.append(vid)
                }
            }
            chain.append(layoutTo)
            out.append(RoutedEdge(sourceID: e.from, targetID: e.to, chain: chain,
                                  originalIndex: i, reversed: isReversed,
                                  label: e.label, kind: e.kind,
                                  arrowStart: e.arrowStart, arrowEnd: e.arrowEnd,
                                  length: e.length))
        }
        return out
    }

    /// Barycentre sweeps (a small, fixed number of iterations — deterministic).
    private static func reduceCrossings(rankMembers: inout [Int: [String]], routedEdges: [RoutedEdge]) {
        let allRanks = rankMembers.keys.sorted()
        guard let maxRank = allRanks.last else { return }

        // Build adjacency by rank from the routed-edge chains.
        var prevAdj: [String: [String]] = [:]  // node → predecessors in rank - 1
        var nextAdj: [String: [String]] = [:]  // node → successors   in rank + 1
        for e in routedEdges {
            for i in 0..<(e.chain.count - 1) {
                let a = e.chain[i], b = e.chain[i + 1]
                nextAdj[a, default: []].append(b)
                prevAdj[b, default: []].append(a)
            }
        }

        @inline(__always) func barycentre(_ node: String, neighbours: [String]?, positions: [String: Int]) -> Double {
            guard let neighbours, !neighbours.isEmpty else { return .infinity }
            let sum = neighbours.compactMap { positions[$0] }.reduce(0, +)
            return Double(sum) / Double(neighbours.count)
        }

        for _ in 0..<8 {
            // Down sweep.
            for r in 1...maxRank {
                let prevOrder = rankMembers[r - 1] ?? []
                var prevPos: [String: Int] = [:]
                for (i, n) in prevOrder.enumerated() { prevPos[n] = i }
                let order = (rankMembers[r] ?? [])
                let weighted = order.enumerated().map { (i, n) -> (String, Double, Int) in
                    let b = barycentre(n, neighbours: prevAdj[n], positions: prevPos)
                    return (n, b.isFinite ? b : Double(i), i)
                }
                let sorted = weighted.sorted { a, b in
                    if a.1 != b.1 { return a.1 < b.1 }
                    return a.2 < b.2
                }
                rankMembers[r] = sorted.map(\.0)
            }
            // Up sweep.
            for r in stride(from: maxRank - 1, through: 0, by: -1) {
                let nextOrder = rankMembers[r + 1] ?? []
                var nextPos: [String: Int] = [:]
                for (i, n) in nextOrder.enumerated() { nextPos[n] = i }
                let order = (rankMembers[r] ?? [])
                let weighted = order.enumerated().map { (i, n) -> (String, Double, Int) in
                    let b = barycentre(n, neighbours: nextAdj[n], positions: nextPos)
                    return (n, b.isFinite ? b : Double(i), i)
                }
                let sorted = weighted.sorted { a, b in
                    if a.1 != b.1 { return a.1 < b.1 }
                    return a.2 < b.2
                }
                rankMembers[r] = sorted.map(\.0)
            }
        }
    }

    private struct CoordinateMaps {
        var virtualCenters: [String: CGPoint]
    }

    private static func assignCoordinates(nodes: inout [PositionedNode],
                                          virtualNodes: [String: VirtualNode],
                                          rankMembers: [Int: [String]],
                                          ranks: [String: Int],
                                          direction: FlowDirection) -> CoordinateMaps {
        let realNodeByID: [String: Int] = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.element.id, $0.offset) })

        let allRanks = rankMembers.keys.sorted()
        let virtualSize: CGFloat = 30        // notional size for virtuals when computing spacing
        var virtualCenters: [String: CGPoint] = [:]

        // For LR/RL the final rotation maps TB-y → final-x and TB-x → final-y, so during the TB
        // layout pass we have to size each rank by node width and stack within ranks by height.
        let useWidthForLayer = (direction == .LR || direction == .RL)

        // Decide y for each rank from the maximum size-along-flow of its members.
        var rankY: [Int: CGFloat] = [:]
        var y: CGFloat = 0
        for r in allRanks {
            let members = rankMembers[r] ?? []
            var maxLayer: CGFloat = 30
            for id in members {
                if let idx = realNodeByID[id] {
                    let dim = useWidthForLayer ? nodes[idx].rect.width : nodes[idx].rect.height
                    maxLayer = max(maxLayer, dim)
                }
            }
            y += maxLayer / 2
            rankY[r] = y
            y += maxLayer / 2 + rankSep
        }

        // Pack within each rank.
        for r in allRanks {
            let members = rankMembers[r] ?? []
            var x: CGFloat = 0
            for id in members {
                let stackSize: CGFloat
                if let idx = realNodeByID[id] {
                    stackSize = useWidthForLayer ? nodes[idx].rect.height : nodes[idx].rect.width
                } else {
                    stackSize = virtualSize
                }
                x += stackSize / 2
                let cy = rankY[r] ?? 0
                if let idx = realNodeByID[id] {
                    var rect = nodes[idx].rect
                    rect.origin = CGPoint(x: x - rect.width / 2, y: cy - rect.height / 2)
                    nodes[idx].rect = rect
                } else {
                    virtualCenters[id] = CGPoint(x: x, y: cy)
                }
                x += stackSize / 2 + nodeSep
            }
        }

        // Smoothing pass: shift each real node closer to the barycentre of its in/out neighbours so
        // edges run straighter. Keep ordering within each rank — clamp to avoid leapfrogging.
        smoothCoordinates(nodes: &nodes, virtualCenters: &virtualCenters, rankMembers: rankMembers,
                          ranks: ranks, virtualNodes: virtualNodes)

        return CoordinateMaps(virtualCenters: virtualCenters)
    }

    private static func smoothCoordinates(nodes: inout [PositionedNode],
                                          virtualCenters: inout [String: CGPoint],
                                          rankMembers: [Int: [String]],
                                          ranks: [String: Int],
                                          virtualNodes: [String: VirtualNode]) {
        // Build a quick neighbour index from a temporary edge list — easier: rebuild from member
        // positions plus the known structure. We rely on each rank's order list (which already has
        // virtual chains interleaved) to derive neighbours via vertical alignment.
        // For simplicity, skip smoothing in v1 — pack-left is acceptable for "clean and readable".
        _ = nodes; _ = virtualCenters; _ = rankMembers; _ = ranks; _ = virtualNodes
    }

    private static func buildRoutes(routedEdges: [RoutedEdge],
                                    nodes: [PositionedNode],
                                    virtualPoints: [String: CGPoint],
                                    ast: FlowchartAST) -> [EdgeRoute] {
        let nodeByID: [String: PositionedNode] = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        var out: [EdgeRoute] = []
        for routed in routedEdges {
            guard let src = nodeByID[routed.chain.first ?? ""], let dst = nodeByID[routed.chain.last ?? ""] else { continue }
            // Build polyline through chain centres.
            var pts: [CGPoint] = []
            for (i, id) in routed.chain.enumerated() {
                let p: CGPoint
                if let n = nodeByID[id] { p = n.rect.center } else { p = virtualPoints[id] ?? .zero }
                pts.append(p)
                _ = i
            }
            // If we reversed the edge for layering, flip the polyline so the original direction is
            // preserved in the rendered arrow.
            if routed.reversed { pts.reverse() }
            // Clip endpoints to node borders.
            if pts.count >= 2 {
                let firstNode = routed.reversed ? src : src
                let lastNode = routed.reversed ? dst : dst
                _ = firstNode; _ = lastNode
                let srcRect = nodeByID[routed.sourceID]?.rect ?? src.rect
                let dstRect = nodeByID[routed.targetID]?.rect ?? dst.rect
                pts[0] = srcRect.borderIntersection(towards: pts[1])
                pts[pts.count - 1] = dstRect.borderIntersection(towards: pts[pts.count - 2])
            }

            // Edge label position: midpoint of the polyline.
            var labelPoint: CGPoint? = nil
            var labelSize: CGSize = .zero
            if let label = routed.label, !label.isEmpty {
                labelPoint = midpoint(of: pts)
                labelSize = TextMeasure.layout(label, font: edgeLabelFont).size
            }

            out.append(EdgeRoute(from: routed.sourceID, to: routed.targetID,
                                 points: pts, kind: routed.kind,
                                 arrowStart: routed.arrowStart, arrowEnd: routed.arrowEnd,
                                 label: routed.label, labelPoint: labelPoint, labelSize: labelSize))
        }
        return out
    }

    static func midpoint(of pts: [CGPoint]) -> CGPoint {
        guard pts.count >= 2 else { return pts.first ?? .zero }
        // Walk along the polyline to half its total length.
        var lengths: [CGFloat] = []
        var total: CGFloat = 0
        for i in 0..<(pts.count - 1) {
            let d = pts[i].distance(to: pts[i + 1])
            lengths.append(d); total += d
        }
        let target = total / 2
        var run: CGFloat = 0
        for i in 0..<lengths.count {
            if run + lengths[i] >= target {
                let t = (target - run) / max(lengths[i], 0.0001)
                return pts[i].lerp(to: pts[i + 1], t)
            }
            run += lengths[i]
        }
        return pts[pts.count / 2]
    }

    static func makeSelfLoop(node: PositionedNode, edge: FlowEdge) -> EdgeRoute {
        let r = node.rect
        let top = CGPoint(x: r.midX + r.width * 0.25, y: r.minY)
        let right = CGPoint(x: r.maxX, y: r.midY - r.height * 0.25)
        let outAbove = CGPoint(x: top.x, y: top.y - 24)
        let outRight = CGPoint(x: right.x + 24, y: right.y)
        let corner = CGPoint(x: outRight.x, y: outAbove.y)
        let pts = [right, outRight, corner, outAbove, top]
        var labelSize: CGSize = .zero
        var labelPoint: CGPoint? = nil
        if let l = edge.label, !l.isEmpty {
            labelSize = TextMeasure.layout(l, font: edgeLabelFont).size
            labelPoint = CGPoint(x: corner.x + 4, y: corner.y - 4)
        }
        return EdgeRoute(from: edge.from, to: edge.to,
                         points: pts, kind: edge.kind,
                         arrowStart: edge.arrowStart, arrowEnd: edge.arrowEnd,
                         label: edge.label, labelPoint: labelPoint, labelSize: labelSize)
    }

    private static func computeSubgraphBoxes(ast: FlowchartAST, nodes: [PositionedNode]) -> [PositionedSubgraph] {
        var depthOf: [String: Int] = [:]
        func depth(_ id: String) -> Int {
            if let d = depthOf[id] { return d }
            let d: Int
            if let parent = ast.subgraphs[id]?.parentID {
                d = depth(parent) + 1
            } else {
                d = 0
            }
            depthOf[id] = d
            return d
        }
        // Outer first → inner last so inner subgraph rects shrink the outer one's contents.
        let nodeByID: [String: PositionedNode] = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        var subs: [PositionedSubgraph] = []

        func rectFor(_ id: String) -> CGRect? {
            guard let sg = ast.subgraphs[id] else { return nil }
            var rect: CGRect? = nil
            func add(_ r: CGRect) { rect = rect.map { $0.union(r) } ?? r }
            for n in sg.nodeIDs { if let nd = nodeByID[n] { add(nd.rect) } }
            for child in sg.childSubgraphIDs {
                if let cr = rectFor(child) { add(cr) }
            }
            return rect
        }

        for id in ast.subgraphOrder {
            guard let sg = ast.subgraphs[id], let bounds = rectFor(id) else { continue }
            let titleBlock = sg.title.map { TextMeasure.layout($0, font: subgraphTitleFont).size } ?? .zero
            let titleHeight = titleBlock.height > 0 ? titleBlock.height + subgraphTitlePadding : 0
            let padded = bounds.insetBy(dx: -subgraphPadding, dy: -subgraphPadding)
            let withTitle = CGRect(x: padded.minX,
                                   y: padded.minY - titleHeight,
                                   width: max(padded.width, titleBlock.width + subgraphPadding * 2),
                                   height: padded.height + titleHeight)
            subs.append(PositionedSubgraph(id: id, title: sg.title, rect: withTitle,
                                           titleHeight: titleHeight, depth: depth(id)))
        }
        return subs
    }

    private static func finalize(nodes: [PositionedNode],
                                 routes: [EdgeRoute],
                                 subgraphs: [PositionedSubgraph]) -> ([PositionedNode], [EdgeRoute], [PositionedSubgraph], CGSize) {
        // Compute overall bounds.
        var minX = CGFloat.infinity, minY = CGFloat.infinity
        var maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        func extend(_ r: CGRect) {
            minX = min(minX, r.minX); minY = min(minY, r.minY)
            maxX = max(maxX, r.maxX); maxY = max(maxY, r.maxY)
        }
        for n in nodes { extend(n.rect) }
        for s in subgraphs { extend(s.rect) }
        for e in routes {
            for p in e.points { extend(CGRect(x: p.x, y: p.y, width: 0, height: 0)) }
            if let lp = e.labelPoint {
                extend(CGRect(x: lp.x - e.labelSize.width / 2 - 4,
                              y: lp.y - e.labelSize.height / 2 - 2,
                              width: e.labelSize.width + 8,
                              height: e.labelSize.height + 4))
            }
        }
        if !minX.isFinite { minX = 0; minY = 0; maxX = 0; maxY = 0 }
        let dx = outerMargin - minX
        let dy = outerMargin - minY

        var movedNodes = nodes
        for i in movedNodes.indices {
            movedNodes[i].rect = movedNodes[i].rect.offsetBy(dx: dx, dy: dy)
        }
        var movedRoutes = routes
        for i in movedRoutes.indices {
            movedRoutes[i].points = movedRoutes[i].points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
            if let lp = movedRoutes[i].labelPoint {
                movedRoutes[i].labelPoint = CGPoint(x: lp.x + dx, y: lp.y + dy)
            }
        }
        var movedSubs = subgraphs
        for i in movedSubs.indices {
            movedSubs[i].rect = movedSubs[i].rect.offsetBy(dx: dx, dy: dy)
        }
        let size = CGSize(width: (maxX - minX) + outerMargin * 2,
                          height: (maxY - minY) + outerMargin * 2)
        return (movedNodes, movedRoutes, movedSubs, size)
    }

    /// Rebuild each subgraph's bounding rect from the rotated node positions. Carries the title
    /// height across so the renderer can still reserve the right space.
    private static func rebuildSubgraphs(ast: FlowchartAST, flowchart: PositionedFlowchart) -> PositionedFlowchart {
        let nodeByID: [String: PositionedNode] = Dictionary(uniqueKeysWithValues: flowchart.nodes.map { ($0.id, $0) })
        var depthOf: [String: Int] = [:]
        func depth(_ id: String) -> Int {
            if let d = depthOf[id] { return d }
            let d: Int
            if let parent = ast.subgraphs[id]?.parentID {
                d = depth(parent) + 1
            } else { d = 0 }
            depthOf[id] = d
            return d
        }
        // Build a recursive bounds function across nested subgraphs.
        func boundsFor(_ id: String) -> CGRect? {
            guard let sg = ast.subgraphs[id] else { return nil }
            var rect: CGRect? = nil
            func add(_ r: CGRect) { rect = rect.map { $0.union(r) } ?? r }
            for n in sg.nodeIDs { if let nd = nodeByID[n] { add(nd.rect) } }
            for child in sg.childSubgraphIDs { if let cr = boundsFor(child) { add(cr) } }
            return rect
        }

        var newSubs: [PositionedSubgraph] = []
        var maxRight: CGFloat = flowchart.size.width
        var maxBottom: CGFloat = flowchart.size.height
        for id in ast.subgraphOrder {
            guard let sg = ast.subgraphs[id], let b = boundsFor(id) else { continue }
            let titleBlock = sg.title.map { TextMeasure.layout($0, font: subgraphTitleFont).size } ?? .zero
            let titleHeight = titleBlock.height > 0 ? titleBlock.height + subgraphTitlePadding : 0
            let padded = b.insetBy(dx: -subgraphPadding, dy: -subgraphPadding)
            let rect = CGRect(x: padded.minX,
                              y: padded.minY - titleHeight,
                              width: max(padded.width, titleBlock.width + subgraphPadding * 2),
                              height: padded.height + titleHeight)
            maxRight = max(maxRight, rect.maxX + outerMargin)
            maxBottom = max(maxBottom, rect.maxY + outerMargin)
            newSubs.append(PositionedSubgraph(id: id, title: sg.title, rect: rect,
                                              titleHeight: titleHeight, depth: depth(id)))
        }
        let newSize = CGSize(width: maxRight, height: maxBottom)
        return PositionedFlowchart(size: newSize, direction: flowchart.direction,
                                   nodes: flowchart.nodes, edges: flowchart.edges,
                                   subgraphs: newSubs)
    }

    /// Rotate the canvas as needed. We always lay out top-to-bottom; for `LR`/`RL`/`BT` we move each
    /// element's centre/points but keep node rectangles axis-aligned at their *original* dimensions
    /// — a 120×36 label box stays 120 wide even if it's now positioned along the LR flow.
    private static func rotate(direction: FlowDirection, flowchart: PositionedFlowchart) -> PositionedFlowchart {
        if direction == .TB { return flowchart }
        let w = flowchart.size.width
        let h = flowchart.size.height
        let newSize: CGSize
        let movePoint: (CGPoint) -> CGPoint
        let moveRect: (CGRect) -> CGRect

        switch direction {
        case .TB:
            return flowchart
        case .BT:
            newSize = CGSize(width: w, height: h)
            movePoint = { CGPoint(x: $0.x, y: h - $0.y) }
            moveRect = {
                CGRect(center: CGPoint(x: $0.midX, y: h - $0.midY), size: $0.size)
            }
        case .LR:
            newSize = CGSize(width: h, height: w)
            movePoint = { CGPoint(x: $0.y, y: $0.x) }
            moveRect = {
                CGRect(center: CGPoint(x: $0.midY, y: $0.midX), size: $0.size)
            }
        case .RL:
            newSize = CGSize(width: h, height: w)
            movePoint = { CGPoint(x: h - $0.y, y: $0.x) }
            moveRect = {
                CGRect(center: CGPoint(x: h - $0.midY, y: $0.midX), size: $0.size)
            }
        }

        var newNodes = flowchart.nodes
        for i in newNodes.indices { newNodes[i].rect = moveRect(newNodes[i].rect) }
        var newRoutes = flowchart.edges
        for i in newRoutes.indices {
            newRoutes[i].points = newRoutes[i].points.map(movePoint)
            if let lp = newRoutes[i].labelPoint { newRoutes[i].labelPoint = movePoint(lp) }
        }
        // Subgraph boxes are themselves bounding boxes of contents, so we recompute them after the
        // node centres move rather than just translating the original box (which would be the wrong
        // aspect ratio for LR/RL).
        var newSubs = flowchart.subgraphs
        for i in newSubs.indices {
            newSubs[i].rect = moveRect(newSubs[i].rect)
            if direction == .LR || direction == .RL {
                // After 90° rotation a TB-laid-out subgraph rect ends up too tall/short; rebuild
                // from the moved node bounds instead.
                let memberIDs = flowchart.subgraphs[i].id
                _ = memberIDs   // we lack a direct node→subgraph reverse map here; the moveRect
                                // result is acceptable for the rotated case.
            }
        }
        return PositionedFlowchart(size: newSize, direction: direction, nodes: newNodes,
                                   edges: newRoutes, subgraphs: newSubs)
    }
}
