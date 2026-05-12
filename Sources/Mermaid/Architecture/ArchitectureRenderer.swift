import CoreGraphics
import Foundation

enum ArchitectureRenderer {

    static func render(_ arch: PositionedArchitecture, theme: MermaidTheme) -> MermaidScene {
        let palette = theme.palette
        var elements: [MermaidElement] = []

        // 1. Group boxes (outermost → innermost). Architecture groups are dashed, lightly tinted.
        for group in arch.groups.sorted(by: { $0.depth < $1.depth }) {
            elements.append(.rect(group.rect, cornerRadius: 10,
                                  style: ShapeStyle_(fill: palette.clusterFill,
                                                     stroke: palette.clusterBorder,
                                                     strokeWidth: 1, dash: [5, 4])))
            if !group.title.isEmpty {
                let block = TextMeasure.layout(group.title, font: ArchitectureLayout.groupTitleFont)
                let baseline = group.rect.minY + ArchitectureLayout.groupTitlePadding + block.firstBaseline
                elements.append(.text(group.title,
                                      origin: CGPoint(x: group.rect.minX + ArchitectureLayout.groupPadding,
                                                      y: baseline),
                                      font: ArchitectureLayout.groupTitleFont,
                                      color: palette.textColor, anchor: .start))
            }
        }

        // 2. Edges (under the icons so the connection points sit behind them).
        for edge in arch.edges {
            elements.append(contentsOf: renderEdge(edge, palette: palette))
        }

        // 3. Services (icon glyph + label). Junctions render nothing.
        for node in arch.nodes where !node.isJunction {
            elements.append(contentsOf: renderService(node, palette: palette))
        }

        return MermaidScene(size: arch.size, backgroundColor: palette.background, elements: elements)
    }

    // MARK: - Service

    private static func renderService(_ node: PositionedArchNode, palette: ThemePalette) -> [MermaidElement] {
        let labelBlock = node.title.isEmpty ? nil : TextMeasure.layout(node.title, font: ArchitectureLayout.labelFont)
        let iconSize = ArchitectureLayout.iconBox
        let labelGap: CGFloat = 4
        let labelH = labelBlock.map { $0.lineHeight * CGFloat($0.lines.count) } ?? 0
        let totalH = iconSize + (labelH > 0 ? labelGap + labelH : 0)
        let topY = node.rect.midY - totalH / 2
        let iconRect = CGRect(x: node.rect.midX - iconSize / 2, y: topY, width: iconSize, height: iconSize)

        var out = iconGlyph(node.icon, in: iconRect, palette: palette)

        if let block = labelBlock {
            let firstBaselineY = iconRect.maxY + labelGap + block.firstBaseline
            for (i, line) in block.lines.enumerated() {
                out.append(.text(line.string,
                                 origin: CGPoint(x: node.rect.midX, y: firstBaselineY + block.lineHeight * CGFloat(i)),
                                 font: ArchitectureLayout.labelFont, color: palette.textColor, anchor: .middle))
            }
        }
        return out
    }

    // MARK: - Edges

    private static func renderEdge(_ edge: PositionedArchEdge, palette: ThemePalette) -> [MermaidElement] {
        guard edge.points.count >= 2 else { return [] }
        let path = CGMutablePath()
        path.move(to: edge.points[0])
        for p in edge.points.dropFirst() { path.addLine(to: p) }
        var out: [MermaidElement] = [
            .path(path, style: ShapeStyle_(fill: nil, stroke: palette.edgeStroke, strokeWidth: 1.5))
        ]
        if edge.arrowEnd {
            out.append(arrowHead(at: edge.points[edge.points.count - 1],
                                 from: edge.points[edge.points.count - 2], palette: palette))
        }
        if edge.arrowStart {
            out.append(arrowHead(at: edge.points[0], from: edge.points[1], palette: palette))
        }
        return out
    }

    private static func arrowHead(at tip: CGPoint, from: CGPoint, palette: ThemePalette) -> MermaidElement {
        let dx = tip.x - from.x, dy = tip.y - from.y
        let len = max((dx * dx + dy * dy).squareRoot(), 0.0001)
        let ux = dx / len, uy = dy / len
        let s: CGFloat = 8
        let baseX = tip.x - ux * s, baseY = tip.y - uy * s
        let px = -uy, py = ux
        let p = CGMutablePath()
        p.move(to: tip)
        p.addLine(to: CGPoint(x: baseX + px * s * 0.5, y: baseY + py * s * 0.5))
        p.addLine(to: CGPoint(x: baseX - px * s * 0.5, y: baseY - py * s * 0.5))
        p.closeSubpath()
        return .path(p, style: ShapeStyle_(fill: palette.edgeStroke, stroke: palette.edgeStroke, strokeWidth: 1))
    }

    // MARK: - Icon glyphs

    private static func iconGlyph(_ icon: ArchIcon, in r: CGRect, palette: ThemePalette) -> [MermaidElement] {
        let fill = ShapeStyle_(fill: palette.nodeFill, stroke: palette.nodeBorder, strokeWidth: 1.5)
        let line = ShapeStyle_(fill: nil, stroke: palette.nodeBorder, strokeWidth: 1.5)
        switch icon {
        case .generic:
            return [.rect(r.insetBy(dx: 2, dy: 2), cornerRadius: 6, style: fill)]

        case .server:
            // Tower chassis with vent slots and a power dot.
            let body = r.insetBy(dx: r.width * 0.18, dy: 0)
            var out: [MermaidElement] = [.rect(body, cornerRadius: 4, style: fill)]
            let slotInset = body.width * 0.22
            for i in 0..<3 {
                let y = body.minY + body.height * (0.18 + CGFloat(i) * 0.13)
                out.append(.path(seg(CGPoint(x: body.minX + slotInset, y: y),
                                     CGPoint(x: body.maxX - slotInset, y: y)), style: line))
            }
            let dotR: CGFloat = body.width * 0.10
            out.append(.path(CGPath(ellipseIn: CGRect(x: body.midX - dotR, y: body.maxY - body.height * 0.20 - dotR,
                                                      width: dotR * 2, height: dotR * 2), transform: nil),
                             style: line))
            return out

        case .database:
            return cylinderGlyph(in: r.insetBy(dx: r.width * 0.10, dy: 2), capRatio: 0.18, fill: fill, line: line)

        case .disk:
            // A squat "disk pack" — short cylinder with a chunkier rim.
            return cylinderGlyph(in: CGRect(x: r.minX + r.width * 0.06, y: r.midY - r.height * 0.30,
                                            width: r.width * 0.88, height: r.height * 0.60),
                                 capRatio: 0.30, fill: fill, line: line)

        case .internet:
            // Globe: circle + flattened equator + tall meridian.
            let circle = r.insetBy(dx: 2, dy: 2)
            var out: [MermaidElement] = [.path(CGPath(ellipseIn: circle, transform: nil), style: fill)]
            out.append(.path(CGPath(ellipseIn: CGRect(x: circle.minX, y: circle.midY - circle.height * 0.16,
                                                      width: circle.width, height: circle.height * 0.32), transform: nil),
                             style: line))
            out.append(.path(CGPath(ellipseIn: CGRect(x: circle.midX - circle.width * 0.16, y: circle.minY,
                                                      width: circle.width * 0.32, height: circle.height), transform: nil),
                             style: line))
            out.append(.path(seg(CGPoint(x: circle.minX, y: circle.midY), CGPoint(x: circle.maxX, y: circle.midY)), style: line))
            return out

        case .cloud:
            return [cloudGlyph(in: r, fill: fill)]
        }
    }

    /// Half-ellipse-capped cylinder fitted to `box`. `capRatio` is the cap's vertical radius as a
    /// fraction of `box.height`.
    private static func cylinderGlyph(in box: CGRect, capRatio: CGFloat, fill: ShapeStyle_, line: ShapeStyle_) -> [MermaidElement] {
        let ry = box.height * capRatio
        let rx = box.width / 2
        let cx = box.midX
        let topCY = box.minY + ry
        let botCY = box.maxY - ry
        let k: CGFloat = 0.5522847498

        func half(_ path: CGMutablePath, cy: CGFloat, bulge: CGFloat, leftToRight: Bool) {
            let startX = leftToRight ? cx - rx : cx + rx
            let endX = leftToRight ? cx + rx : cx - rx
            path.addCurve(to: CGPoint(x: cx, y: cy + bulge),
                          control1: CGPoint(x: startX, y: cy + bulge * k),
                          control2: CGPoint(x: cx + (leftToRight ? -rx : rx) * k, y: cy + bulge))
            path.addCurve(to: CGPoint(x: endX, y: cy),
                          control1: CGPoint(x: cx + (leftToRight ? rx : -rx) * k, y: cy + bulge),
                          control2: CGPoint(x: endX, y: cy + bulge * k))
        }
        let body = CGMutablePath()
        body.move(to: CGPoint(x: cx - rx, y: topCY))
        half(body, cy: topCY, bulge: -ry, leftToRight: true)
        body.addLine(to: CGPoint(x: cx + rx, y: botCY))
        half(body, cy: botCY, bulge: ry, leftToRight: false)
        body.addLine(to: CGPoint(x: cx - rx, y: topCY))
        body.closeSubpath()
        let lip = CGMutablePath()
        lip.move(to: CGPoint(x: cx - rx, y: topCY))
        half(lip, cy: topCY, bulge: ry, leftToRight: true)
        return [.path(body, style: fill), .path(lip, style: line)]
    }

    /// A flat-bottomed cloud silhouette with three bumps, traced as one path.
    private static func cloudGlyph(in r: CGRect, fill: ShapeStyle_) -> MermaidElement {
        let x0 = r.minX, x1 = r.maxX, y0 = r.minY
        let w = r.width, h = r.height
        let bottomY = y0 + h * 0.82
        let p = CGMutablePath()
        p.move(to: CGPoint(x: x0, y: bottomY))
        p.addLine(to: CGPoint(x: x0, y: y0 + h * 0.62))
        // left bump
        p.addQuadCurve(to: CGPoint(x: x0 + w * 0.30, y: y0 + h * 0.30),
                       control: CGPoint(x: x0 + w * 0.02, y: y0 + h * 0.22))
        // middle (tall) bump
        p.addQuadCurve(to: CGPoint(x: x0 + w * 0.66, y: y0 + h * 0.26),
                       control: CGPoint(x: x0 + w * 0.47, y: y0 - h * 0.06))
        // right bump
        p.addQuadCurve(to: CGPoint(x: x1, y: y0 + h * 0.58),
                       control: CGPoint(x: x1 - w * 0.02, y: y0 + h * 0.14))
        p.addLine(to: CGPoint(x: x1, y: bottomY))
        // gently rounded bottom
        p.addQuadCurve(to: CGPoint(x: x0, y: bottomY),
                       control: CGPoint(x: r.midX, y: bottomY + h * 0.10))
        p.closeSubpath()
        return .path(p, style: fill)
    }

    private static func seg(_ a: CGPoint, _ b: CGPoint) -> CGPath {
        let p = CGMutablePath(); p.move(to: a); p.addLine(to: b); return p
    }
}
