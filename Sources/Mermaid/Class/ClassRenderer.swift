import CoreGraphics
import Foundation

/// Turns a `PositionedClassDiagram` into a `MermaidScene`. Boxes reuse the flowchart node palette
/// (Mermaid's class diagram shares those colours); relationship lines reuse the edge palette.
enum ClassRenderer {

    // Marker geometry (the lengths must match `ClassLayout.markerRetract`).
    private static let triangleLen: CGFloat = 14
    private static let triangleHalfWidth: CGFloat = 7
    private static let diamondLen: CGFloat = 16
    private static let diamondHalfWidth: CGFloat = 6
    private static let arrowLen: CGFloat = 10
    private static let arrowHalfWidth: CGFloat = 5

    static func render(_ diagram: PositionedClassDiagram, theme: MermaidTheme) -> MermaidScene {
        let palette = theme.palette
        var elements: [MermaidElement] = []

        // Relationships first so the boxes draw over the line ends.
        for rel in diagram.relations { elements.append(contentsOf: renderRelation(rel, palette: palette)) }
        for box in diagram.boxes { elements.append(contentsOf: renderBox(box, palette: palette)) }

        return MermaidScene(size: diagram.size, backgroundColor: palette.background, elements: elements)
    }

    // MARK: - Boxes

    private static func renderBox(_ box: PositionedClassBox, palette: ThemePalette) -> [MermaidElement] {
        let r = box.rect
        let m = ClassBoxMetrics.measure(box.def)
        let boxStyle = ShapeStyle_(fill: palette.nodeFill, stroke: palette.nodeBorder, strokeWidth: 1)
        let lineStyle = ShapeStyle_(fill: nil, stroke: palette.nodeBorder, strokeWidth: 1)
        var out: [MermaidElement] = [.rect(r, cornerRadius: 0, style: boxStyle)]

        // --- Title compartment ---
        var y = r.minY + ClassBoxMetrics.headerVPad
        if let annText = m.annotationText, let annBlock = m.annotationBlock {
            out.append(.text(annText,
                             origin: CGPoint(x: r.midX, y: y + annBlock.firstBaseline),
                             font: ClassBoxMetrics.annotationFont, color: palette.nodeTextColor, anchor: .middle))
            y += annBlock.size.height
        }
        out.append(.text(box.def.name.isEmpty ? box.def.id : box.def.name,
                         origin: CGPoint(x: r.midX, y: y + m.nameBlock.firstBaseline),
                         font: ClassBoxMetrics.titleFont, color: palette.nodeTextColor, anchor: .middle))

        // --- Divider + attributes ---
        let div1 = r.minY + m.headerHeight
        out.append(.path(hLine(r.minX, r.maxX, div1), style: lineStyle))
        out.append(contentsOf: compartmentLines(box.def.members.map(\.text), blocks: m.memberBlocks,
                                                top: div1, left: r.minX + ClassBoxMetrics.hPad,
                                                color: palette.nodeTextColor))

        // --- Divider + methods ---
        let div2 = div1 + m.membersHeight
        out.append(.path(hLine(r.minX, r.maxX, div2), style: lineStyle))
        out.append(contentsOf: compartmentLines(box.def.methods.map(\.text), blocks: m.methodBlocks,
                                                top: div2, left: r.minX + ClassBoxMetrics.hPad,
                                                color: palette.nodeTextColor))
        return out
    }

    private static func compartmentLines(_ texts: [String], blocks: [TextMeasure.Block],
                                         top: CGFloat, left: CGFloat, color: CGColor) -> [MermaidElement] {
        guard !texts.isEmpty else { return [] }
        var out: [MermaidElement] = []
        var y = top + ClassBoxMetrics.compVPad
        for (text, block) in zip(texts, blocks) {
            out.append(.text(text, origin: CGPoint(x: left, y: y + block.firstBaseline),
                             font: ClassBoxMetrics.memberFont, color: color, anchor: .start))
            y += block.lineHeight
        }
        return out
    }

    // MARK: - Relationships

    private static func renderRelation(_ rel: PositionedClassRelation, palette: ThemePalette) -> [MermaidElement] {
        guard rel.points.count >= 2 else { return [] }
        var out: [MermaidElement] = []

        // The closed markers (triangle, diamond) sit *on* the endpoint and extend toward the line, so
        // pull the polyline ends back behind them; the open "V" arrowhead lets the line run to the tip.
        var line = rel.points
        retract(&line, startBy: markerLength(rel.startKind), endBy: markerLength(rel.endKind))
        let dash: [CGFloat]? = (rel.lineStyle == .dashed) ? [4, 4] : nil
        out.append(.path(polyline(line), style: ShapeStyle_(fill: nil, stroke: palette.edgeStroke,
                                                            strokeWidth: 1, dash: dash)))

        // Markers point at the true (un-retracted) endpoints, oriented along the terminal segment.
        out.append(contentsOf: marker(rel.endKind, tip: rel.points[rel.points.count - 1],
                                      from: rel.points[rel.points.count - 2], palette: palette))
        out.append(contentsOf: marker(rel.startKind, tip: rel.points[0], from: rel.points[1], palette: palette))

        // `: label`.
        if let label = rel.label, !label.isEmpty, let pt = rel.labelPoint {
            out.append(contentsOf: labelBox(label, at: pt, font: ClassLayout.labelFont, palette: palette))
        }

        // Cardinality strings, nudged just inside each endpoint.
        if let c = rel.startCardinality, !c.isEmpty {
            out.append(contentsOf: cardinality(c, at: rel.points[0], toward: rel.points[1], palette: palette))
        }
        if let c = rel.endCardinality, !c.isEmpty {
            out.append(contentsOf: cardinality(c, at: rel.points[rel.points.count - 1],
                                               toward: rel.points[rel.points.count - 2], palette: palette))
        }
        return out
    }

    /// How far a closed end-marker extends back from the endpoint (0 for the open arrowhead / none).
    private static func markerLength(_ kind: ClassRelationKind) -> CGFloat {
        switch kind {
        case .extends: return triangleLen
        case .composition, .aggregation: return diamondLen
        case .association, .none: return 0
        }
    }

    /// Pull the first/last polyline point inward along its terminal segment by the given amounts.
    private static func retract(_ pts: inout [CGPoint], startBy: CGFloat, endBy: CGFloat) {
        guard pts.count >= 2 else { return }
        if startBy > 0 {
            let a = pts[0], b = pts[1], d = a.distance(to: b)
            if d > startBy + 0.5 { pts[0] = a.lerp(to: b, startBy / d) }
        }
        if endBy > 0 {
            let n = pts.count, a = pts[n - 1], b = pts[n - 2], d = a.distance(to: b)
            if d > endBy + 0.5 { pts[n - 1] = a.lerp(to: b, endBy / d) }
        }
    }

    private static func marker(_ kind: ClassRelationKind, tip: CGPoint, from: CGPoint,
                               palette: ThemePalette) -> [MermaidElement] {
        let d = tip - from
        let len = max(d.length, 0.0001)
        let dir = CGPoint(x: d.x / len, y: d.y / len)         // unit vector toward the tip
        let perp = CGPoint(x: -dir.y, y: dir.x)
        let stroke = ShapeStyle_(fill: nil, stroke: palette.edgeStroke, strokeWidth: 1)

        switch kind {
        case .none:
            return []
        case .extends:
            // Hollow triangle, filled with the background so the line behind it doesn't show.
            let baseC = tip - dir * triangleLen
            let p = CGMutablePath()
            p.move(to: tip)
            p.addLine(to: baseC + perp * triangleHalfWidth)
            p.addLine(to: baseC - perp * triangleHalfWidth)
            p.closeSubpath()
            return [.path(p, style: ShapeStyle_(fill: palette.background, stroke: palette.edgeStroke, strokeWidth: 1))]
        case .composition, .aggregation:
            let mid = tip - dir * (diamondLen / 2)
            let back = tip - dir * diamondLen
            let p = CGMutablePath()
            p.move(to: tip)
            p.addLine(to: mid + perp * diamondHalfWidth)
            p.addLine(to: back)
            p.addLine(to: mid - perp * diamondHalfWidth)
            p.closeSubpath()
            let fill: CGColor = (kind == .composition) ? palette.edgeStroke : palette.background
            return [.path(p, style: ShapeStyle_(fill: fill, stroke: palette.edgeStroke, strokeWidth: 1))]
        case .association:
            // Open "V" arrowhead — two strokes meeting at the tip.
            let back = tip - dir * arrowLen
            let p = CGMutablePath()
            p.move(to: back + perp * arrowHalfWidth)
            p.addLine(to: tip)
            p.addLine(to: back - perp * arrowHalfWidth)
            return [.path(p, style: stroke)]
        }
    }

    private static func cardinality(_ text: String, at endpoint: CGPoint, toward next: CGPoint,
                                    palette: ThemePalette) -> [MermaidElement] {
        let d = next - endpoint
        let len = max(d.length, 0.0001)
        let dir = CGPoint(x: d.x / len, y: d.y / len)
        let perp = CGPoint(x: -dir.y, y: dir.x)
        let block = TextMeasure.layout(text, font: ClassLayout.cardinalityFont)
        // Sit ~16pt in from the endpoint and ~9pt off to the side of the line.
        let centre = endpoint + dir * 16 + perp * (block.size.height / 2 + 5)
        let baselineY = centre.y - block.size.height / 2 + block.firstBaseline
        return [.text(text, origin: CGPoint(x: centre.x, y: baselineY),
                      font: ClassLayout.cardinalityFont, color: palette.edgeLabelColor, anchor: .middle)]
    }

    private static func labelBox(_ text: String, at pt: CGPoint, font: FontSpec,
                                 palette: ThemePalette) -> [MermaidElement] {
        let block = TextMeasure.layout(text, font: font)
        let pad: CGFloat = 4
        let bg = CGRect(x: pt.x - block.size.width / 2 - pad, y: pt.y - block.size.height / 2 - pad / 2,
                        width: block.size.width + pad * 2, height: block.size.height + pad)
        var out: [MermaidElement] = [.rect(bg, cornerRadius: 3,
                                           style: ShapeStyle_(fill: palette.edgeLabelBackground, stroke: nil, strokeWidth: 0))]
        let firstBaselineY = pt.y - block.size.height / 2 + block.firstBaseline
        for (i, line) in block.lines.enumerated() {
            out.append(.text(line.string, origin: CGPoint(x: pt.x, y: firstBaselineY + block.lineHeight * CGFloat(i)),
                             font: font, color: palette.edgeLabelColor, anchor: .middle))
        }
        return out
    }

    // MARK: - Path helpers

    private static func hLine(_ x0: CGFloat, _ x1: CGFloat, _ y: CGFloat) -> CGPath {
        let p = CGMutablePath(); p.move(to: CGPoint(x: x0, y: y)); p.addLine(to: CGPoint(x: x1, y: y)); return p
    }

    private static func polyline(_ pts: [CGPoint]) -> CGPath {
        let p = CGMutablePath()
        guard let first = pts.first else { return p }
        p.move(to: first)
        for pt in pts.dropFirst() { p.addLine(to: pt) }
        return p
    }
}
