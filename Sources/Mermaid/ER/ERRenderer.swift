import CoreGraphics
import Foundation

/// Turns a `PositionedERDiagram` into a `MermaidScene`.
///
/// Cardinality is drawn in textbook crow's-foot notation rather than by reproducing Mermaid's own
/// marker paths: the symbol nearest the entity carries the cardinality (a bar for "one", a crow's
/// foot for "many") and the symbol further along the line carries the optionality (a bar for
/// "mandatory", a ring for "optional").
enum ERRenderer {

    private static let crowLength: CGFloat = 14      // how far the foot's apex sits from the entity
    private static let crowHalfWidth: CGFloat = 7
    private static let barHalfWidth: CGFloat = 7
    private static let barOffset: CGFloat = 8        // first bar's distance from the entity border
    private static let barGap: CGFloat = 7           // spacing between the two markers on one end
    private static let ringRadius: CGFloat = 4

    static func render(_ diagram: PositionedERDiagram, theme: MermaidTheme) -> MermaidScene {
        let palette = theme.palette
        var elements: [MermaidElement] = []

        // Relationships first so the entity boxes draw over the line ends.
        for rel in diagram.relationships { elements.append(contentsOf: renderRelationship(rel, palette: palette)) }
        for entity in diagram.entities { elements.append(contentsOf: renderEntity(entity, palette: palette)) }

        return MermaidScene(size: diagram.size, backgroundColor: palette.background, elements: elements)
    }

    // MARK: - Entities

    private static func renderEntity(_ positioned: PositionedEREntity, palette: ThemePalette) -> [MermaidElement] {
        let r = positioned.rect
        let m = EREntityMetrics.measure(positioned.entity)
        let border = ShapeStyle_(fill: nil, stroke: palette.erEntityBorder, strokeWidth: 1)
        var out: [MermaidElement] = []

        // Header band.
        let header = CGRect(x: r.minX, y: r.minY, width: r.width, height: m.headerHeight)
        out.append(.rect(header, cornerRadius: 0,
                         style: ShapeStyle_(fill: palette.erEntityFill, stroke: nil, strokeWidth: 0)))

        // Attribute rows, alternating background.
        for row in m.cells.indices {
            let rowRect = CGRect(x: r.minX, y: r.minY + m.headerHeight + m.rowHeight * CGFloat(row),
                                 width: r.width, height: m.rowHeight)
            let fill = row.isMultiple(of: 2) ? palette.erAttributeFillOdd : palette.erAttributeFillEven
            out.append(.rect(rowRect, cornerRadius: 0,
                             style: ShapeStyle_(fill: fill, stroke: nil, strokeWidth: 0)))
        }

        // Outline, then the internal rules.
        out.append(.rect(r, cornerRadius: 0, style: border))
        if !m.cells.isEmpty {
            out.append(.path(line(from: CGPoint(x: r.minX, y: r.minY + m.headerHeight),
                                  to: CGPoint(x: r.maxX, y: r.minY + m.headerHeight)), style: border))
            for row in 1..<max(1, m.cells.count) {
                let y = r.minY + m.headerHeight + m.rowHeight * CGFloat(row)
                out.append(.path(line(from: CGPoint(x: r.minX, y: y), to: CGPoint(x: r.maxX, y: y)), style: border))
            }
            var x = r.minX
            for width in m.columnWidths.dropLast() {
                x += width
                out.append(.path(line(from: CGPoint(x: x, y: r.minY + m.headerHeight),
                                      to: CGPoint(x: x, y: r.maxY)), style: border))
            }
        }

        // Entity name, centred in the header.
        let nameY = r.minY + (m.headerHeight - m.nameBlock.size.height) / 2 + m.nameBlock.firstBaseline
        out.append(.text(positioned.entity.name.isEmpty ? positioned.entity.id : positioned.entity.name,
                         origin: CGPoint(x: r.midX, y: nameY),
                         font: EREntityMetrics.titleFont, color: palette.nodeTextColor, anchor: .middle))

        // Attribute cells, left-aligned within their column.
        for (row, cells) in m.cells.enumerated() {
            let rowTop = r.minY + m.headerHeight + m.rowHeight * CGFloat(row)
            var x = r.minX
            for (col, text) in cells.enumerated() {
                let width = m.columnWidths[col]
                if !text.isEmpty {
                    let block = TextMeasure.layout(text, font: EREntityMetrics.attributeFont)
                    let baselineY = rowTop + (m.rowHeight - block.size.height) / 2 + block.firstBaseline
                    out.append(.text(text, origin: CGPoint(x: x + EREntityMetrics.cellHPad, y: baselineY),
                                     font: EREntityMetrics.attributeFont, color: palette.nodeTextColor, anchor: .start))
                }
                x += width
            }
        }
        return out
    }

    // MARK: - Relationships

    private static func renderRelationship(_ rel: PositionedERRelationship, palette: ThemePalette) -> [MermaidElement] {
        guard rel.points.count >= 2 else { return [] }
        var out: [MermaidElement] = []

        let dash: [CGFloat]? = (rel.lineStyle == .nonIdentifying) ? [5, 4] : nil
        out.append(.path(polyline(rel.points),
                         style: ShapeStyle_(fill: nil, stroke: palette.edgeStroke, strokeWidth: 1, dash: dash)))

        let n = rel.points.count
        out.append(contentsOf: marker(rel.lhsCardinality, at: rel.points[0], from: rel.points[1], palette: palette))
        out.append(contentsOf: marker(rel.rhsCardinality, at: rel.points[n - 1], from: rel.points[n - 2], palette: palette))

        if let label = rel.label, !label.isEmpty, let pt = rel.labelPoint {
            out.append(contentsOf: labelBox(label, at: pt, palette: palette))
        }
        return out
    }

    /// `tip` sits on the entity border; `from` is the neighbouring polyline point, so `-dir` walks
    /// back into the diagram. Markers are stacked along that direction.
    private static func marker(_ cardinality: ERCardinality, at endpoint: CGPoint,
                               from: CGPoint, palette: ThemePalette) -> [MermaidElement] {
        let d = endpoint - from
        let len = max(d.length, 0.0001)
        let dir = CGPoint(x: d.x / len, y: d.y / len)          // unit vector pointing at the entity
        let perp = CGPoint(x: -dir.y, y: dir.x)
        let stroke = ShapeStyle_(fill: nil, stroke: palette.edgeStroke, strokeWidth: 1.4)

        func bar(_ distance: CGFloat) -> MermaidElement {
            let c = endpoint - dir * distance
            return .path(line(from: c + perp * barHalfWidth, to: c - perp * barHalfWidth), style: stroke)
        }
        func ring(_ distance: CGFloat) -> MermaidElement {
            let c = endpoint - dir * distance
            let p = CGMutablePath()
            p.addEllipse(in: CGRect(center: c, size: CGSize(width: ringRadius * 2, height: ringRadius * 2)))
            return .path(p, style: ShapeStyle_(fill: palette.background, stroke: palette.edgeStroke, strokeWidth: 1.4))
        }
        func crowsFoot() -> MermaidElement {
            let apex = endpoint - dir * crowLength
            let p = CGMutablePath()
            p.move(to: apex); p.addLine(to: endpoint + perp * crowHalfWidth)
            p.move(to: apex); p.addLine(to: endpoint - perp * crowHalfWidth)
            p.move(to: apex); p.addLine(to: endpoint)
            return .path(p, style: stroke)
        }

        switch cardinality {
        case .exactlyOne:
            return [bar(barOffset), bar(barOffset + barGap)]
        case .zeroOrOne:
            return [bar(barOffset), ring(barOffset + barGap + ringRadius)]
        case .oneOrMore:
            return [crowsFoot(), bar(crowLength + barGap)]
        case .zeroOrMore:
            return [crowsFoot(), ring(crowLength + barGap + ringRadius)]
        }
    }

    private static func labelBox(_ text: String, at pt: CGPoint, palette: ThemePalette) -> [MermaidElement] {
        let font = ERLayout.labelFont
        let block = TextMeasure.layout(text, font: font)
        let bg = ERLayout.labelRect(text, at: pt)
        var out: [MermaidElement] = [.rect(bg, cornerRadius: 3,
                                           style: ShapeStyle_(fill: palette.edgeLabelBackground, stroke: nil, strokeWidth: 0))]
        let firstBaselineY = pt.y - block.size.height / 2 + block.firstBaseline
        for (i, l) in block.lines.enumerated() {
            out.append(.text(l.string, origin: CGPoint(x: pt.x, y: firstBaselineY + block.lineHeight * CGFloat(i)),
                             font: font, color: palette.edgeLabelColor, anchor: .middle))
        }
        return out
    }

    // MARK: - Path helpers

    private static func line(from a: CGPoint, to b: CGPoint) -> CGPath {
        let p = CGMutablePath(); p.move(to: a); p.addLine(to: b); return p
    }

    private static func polyline(_ pts: [CGPoint]) -> CGPath {
        let p = CGMutablePath()
        guard let first = pts.first else { return p }
        p.move(to: first)
        for pt in pts.dropFirst() { p.addLine(to: pt) }
        return p
    }
}
