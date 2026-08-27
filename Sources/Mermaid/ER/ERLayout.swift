import CoreGraphics
import Foundation
import MermaidLayoutDagre

// MARK: - Entity metrics

/// Which attribute-table columns an entity actually needs. `type` and `name` are always present;
/// the other two appear only when at least one attribute uses them.
enum ERAttributeColumn {
    case type, name, keys, comment
}

/// Pre-computed geometry for one entity box. Shared by the layout (which needs `size` to hand to
/// dagre) and the renderer (which needs the row/column splits and the per-cell text).
struct EREntityMetrics {
    var size: CGSize
    var headerHeight: CGFloat
    var rowHeight: CGFloat
    var columns: [ERAttributeColumn]
    /// Laid-out column widths, in `columns` order. Sums to `size.width`.
    var columnWidths: [CGFloat]
    var nameBlock: TextMeasure.Block
    /// Cell text per row, in `columns` order.
    var cells: [[String]]

    static let titleFont = FontSpec(family: FontSpec.defaultFamily, size: 15, weight: .bold)
    static let attributeFont = FontSpec(family: FontSpec.defaultFamily, size: 13)

    static let cellHPad: CGFloat = 10        // text inset on each side of a table cell
    static let headerHPad: CGFloat = 14
    static let headerVPad: CGFloat = 8
    static let rowVPad: CGFloat = 5
    static let minWidth: CGFloat = 100       // mermaid's `er.minEntityWidth`
    static let minBareHeight: CGFloat = 44   // an entity with no attribute block

    static func measure(_ entity: EREntity) -> EREntityMetrics {
        let nameBlock = TextMeasure.layout(entity.name.isEmpty ? entity.id : entity.name, font: titleFont)
        let headerHeight = ceil(nameBlock.size.height + headerVPad * 2)

        var columns: [ERAttributeColumn] = [.type, .name]
        if entity.attributes.contains(where: { !$0.keys.isEmpty }) { columns.append(.keys) }
        if entity.attributes.contains(where: { !($0.comment ?? "").isEmpty }) { columns.append(.comment) }

        let cells: [[String]] = entity.attributes.map { attr in
            columns.map { column in
                switch column {
                case .type: return attr.type
                case .name: return attr.name
                case .keys: return attr.keys.joined(separator: ", ")
                case .comment: return attr.comment ?? ""
                }
            }
        }

        guard !entity.attributes.isEmpty else {
            let width = max(minWidth, nameBlock.size.width + headerHPad * 2)
            return EREntityMetrics(size: CGSize(width: ceil(width), height: max(headerHeight, minBareHeight)),
                                   headerHeight: max(headerHeight, minBareHeight),
                                   rowHeight: 0, columns: [], columnWidths: [],
                                   nameBlock: nameBlock, cells: [])
        }

        var columnWidths = columns.indices.map { c -> CGFloat in
            let widest = cells.map { TextMeasure.lineWidth($0[c], font: attributeFont) }.max() ?? 0
            return ceil(widest + cellHPad * 2)
        }
        let tableWidth = columnWidths.reduce(0, +)
        let width = max(minWidth, tableWidth, ceil(nameBlock.size.width + headerHPad * 2))
        // Any slack goes to the last column so the table always fills the box and the earlier
        // columns stay left-aligned at their natural widths.
        if width > tableWidth, let last = columnWidths.indices.last {
            columnWidths[last] += width - tableWidth
        }

        let rowHeight = ceil(TextMeasure.layout("Mg", font: attributeFont).lineHeight + rowVPad * 2)
        let height = headerHeight + rowHeight * CGFloat(entity.attributes.count)

        return EREntityMetrics(size: CGSize(width: width, height: height),
                               headerHeight: headerHeight,
                               rowHeight: rowHeight,
                               columns: columns,
                               columnWidths: columnWidths,
                               nameBlock: nameBlock,
                               cells: cells)
    }
}

// MARK: - Layout

/// Lays out an ER diagram with the vendored dagre (`MermaidLayoutDagre`), the same backend the
/// flowchart and class pipelines use: entity boxes are nodes, relationships are edges. If dagre
/// throws on a degenerate graph we fall back to a plain row layout rather than failing.
enum ERLayout {

    static let rankSep: CGFloat = 70
    static let nodeSep: CGFloat = 60
    static let outerMargin: CGFloat = 16
    static let labelFont = FontSpec(family: FontSpec.defaultFamily, size: 12)
    static let labelPad: CGFloat = 4

    /// The background box a relationship label occupies. Shared with the renderer so the canvas
    /// bounds and the drawn box can't drift apart.
    static func labelRect(_ text: String, at point: CGPoint) -> CGRect {
        let size = TextMeasure.layout(text, font: labelFont).size
        return CGRect(center: point,
                      size: CGSize(width: size.width + labelPad * 2, height: size.height + labelPad))
    }

    static func layout(_ ast: ERDiagramAST) -> PositionedERDiagram {
        let metrics: [String: EREntityMetrics] = Dictionary(
            uniqueKeysWithValues: ast.entityOrder.compactMap { id in
                ast.entities[id].map { (id, EREntityMetrics.measure($0)) }
            }
        )
        guard !ast.entityOrder.isEmpty else {
            return PositionedERDiagram(size: CGSize(width: 48, height: 48), entities: [], relationships: [])
        }
        if let positioned = try? dagreLayout(ast, metrics: metrics) { return positioned }
        return fallbackLayout(ast, metrics: metrics)
    }

    // MARK: dagre path

    private static func dagreLayout(_ ast: ERDiagramAST, metrics: [String: EREntityMetrics]) throws -> PositionedERDiagram {
        let g: DagreGraph = Graph(options: GraphOptions(directed: true, multigraph: true, compound: false))
        let opts = LayoutOptions()
        opts.rankdir = dagreDir(ast.direction)
        opts.nodesep = Double(nodeSep)
        opts.ranksep = Double(rankSep)
        opts.marginx = Double(outerMargin)
        opts.marginy = Double(outerMargin)
        g.setGraph(opts)

        for id in ast.entityOrder {
            guard let m = metrics[id] else { continue }
            _ = g.setNode(id, label: DagreNodeLabel(width: Double(m.size.width), height: Double(m.size.height)))
        }

        // Relationships have no inherent hierarchy, so the edge always runs lhs → rhs.
        for (i, rel) in ast.relationships.enumerated() where rel.lhsID != rel.rhsID {
            let label = DagreEdgeLabel(minlen: 1, weight: 1)
            if let text = rel.label, !text.isEmpty {
                let sz = TextMeasure.layout(text, font: labelFont).size
                label.width = Double(sz.width + 10)
                label.height = Double(sz.height + 6)
            }
            _ = try g.setEdge(rel.lhsID, rel.rhsID, label: label, name: "r\(i)")
        }

        try SwiftDagreLayout.layout(g, options: opts)

        var entities: [PositionedEREntity] = []
        var rectByID: [String: CGRect] = [:]
        for id in ast.entityOrder {
            guard let entity = ast.entities[id], let m = metrics[id], let dl = g.node(id) else { continue }
            let rect = CGRect(center: CGPoint(x: CGFloat(dl.x), y: CGFloat(dl.y)), size: m.size)
            rectByID[id] = rect
            entities.append(PositionedEREntity(entity: entity, rect: rect))
        }

        var relationships: [PositionedERRelationship] = []
        for (i, rel) in ast.relationships.enumerated() {
            guard let r1 = rectByID[rel.lhsID], let r2 = rectByID[rel.rhsID] else { continue }
            if rel.lhsID == rel.rhsID {
                relationships.append(makeSelfLoop(rel: rel, rect: r1))
                continue
            }
            guard let dl = g.edge(EdgeId(v: rel.lhsID, w: rel.rhsID, name: "r\(i)")) else { continue }
            var pts = dl.points.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }
            if pts.count < 2 { pts = [r1.center, r2.center] }
            pts[0] = r1.borderIntersection(towards: pts[1])
            pts[pts.count - 1] = r2.borderIntersection(towards: pts[pts.count - 2])

            let labelPoint = (rel.label?.isEmpty == false) ? CGPoint(x: CGFloat(dl.x), y: CGFloat(dl.y)) : nil
            relationships.append(positioned(rel, points: pts, labelPoint: labelPoint))
        }

        return finish(entities: entities, relationships: relationships)
    }

    // MARK: fallback path (dagre unavailable / threw)

    private static func fallbackLayout(_ ast: ERDiagramAST, metrics: [String: EREntityMetrics]) -> PositionedERDiagram {
        var entities: [PositionedEREntity] = []
        var rectByID: [String: CGRect] = [:]
        var x = outerMargin, y = outerMargin, rowHeight: CGFloat = 0, col = 0
        for id in ast.entityOrder {
            guard let entity = ast.entities[id], let m = metrics[id] else { continue }
            if col == 3 { x = outerMargin; y += rowHeight + rankSep; rowHeight = 0; col = 0 }
            let rect = CGRect(x: x, y: y, width: m.size.width, height: m.size.height)
            rectByID[id] = rect
            entities.append(PositionedEREntity(entity: entity, rect: rect))
            x += m.size.width + nodeSep
            rowHeight = max(rowHeight, m.size.height)
            col += 1
        }
        var relationships: [PositionedERRelationship] = []
        for rel in ast.relationships {
            guard let r1 = rectByID[rel.lhsID], let r2 = rectByID[rel.rhsID] else { continue }
            if rel.lhsID == rel.rhsID { relationships.append(makeSelfLoop(rel: rel, rect: r1)); continue }
            let pts = [r1.borderIntersection(towards: r2.center), r2.borderIntersection(towards: r1.center)]
            relationships.append(positioned(rel, points: pts, labelPoint: pts[0].lerp(to: pts[1], 0.5)))
        }
        return finish(entities: entities, relationships: relationships)
    }

    // MARK: shared helpers

    private static func positioned(_ rel: ERRelationship, points: [CGPoint], labelPoint: CGPoint?) -> PositionedERRelationship {
        PositionedERRelationship(lhsID: rel.lhsID, rhsID: rel.rhsID, points: points,
                                 lhsCardinality: rel.lhsCardinality, rhsCardinality: rel.rhsCardinality,
                                 lineStyle: rel.lineStyle, label: rel.label, labelPoint: labelPoint)
    }

    /// Union all geometry, shift so the content starts at `outerMargin`, and report the canvas size.
    private static func finish(entities: [PositionedEREntity],
                               relationships: [PositionedERRelationship]) -> PositionedERDiagram {
        var minX = CGFloat.infinity, minY = CGFloat.infinity, maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        func extend(_ r: CGRect) { minX = min(minX, r.minX); minY = min(minY, r.minY); maxX = max(maxX, r.maxX); maxY = max(maxY, r.maxY) }
        for e in entities { extend(e.rect) }
        for rel in relationships {
            for p in rel.points { extend(CGRect(x: p.x, y: p.y, width: 0, height: 0)) }
            if let text = rel.label, !text.isEmpty, let pt = rel.labelPoint { extend(labelRect(text, at: pt)) }
        }
        if !minX.isFinite {
            return PositionedERDiagram(size: CGSize(width: 48, height: 48), entities: entities, relationships: relationships)
        }

        let dx = outerMargin - minX, dy = outerMargin - minY
        var movedEntities = entities, movedRelationships = relationships
        if dx != 0 || dy != 0 {
            for i in movedEntities.indices { movedEntities[i].rect = movedEntities[i].rect.offsetBy(dx: dx, dy: dy) }
            for i in movedRelationships.indices {
                movedRelationships[i].points = movedRelationships[i].points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
                movedRelationships[i].labelPoint = movedRelationships[i].labelPoint.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
            }
        }
        let size = CGSize(width: (maxX - minX) + outerMargin * 2, height: (maxY - minY) + outerMargin * 2)
        return PositionedERDiagram(size: size, entities: movedEntities, relationships: movedRelationships)
    }

    /// A recursive relationship (`EMPLOYEE ||--o{ EMPLOYEE : manages`) loops out of the right edge.
    private static func makeSelfLoop(rel: ERRelationship, rect r: CGRect) -> PositionedERRelationship {
        let inset = min(r.height * 0.3, 24)
        let ext: CGFloat = 34
        let p0 = CGPoint(x: r.maxX, y: r.minY + inset)
        let p1 = CGPoint(x: r.maxX + ext, y: r.minY + inset)
        let p2 = CGPoint(x: r.maxX + ext, y: r.minY - ext * 0.6)
        let p3 = CGPoint(x: min(r.maxX, r.midX + r.width * 0.25), y: r.minY - ext * 0.6)
        let pts = [p0, p1, p2, p3, CGPoint(x: p3.x, y: r.minY)]
        return positioned(rel, points: pts, labelPoint: p2)
    }

    private static func dagreDir(_ d: ERDirection) -> LayoutOptions.RankDirection {
        switch d {
        case .TB: return .topBottom
        case .BT: return .bottomTop
        case .LR: return .leftRight
        case .RL: return .rightLeft
        }
    }
}
