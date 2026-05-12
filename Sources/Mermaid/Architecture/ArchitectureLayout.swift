import CoreGraphics
import Foundation

// MARK: - Positioned model

struct PositionedArchNode {
    let id: String
    /// For junctions this is a zero-size rect at the connection point.
    var rect: CGRect
    let title: String
    let icon: ArchIcon
    let isJunction: Bool
    let groupID: String?
}

struct PositionedArchGroup {
    let id: String
    let title: String
    let icon: ArchIcon
    var rect: CGRect
    /// Vertical room reserved at the top for the title.
    let titleHeight: CGFloat
    let depth: Int
}

struct PositionedArchEdge {
    var points: [CGPoint]
    let arrowStart: Bool
    let arrowEnd: Bool
}

struct PositionedArchitecture {
    let size: CGSize
    let nodes: [PositionedArchNode]
    let groups: [PositionedArchGroup]
    let edges: [PositionedArchEdge]
}

// MARK: - Layout

/// Deterministic grid layout. Mermaid uses a force-directed grid (cytoscape/fcose); we instead
/// propagate the edges' side specifiers as relative-position constraints over an integer grid, which
/// is deterministic and good enough for the diagram sizes architecture diagrams target. Group boxes
/// are bounding boxes of their members (nested groups handled recursively).
enum ArchitectureLayout {

    static let serviceW: CGFloat = 100
    static let serviceH: CGFloat = 100
    static let iconBox: CGFloat = 44          // glyph size inside a service cell
    static let cellGapX: CGFloat = 36
    static let cellGapY: CGFloat = 36
    static let groupPadding: CGFloat = 18
    static let groupTitlePadding: CGFloat = 6
    static let edgeStub: CGFloat = 18
    static let outerMargin: CGFloat = 20
    static let labelFont = FontSpec(family: FontSpec.defaultFamily, size: 13)
    static let groupTitleFont = FontSpec(family: FontSpec.defaultFamily, size: 14, weight: .bold)

    private struct Cell: Hashable { var c: Int; var r: Int }

    static func layout(_ ast: ArchitectureAST) -> PositionedArchitecture {
        // 1. Assign each service/junction a grid cell.
        var pos: [String: Cell] = [:]
        var occupied: Set<Cell> = []

        // Adjacency for BFS (only "node ↔ node" edges; group-marked endpoints still constrain the
        // underlying nodes, which is a reasonable approximation).
        var adjacency: [String: [(neighbour: String, fromSide: ArchSide)]] = [:]
        for edge in ast.edges {
            guard ast.services[edge.lhs.id] != nil, ast.services[edge.rhs.id] != nil else { continue }
            adjacency[edge.lhs.id, default: []].append((edge.rhs.id, edge.lhs.side))
            adjacency[edge.rhs.id, default: []].append((edge.lhs.id, edge.rhs.side))
        }

        func place(_ id: String, at cell: Cell) {
            var c = cell
            // Resolve collisions by stepping one more cell along the original direction, then by a
            // small spiral. This keeps "intent" while never overlapping.
            if occupied.contains(c) {
                var found = false
                for radius in 1...6 {
                    for (dc, dr) in [(radius, 0), (0, radius), (-radius, 0), (0, -radius),
                                     (radius, radius), (-radius, radius), (radius, -radius), (-radius, -radius)] {
                        let cand = Cell(c: cell.c + dc, r: cell.r + dr)
                        if !occupied.contains(cand) { c = cand; found = true; break }
                    }
                    if found { break }
                }
            }
            pos[id] = c
            occupied.insert(c)
        }

        // BFS over connected components, in declaration order for determinism.
        var visited: Set<String> = []
        var nextFreeColForComponents = 0
        for startID in ast.serviceOrder where !visited.contains(startID) {
            guard adjacency[startID] != nil else { continue }   // isolated nodes handled later
            // Anchor this component to the right of previous components.
            let anchor = Cell(c: nextFreeColForComponents, r: 0)
            place(startID, at: anchor)
            visited.insert(startID)
            var queue = [startID]
            var head = 0
            while head < queue.count {
                let u = queue[head]; head += 1
                guard let uCell = pos[u] else { continue }
                for (v, side) in adjacency[u] ?? [] where !visited.contains(v) {
                    let (dc, dr) = side.gridDelta
                    place(v, at: Cell(c: uCell.c + dc, r: uCell.r + dr))
                    visited.insert(v)
                    queue.append(v)
                }
            }
            // Advance the anchor column past this component's bbox.
            let maxC = occupied.map(\.c).max() ?? nextFreeColForComponents
            nextFreeColForComponents = maxC + 2
        }

        // 2. Isolated services: lay them out per group so group boxes don't collapse on top of each
        //    other. Members of a group with placed siblings go next to them; otherwise a fresh row.
        let maxRowSoFar = occupied.map(\.r).max() ?? 0
        var groupFreeRow: [String?: Int] = [:]   // immediate-group → next free row for stragglers
        for id in ast.serviceOrder where pos[id] == nil {
            let svc = ast.services[id]!
            let key = svc.groupID
            // Find a column anchor: near an already-placed sibling in the same group, else fresh.
            let siblingCells = ast.serviceOrder
                .filter { ast.services[$0]?.groupID == key }
                .compactMap { pos[$0] }
            let baseCol = siblingCells.map(\.c).min() ?? (nextFreeColForComponents)
            let baseRow = groupFreeRow[key] ?? (siblingCells.map(\.r).max().map { $0 + 1 } ?? (maxRowSoFar + 2))
            // Pack horizontally on `baseRow`.
            var col = baseCol
            while occupied.contains(Cell(c: col, r: baseRow)) { col += 1 }
            place(id, at: Cell(c: col, r: baseRow))
            groupFreeRow[key] = (groupFreeRow[key] ?? baseRow)
            if key == nil { nextFreeColForComponents = max(nextFreeColForComponents, col + 2) }
        }

        // 3. Normalise grid to start at (0,0) and convert to pixel rects.
        let minC = pos.values.map(\.c).min() ?? 0
        let minR = pos.values.map(\.r).min() ?? 0
        func cellRect(_ cell: Cell) -> CGRect {
            let x = outerMargin + CGFloat(cell.c - minC) * (serviceW + cellGapX)
            let y = outerMargin + CGFloat(cell.r - minR) * (serviceH + cellGapY)
            return CGRect(x: x, y: y, width: serviceW, height: serviceH)
        }

        var nodes: [PositionedArchNode] = []
        var nodeRectByID: [String: CGRect] = [:]
        for id in ast.serviceOrder {
            guard let cell = pos[id], let svc = ast.services[id] else { continue }
            let full = cellRect(cell)
            let rect: CGRect
            if svc.isJunction {
                rect = CGRect(center: full.center, size: .zero)
            } else {
                rect = full
            }
            nodeRectByID[id] = rect
            nodes.append(PositionedArchNode(id: id, rect: rect, title: svc.title, icon: svc.icon,
                                            isJunction: svc.isJunction, groupID: svc.groupID))
        }

        // 4. Group boxes — innermost first so a parent's box encloses child boxes.
        var depthOf: [String: Int] = [:]
        func depth(_ id: String) -> Int {
            if let d = depthOf[id] { return d }
            let d = (ast.groups[id]?.parentID).map { depth($0) + 1 } ?? 0
            depthOf[id] = d
            return d
        }
        // Build child lists.
        var childServices: [String: [String]] = [:]
        for (id, svc) in ast.services { if let g = svc.groupID { childServices[g, default: []].append(id) } }
        var childGroups: [String: [String]] = [:]
        for (id, g) in ast.groups { if let p = g.parentID { childGroups[p, default: []].append(id) } }

        var groupRectByID: [String: CGRect] = [:]
        func boundsFor(_ id: String) -> CGRect? {
            var rect: CGRect? = nil
            func add(_ r: CGRect) {
                guard r.width >= 0, r.height >= 0 else { return }
                rect = rect.map { $0.union(r) } ?? r
            }
            for s in childServices[id] ?? [] {
                if let r = nodeRectByID[s] { add(r.insetBy(dx: -2, dy: -2)) }
            }
            for child in childGroups[id] ?? [] {
                if let r = boundsFor(child) { add(r) }
            }
            return rect
        }

        var groups: [PositionedArchGroup] = []
        // Process deepest first so nested boxes are computed before their parents query them.
        let orderedGroupIDs = ast.groupOrder.sorted { depth($0) > depth($1) }
        for id in orderedGroupIDs {
            guard let g = ast.groups[id] else { continue }
            guard let inner = boundsFor(id) else { continue }
            let titleBlock = g.title.isEmpty ? CGSize.zero : TextMeasure.layout(g.title, font: groupTitleFont).size
            let titleHeight = titleBlock.height > 0 ? titleBlock.height + groupTitlePadding * 2 : 0
            let padded = inner.insetBy(dx: -groupPadding, dy: -groupPadding)
            let rect = CGRect(x: padded.minX, y: padded.minY - titleHeight,
                              width: max(padded.width, titleBlock.width + groupPadding * 2),
                              height: padded.height + titleHeight)
            groupRectByID[id] = rect
            groups.append(PositionedArchGroup(id: id, title: g.title, icon: g.icon, rect: rect,
                                              titleHeight: titleHeight, depth: depth(id)))
        }
        // Re-sort groups outermost→innermost for stable rendering.
        groups.sort { $0.depth < $1.depth }

        // 5. Route edges.
        var edges: [PositionedArchEdge] = []
        for edge in ast.edges {
            guard let lhsRect = rect(for: edge.lhs, nodeRects: nodeRectByID, groupRects: groupRectByID, ast: ast),
                  let rhsRect = rect(for: edge.rhs, nodeRects: nodeRectByID, groupRects: groupRectByID, ast: ast) else {
                continue
            }
            let pts = route(from: lhsRect, side: edge.lhs.side, to: rhsRect, side: edge.rhs.side)
            edges.append(PositionedArchEdge(points: pts, arrowStart: edge.arrowLhs, arrowEnd: edge.arrowRhs))
        }

        // 6. Canvas size.
        var maxX: CGFloat = 0, maxY: CGFloat = 0
        var minX: CGFloat = .infinity, minY: CGFloat = .infinity
        func extend(_ r: CGRect) {
            minX = min(minX, r.minX); minY = min(minY, r.minY)
            maxX = max(maxX, r.maxX); maxY = max(maxY, r.maxY)
        }
        for n in nodes where !n.isJunction { extend(n.rect.insetBy(dx: 0, dy: -labelHeight())) }
        for g in groups { extend(g.rect) }
        for e in edges { for p in e.points { extend(CGRect(x: p.x, y: p.y, width: 0, height: 0)) } }
        if !minX.isFinite { minX = 0; minY = 0 }
        // Shift everything so the content starts at outerMargin.
        let dx = outerMargin - minX
        let dy = outerMargin - minY
        if dx != 0 || dy != 0 {
            for i in nodes.indices { nodes[i].rect = nodes[i].rect.offsetBy(dx: dx, dy: dy) }
            for i in groups.indices { groups[i].rect = groups[i].rect.offsetBy(dx: dx, dy: dy) }
            for i in edges.indices { edges[i].points = edges[i].points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) } }
        }
        let size = CGSize(width: (maxX - minX) + outerMargin * 2,
                          height: (maxY - minY) + outerMargin * 2)
        return PositionedArchitecture(size: size, nodes: nodes, groups: groups, edges: edges)
    }

    // MARK: - Edge geometry

    private static func rect(for end: ArchEdgeEnd,
                             nodeRects: [String: CGRect],
                             groupRects: [String: CGRect],
                             ast: ArchitectureAST) -> CGRect? {
        if end.viaGroup {
            // Connect to the containing group's boundary (or the node itself if it *is* a group).
            if let gr = groupRects[end.id] { return gr }
            if let svc = ast.services[end.id], let g = svc.groupID, let gr = groupRects[g] { return gr }
            return nodeRects[end.id]
        }
        if let nr = nodeRects[end.id] { return nr }
        if let gr = groupRects[end.id] { return gr }
        return nil
    }

    private static func attachPoint(_ rect: CGRect, side: ArchSide) -> CGPoint {
        if rect.width == 0 && rect.height == 0 { return rect.center }
        switch side {
        case .L: return CGPoint(x: rect.minX, y: rect.midY)
        case .R: return CGPoint(x: rect.maxX, y: rect.midY)
        case .T: return CGPoint(x: rect.midX, y: rect.minY)
        case .B: return CGPoint(x: rect.midX, y: rect.maxY)
        }
    }

    /// Orthogonal route: out of side `a` by a stub, into side `b` by a stub, with one or two bends.
    private static func route(from rectA: CGRect, side a: ArchSide,
                              to rectB: CGRect, side b: ArchSide) -> [CGPoint] {
        let p0 = attachPoint(rectA, side: a)
        let p3 = attachPoint(rectB, side: b)
        let p1 = p0 + (a.outward * edgeStub)
        let p2 = p3 + (b.outward * edgeStub)

        var pts: [CGPoint] = [p0, p1]
        switch (a.isHorizontal, b.isHorizontal) {
        case (true, true):
            let mx = (p1.x + p2.x) / 2
            pts.append(CGPoint(x: mx, y: p1.y))
            pts.append(CGPoint(x: mx, y: p2.y))
        case (false, false):
            let my = (p1.y + p2.y) / 2
            pts.append(CGPoint(x: p1.x, y: my))
            pts.append(CGPoint(x: p2.x, y: my))
        case (true, false):
            pts.append(CGPoint(x: p2.x, y: p1.y))
        case (false, true):
            pts.append(CGPoint(x: p1.x, y: p2.y))
        }
        pts.append(p2)
        pts.append(p3)

        // Drop consecutive duplicates / collinear midpoints.
        var cleaned: [CGPoint] = []
        for p in pts {
            if let last = cleaned.last, abs(last.x - p.x) < 0.01, abs(last.y - p.y) < 0.01 { continue }
            cleaned.append(p)
        }
        return cleaned
    }

    static func labelHeight() -> CGFloat {
        TextMeasure.layout("Mg", font: labelFont).size.height
    }
}
