import CoreGraphics
import Foundation
import MermaidLayoutDagre

// MARK: - Box metrics

/// Pre-computed geometry for a single class box. Shared by the layout (which needs the overall
/// `size` to hand to dagre) and the renderer (which needs the compartment splits and the per-line
/// blocks to draw text).
struct ClassBoxMetrics {
    var size: CGSize
    var headerHeight: CGFloat       // title compartment (annotation line + name)
    var membersHeight: CGFloat      // attributes compartment
    // methods compartment = size.height - headerHeight - membersHeight

    var annotationText: String?     // already wrapped in « »
    var annotationBlock: TextMeasure.Block?
    var nameBlock: TextMeasure.Block
    var memberBlocks: [TextMeasure.Block]
    var methodBlocks: [TextMeasure.Block]

    static let titleFont = FontSpec(family: FontSpec.defaultFamily, size: 15, weight: .bold)
    static let annotationFont = FontSpec(family: FontSpec.defaultFamily, size: 12, italic: true)
    static let memberFont = FontSpec(family: FontSpec.defaultFamily, size: 13)

    static let hPad: CGFloat = 14            // text inset on each side
    static let headerVPad: CGFloat = 7       // top & bottom of the title compartment
    static let compVPad: CGFloat = 6         // top & bottom of the member / method compartments
    static let minWidth: CGFloat = 80
    static let emptyCompartmentHeight: CGFloat = 12

    static func measure(_ def: ClassDef) -> ClassBoxMetrics {
        let annText = def.annotation.map { "\u{00AB}\($0)\u{00BB}" }   // «interface»
        let annBlock = annText.map { TextMeasure.layout($0, font: annotationFont) }
        let nameBlock = TextMeasure.layout(def.name.isEmpty ? def.id : def.name, font: titleFont)
        let memberBlocks = def.members.map { TextMeasure.layout($0.text, font: memberFont) }
        let methodBlocks = def.methods.map { TextMeasure.layout($0.text, font: memberFont) }

        let contentWidth = max(
            minWidth,
            annBlock?.size.width ?? 0,
            nameBlock.size.width,
            memberBlocks.map(\.size.width).max() ?? 0,
            methodBlocks.map(\.size.width).max() ?? 0
        )
        let width = contentWidth + hPad * 2

        let lineH = TextMeasure.layout("Mg", font: memberFont).lineHeight
        let headerHeight = ceil(headerVPad * 2 + (annBlock?.size.height ?? 0) + nameBlock.size.height)
        let membersHeight = ceil(def.members.isEmpty ? emptyCompartmentHeight
            : compVPad * 2 + lineH * CGFloat(def.members.count))
        let methodsHeight = ceil(def.methods.isEmpty ? emptyCompartmentHeight
            : compVPad * 2 + lineH * CGFloat(def.methods.count))

        return ClassBoxMetrics(size: CGSize(width: ceil(width), height: headerHeight + membersHeight + methodsHeight),
                               headerHeight: headerHeight,
                               membersHeight: membersHeight,
                               annotationText: annText,
                               annotationBlock: annBlock,
                               nameBlock: nameBlock,
                               memberBlocks: memberBlocks,
                               methodBlocks: methodBlocks)
    }
}

// MARK: - Layout

/// Lays out a class diagram with the vendored dagre (`MermaidLayoutDagre`) — the same backend the
/// flowchart pipeline uses. Class boxes are dagre nodes; relationships are edges, with the ranking
/// direction chosen so the "parent" end of an inheritance/realization arrow lands toward the top.
/// If dagre throws on a degenerate graph we fall back to a plain row layout rather than failing.
enum ClassLayout {

    static let rankSep: CGFloat = 60
    static let nodeSep: CGFloat = 50
    static let outerMargin: CGFloat = 16
    static let labelFont = FontSpec(family: FontSpec.defaultFamily, size: 12)
    static let cardinalityFont = FontSpec(family: FontSpec.defaultFamily, size: 12)

    static func layout(_ ast: ClassDiagramAST) -> PositionedClassDiagram {
        let metrics: [String: ClassBoxMetrics] = Dictionary(
            uniqueKeysWithValues: ast.classOrder.compactMap { id in
                ast.classes[id].map { (id, ClassBoxMetrics.measure($0)) }
            }
        )
        guard !ast.classOrder.isEmpty else {
            return PositionedClassDiagram(size: CGSize(width: 48, height: 48), boxes: [], relations: [])
        }

        if let positioned = try? dagreLayout(ast, metrics: metrics) { return positioned }
        return fallbackLayout(ast, metrics: metrics)
    }

    // MARK: dagre path

    private static func dagreLayout(_ ast: ClassDiagramAST, metrics: [String: ClassBoxMetrics]) throws -> PositionedClassDiagram {
        let g: DagreGraph = Graph(options: GraphOptions(directed: true, multigraph: true, compound: false))
        let opts = LayoutOptions()
        opts.rankdir = dagreDir(ast.direction)
        opts.nodesep = Double(nodeSep)
        opts.ranksep = Double(rankSep)
        opts.marginx = Double(outerMargin)
        opts.marginy = Double(outerMargin)
        g.setGraph(opts)

        for id in ast.classOrder {
            guard let m = metrics[id] else { continue }
            _ = g.setNode(id, label: DagreNodeLabel(width: Double(m.size.width), height: Double(m.size.height)))
        }

        // Per-relation dagre edge direction: the only case we reverse is when the *end* carries the
        // inheritance/realization triangle (so the pointed-at class is ranked above).
        struct EdgePlan { var src: String; var dst: String; var reversed: Bool }
        var plans: [EdgePlan?] = []
        for (i, rel) in ast.relations.enumerated() {
            guard rel.id1 != rel.id2 else { plans.append(nil); continue }   // self-loops handled separately
            let reversed = (rel.endKind == .extends && rel.startKind != .extends)
            let plan = reversed ? EdgePlan(src: rel.id2, dst: rel.id1, reversed: true)
                                : EdgePlan(src: rel.id1, dst: rel.id2, reversed: false)
            plans.append(plan)
            let label = DagreEdgeLabel(minlen: 1, weight: 1)
            if let text = rel.label, !text.isEmpty {
                let sz = TextMeasure.layout(text, font: labelFont).size
                label.width = Double(sz.width + 10)
                label.height = Double(sz.height + 6)
            }
            _ = try g.setEdge(plan.src, plan.dst, label: label, name: "r\(i)")
        }

        try SwiftDagreLayout.layout(g, options: opts)

        var boxes: [PositionedClassBox] = []
        var rectByID: [String: CGRect] = [:]
        for id in ast.classOrder {
            guard let def = ast.classes[id], let m = metrics[id], let dl = g.node(id) else { continue }
            let rect = CGRect(center: CGPoint(x: CGFloat(dl.x), y: CGFloat(dl.y)), size: m.size)
            rectByID[id] = rect
            boxes.append(PositionedClassBox(def: def, rect: rect))
        }

        var relations: [PositionedClassRelation] = []
        for (i, rel) in ast.relations.enumerated() {
            guard let r1 = rectByID[rel.id1], let r2 = rectByID[rel.id2] else { continue }
            if rel.id1 == rel.id2 {
                relations.append(makeSelfLoop(rel: rel, rect: r1))
                continue
            }
            guard let plan = plans[i],
                  let dl = g.edge(EdgeId(v: plan.src, w: plan.dst, name: "r\(i)")) else { continue }
            var pts = dl.points.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }
            if plan.reversed { pts.reverse() }   // normalise to id1 → id2 order
            if pts.count < 2 { pts = [r1.center, r2.center] }
            pts[0] = r1.borderIntersection(towards: pts.count >= 2 ? pts[1] : r2.center)
            pts[pts.count - 1] = r2.borderIntersection(towards: pts.count >= 2 ? pts[pts.count - 2] : r1.center)

            var labelPoint: CGPoint? = nil
            if rel.label?.isEmpty == false { labelPoint = CGPoint(x: CGFloat(dl.x), y: CGFloat(dl.y)) }

            relations.append(PositionedClassRelation(id1: rel.id1, id2: rel.id2, points: pts,
                                                     startKind: rel.startKind, endKind: rel.endKind,
                                                     lineStyle: rel.lineStyle, label: rel.label,
                                                     labelPoint: labelPoint,
                                                     startCardinality: rel.startCardinality,
                                                     endCardinality: rel.endCardinality))
        }

        return finish(boxes: boxes, relations: relations)
    }

    // MARK: fallback path (dagre unavailable / threw)

    private static func fallbackLayout(_ ast: ClassDiagramAST, metrics: [String: ClassBoxMetrics]) -> PositionedClassDiagram {
        // Pack boxes left-to-right, wrapping to a new row roughly every ~3 boxes.
        var boxes: [PositionedClassBox] = []
        var rectByID: [String: CGRect] = [:]
        var x = outerMargin, y = outerMargin, rowHeight: CGFloat = 0, col = 0
        for id in ast.classOrder {
            guard let def = ast.classes[id], let m = metrics[id] else { continue }
            if col == 3 { x = outerMargin; y += rowHeight + rankSep; rowHeight = 0; col = 0 }
            let rect = CGRect(x: x, y: y, width: m.size.width, height: m.size.height)
            rectByID[id] = rect
            boxes.append(PositionedClassBox(def: def, rect: rect))
            x += m.size.width + nodeSep
            rowHeight = max(rowHeight, m.size.height)
            col += 1
        }
        var relations: [PositionedClassRelation] = []
        for rel in ast.relations {
            guard let r1 = rectByID[rel.id1], let r2 = rectByID[rel.id2] else { continue }
            if rel.id1 == rel.id2 { relations.append(makeSelfLoop(rel: rel, rect: r1)); continue }
            let pts = [r1.borderIntersection(towards: r2.center), r2.borderIntersection(towards: r1.center)]
            relations.append(PositionedClassRelation(id1: rel.id1, id2: rel.id2, points: pts,
                                                     startKind: rel.startKind, endKind: rel.endKind,
                                                     lineStyle: rel.lineStyle, label: rel.label,
                                                     labelPoint: pts.first?.lerp(to: pts.last ?? pts[0], 0.5),
                                                     startCardinality: rel.startCardinality,
                                                     endCardinality: rel.endCardinality))
        }
        return finish(boxes: boxes, relations: relations)
    }

    // MARK: shared helpers

    /// Normalise the content into the canvas: union all geometry, then shift so it starts at
    /// `outerMargin`, and report the overall size.
    private static func finish(boxes: [PositionedClassBox], relations: [PositionedClassRelation]) -> PositionedClassDiagram {
        var minX = CGFloat.infinity, minY = CGFloat.infinity, maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        func extend(_ r: CGRect) { minX = min(minX, r.minX); minY = min(minY, r.minY); maxX = max(maxX, r.maxX); maxY = max(maxY, r.maxY) }
        for b in boxes { extend(b.rect) }
        for rel in relations { for p in rel.points { extend(CGRect(x: p.x, y: p.y, width: 0, height: 0)) } }
        if !minX.isFinite { return PositionedClassDiagram(size: CGSize(width: 48, height: 48), boxes: boxes, relations: relations) }

        let dx = outerMargin - minX, dy = outerMargin - minY
        var movedBoxes = boxes, movedRelations = relations
        if dx != 0 || dy != 0 {
            for i in movedBoxes.indices { movedBoxes[i].rect = movedBoxes[i].rect.offsetBy(dx: dx, dy: dy) }
            for i in movedRelations.indices {
                movedRelations[i].points = movedRelations[i].points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
                movedRelations[i].labelPoint = movedRelations[i].labelPoint.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
            }
        }
        let size = CGSize(width: (maxX - minX) + outerMargin * 2, height: (maxY - minY) + outerMargin * 2)
        return PositionedClassDiagram(size: size, boxes: movedBoxes, relations: movedRelations)
    }

    private static func makeSelfLoop(rel: ClassRelation, rect r: CGRect) -> PositionedClassRelation {
        let inset = min(r.height * 0.3, 24)
        let ext: CGFloat = 28
        let p0 = CGPoint(x: r.maxX, y: r.minY + inset)
        let p1 = CGPoint(x: r.maxX + ext, y: r.minY + inset)
        let p2 = CGPoint(x: r.maxX + ext, y: r.minY - ext * 0.6)
        let p3 = CGPoint(x: min(r.maxX, r.midX + r.width * 0.25), y: r.minY - ext * 0.6)
        let pts = [p0, p1, p2, p3, CGPoint(x: p3.x, y: r.minY)]
        return PositionedClassRelation(id1: rel.id1, id2: rel.id2, points: pts,
                                       startKind: rel.startKind, endKind: rel.endKind, lineStyle: rel.lineStyle,
                                       label: rel.label, labelPoint: p2,
                                       startCardinality: rel.startCardinality, endCardinality: rel.endCardinality)
    }

    private static func dagreDir(_ d: ClassDirection) -> LayoutOptions.RankDirection {
        switch d {
        case .TB: return .topBottom
        case .BT: return .bottomTop
        case .LR: return .leftRight
        case .RL: return .rightLeft
        }
    }
}
