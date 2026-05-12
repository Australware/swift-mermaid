import CoreGraphics
import Foundation

enum FlowchartRenderer {

    static func render(_ flow: PositionedFlowchart, theme: MermaidTheme) -> MermaidScene {
        let palette = theme.palette
        var elements: [MermaidElement] = []

        // 1. Subgraphs (outer first, so inner subgraphs draw on top).
        for sg in flow.subgraphs.sorted(by: { $0.depth < $1.depth }) {
            elements.append(.rect(sg.rect, cornerRadius: 6,
                                  style: ShapeStyle_(fill: palette.clusterFill,
                                                     stroke: palette.clusterBorder,
                                                     strokeWidth: 1)))
            if let title = sg.title, !title.isEmpty {
                let block = TextMeasure.layout(title, font: FlowchartLayout.subgraphTitleFont)
                let baseline = sg.rect.minY + FlowchartLayout.subgraphTitlePadding / 2 + block.firstBaseline
                elements.append(.text(title,
                                      origin: CGPoint(x: sg.rect.midX, y: baseline),
                                      font: FlowchartLayout.subgraphTitleFont,
                                      color: palette.textColor,
                                      anchor: .middle))
            }
        }

        // 2. Edges (under nodes so nodes cover the line ends).
        for edge in flow.edges {
            elements.append(contentsOf: renderEdge(edge, palette: palette))
        }

        // 3. Nodes.
        for node in flow.nodes {
            elements.append(contentsOf: renderNode(node, palette: palette))
        }

        return MermaidScene(size: flow.size,
                            backgroundColor: palette.background,
                            elements: elements)
    }

    // MARK: - Nodes

    private static func renderNode(_ node: PositionedNode, palette: ThemePalette) -> [MermaidElement] {
        let style = ShapeStyle_(fill: palette.nodeFill, stroke: palette.nodeBorder, strokeWidth: 1)
        var out: [MermaidElement] = []
        let r = node.rect
        switch node.shape {
        case .rect:
            out.append(.rect(r, cornerRadius: 0, style: style))
        case .roundRect:
            out.append(.rect(r, cornerRadius: 6, style: style))
        case .stadium:
            out.append(.rect(r, cornerRadius: r.height / 2, style: style))
        case .subroutine:
            out.append(.rect(r, cornerRadius: 0, style: style))
            // Internal bars 6pt from each side.
            let inner = 8.0
            out.append(.path(linePath(from: CGPoint(x: r.minX + inner, y: r.minY),
                                      to: CGPoint(x: r.minX + inner, y: r.maxY)),
                             style: ShapeStyle_(fill: nil, stroke: palette.nodeBorder, strokeWidth: 1)))
            out.append(.path(linePath(from: CGPoint(x: r.maxX - inner, y: r.minY),
                                      to: CGPoint(x: r.maxX - inner, y: r.maxY)),
                             style: ShapeStyle_(fill: nil, stroke: palette.nodeBorder, strokeWidth: 1)))
        case .cylinder:
            out.append(contentsOf: cylinder(rect: r, style: style))
        case .circle:
            out.append(.path(ellipsePath(in: r), style: style))
        case .doubleCircle:
            out.append(.path(ellipsePath(in: r), style: style))
            out.append(.path(ellipsePath(in: r.insetBy(dx: 5, dy: 5)),
                             style: ShapeStyle_(fill: nil, stroke: palette.nodeBorder, strokeWidth: 1)))
        case .rhombus:
            out.append(.path(rhombusPath(in: r), style: style))
        case .hexagon:
            out.append(.path(hexagonPath(in: r), style: style))
        case .parallelogramFwd:
            out.append(.path(parallelogramPath(in: r, forward: true), style: style))
        case .parallelogramBack:
            out.append(.path(parallelogramPath(in: r, forward: false), style: style))
        case .trapezoid:
            out.append(.path(trapezoidPath(in: r, inverted: false), style: style))
        case .trapezoidInv:
            out.append(.path(trapezoidPath(in: r, inverted: true), style: style))
        case .asymmetric:
            out.append(.path(asymmetricPath(in: r), style: style))
        }
        // Centred label, multi-line.
        out.append(contentsOf: drawLabel(node.label, in: r, font: FlowchartLayout.nodeFont, color: palette.nodeTextColor))
        return out
    }

    private static func drawLabel(_ text: String, in rect: CGRect, font: FontSpec, color: CGColor) -> [MermaidElement] {
        let block = TextMeasure.layout(text, font: font)
        let totalHeight = block.lineHeight * CGFloat(block.lines.count)
        let firstBaselineY = rect.midY - totalHeight / 2 + block.firstBaseline
        var out: [MermaidElement] = []
        for (i, line) in block.lines.enumerated() {
            let y = firstBaselineY + block.lineHeight * CGFloat(i)
            out.append(.text(line.string,
                             origin: CGPoint(x: rect.midX, y: y),
                             font: font, color: color, anchor: .middle))
        }
        return out
    }

    // MARK: - Edges

    private static func renderEdge(_ edge: EdgeRoute, palette: ThemePalette) -> [MermaidElement] {
        let strokeWidth: CGFloat = (edge.kind == .thick) ? 3 : 1.5
        let dash: [CGFloat]? = (edge.kind == .dotted) ? [4, 3] : nil
        let style = ShapeStyle_(fill: nil, stroke: palette.edgeStroke,
                                strokeWidth: strokeWidth, dash: dash)
        var out: [MermaidElement] = []
        out.append(.path(smoothPath(through: edge.points), style: style))

        // Arrowheads.
        if edge.points.count >= 2 {
            if edge.arrowEnd != .none {
                out.append(contentsOf: arrowHead(kind: edge.arrowEnd,
                                                  at: edge.points.last!,
                                                  approachingFrom: edge.points[edge.points.count - 2],
                                                  palette: palette))
            }
            if edge.arrowStart != .none {
                out.append(contentsOf: arrowHead(kind: edge.arrowStart,
                                                  at: edge.points.first!,
                                                  approachingFrom: edge.points[1],
                                                  palette: palette))
            }
        }

        // Label.
        if let label = edge.label, !label.isEmpty, let pt = edge.labelPoint {
            let block = TextMeasure.layout(label, font: FlowchartLayout.edgeLabelFont)
            let pad: CGFloat = 4
            let bg = CGRect(x: pt.x - block.size.width / 2 - pad,
                            y: pt.y - block.size.height / 2 - pad / 2,
                            width: block.size.width + pad * 2,
                            height: block.size.height + pad)
            out.append(.rect(bg, cornerRadius: 3,
                             style: ShapeStyle_(fill: palette.edgeLabelBackground,
                                                stroke: nil, strokeWidth: 0)))
            let totalHeight = block.lineHeight * CGFloat(block.lines.count)
            let firstBaselineY = pt.y - totalHeight / 2 + block.firstBaseline
            for (i, line) in block.lines.enumerated() {
                let y = firstBaselineY + block.lineHeight * CGFloat(i)
                out.append(.text(line.string,
                                 origin: CGPoint(x: pt.x, y: y),
                                 font: FlowchartLayout.edgeLabelFont,
                                 color: palette.edgeLabelColor,
                                 anchor: .middle))
            }
        }
        return out
    }

    private static func arrowHead(kind: FlowArrow, at tip: CGPoint, approachingFrom: CGPoint,
                                  palette: ThemePalette) -> [MermaidElement] {
        switch kind {
        case .none:
            return []
        case .arrow:
            let dx = tip.x - approachingFrom.x
            let dy = tip.y - approachingFrom.y
            let len = max((dx * dx + dy * dy).squareRoot(), 0.0001)
            let ux = dx / len, uy = dy / len
            let size: CGFloat = 8
            let baseX = tip.x - ux * size
            let baseY = tip.y - uy * size
            let perpX = -uy, perpY = ux
            let leftX = baseX + perpX * size * 0.5
            let leftY = baseY + perpY * size * 0.5
            let rightX = baseX - perpX * size * 0.5
            let rightY = baseY - perpY * size * 0.5
            let path = CGMutablePath()
            path.move(to: tip)
            path.addLine(to: CGPoint(x: leftX, y: leftY))
            path.addLine(to: CGPoint(x: rightX, y: rightY))
            path.closeSubpath()
            return [.path(path, style: ShapeStyle_(fill: palette.edgeStroke,
                                                   stroke: palette.edgeStroke,
                                                   strokeWidth: 1))]
        case .circle:
            let d: CGFloat = 8
            let rect = CGRect(x: tip.x - d / 2, y: tip.y - d / 2, width: d, height: d)
            return [.path(ellipsePath(in: rect),
                          style: ShapeStyle_(fill: palette.background,
                                             stroke: palette.edgeStroke,
                                             strokeWidth: 1.5))]
        case .cross:
            let d: CGFloat = 5
            let path = CGMutablePath()
            path.move(to: CGPoint(x: tip.x - d, y: tip.y - d))
            path.addLine(to: CGPoint(x: tip.x + d, y: tip.y + d))
            path.move(to: CGPoint(x: tip.x - d, y: tip.y + d))
            path.addLine(to: CGPoint(x: tip.x + d, y: tip.y - d))
            return [.path(path, style: ShapeStyle_(fill: nil, stroke: palette.edgeStroke, strokeWidth: 1.5))]
        }
    }

    // MARK: - Shape paths

    private static func ellipsePath(in rect: CGRect) -> CGPath {
        CGPath(ellipseIn: rect, transform: nil)
    }

    private static func rhombusPath(in r: CGRect) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.midY))
        p.closeSubpath()
        return p
    }

    private static func hexagonPath(in r: CGRect) -> CGPath {
        let inset = min(r.height * 0.4, r.width * 0.25)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: r.minX + inset, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - inset, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        p.addLine(to: CGPoint(x: r.maxX - inset, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + inset, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.midY))
        p.closeSubpath()
        return p
    }

    private static func parallelogramPath(in r: CGRect, forward: Bool) -> CGPath {
        let slant: CGFloat = min(r.height * 0.5, 18)
        let p = CGMutablePath()
        if forward {
            p.move(to: CGPoint(x: r.minX + slant, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX - slant, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        } else {
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX - slant, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX + slant, y: r.maxY))
        }
        p.closeSubpath()
        return p
    }

    private static func trapezoidPath(in r: CGRect, inverted: Bool) -> CGPath {
        let slant: CGFloat = min(r.height * 0.5, 18)
        let p = CGMutablePath()
        if inverted {
            // [\text/] — narrow at top, wide at bottom
            p.move(to: CGPoint(x: r.minX + slant, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX - slant, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        } else {
            // [/text\] — wide at top, narrow at bottom
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX - slant, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX + slant, y: r.maxY))
        }
        p.closeSubpath()
        return p
    }

    private static func asymmetricPath(in r: CGRect) -> CGPath {
        let arrow: CGFloat = 12
        let p = CGMutablePath()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - arrow, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        p.addLine(to: CGPoint(x: r.maxX - arrow, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }

    private static func cylinder(rect r: CGRect, style: ShapeStyle_) -> [MermaidElement] {
        // Vertical radius of the two cap ellipses (the "lip" of the can). Caps fit *inside* `r`:
        // the top of the upper cap sits at r.minY, the bottom of the lower cap at r.maxY.
        let ry = min(r.height * 0.18, 10)
        let rx = r.width / 2
        let cx = r.midX
        let topCY = r.minY + ry
        let botCY = r.maxY - ry
        // Cubic-bezier approximation of a quarter ellipse.
        let k: CGFloat = 0.5522847498

        /// Append a half-ellipse arc spanning the two horizontal extremes at height `cy`, bulging
        /// vertically by `bulge` (positive = downward). `leftToRight` picks which extreme the path
        /// must currently be at (and which it ends at).
        func appendHalfEllipse(_ path: CGMutablePath, cy: CGFloat, bulge: CGFloat, leftToRight: Bool) {
            let startX = leftToRight ? cx - rx : cx + rx
            let endX = leftToRight ? cx + rx : cx - rx
            path.addCurve(to: CGPoint(x: cx, y: cy + bulge),
                          control1: CGPoint(x: startX, y: cy + bulge * k),
                          control2: CGPoint(x: cx + (leftToRight ? -rx : rx) * k, y: cy + bulge))
            path.addCurve(to: CGPoint(x: endX, y: cy),
                          control1: CGPoint(x: cx + (leftToRight ? rx : -rx) * k, y: cy + bulge),
                          control2: CGPoint(x: endX, y: cy + bulge * k))
        }

        // Filled silhouette, walked clockwise (y is down): back of top rim (bulges up) → right wall
        // → front of bottom (bulges down) → left wall.
        let body = CGMutablePath()
        body.move(to: CGPoint(x: cx - rx, y: topCY))
        appendHalfEllipse(body, cy: topCY, bulge: -ry, leftToRight: true)
        body.addLine(to: CGPoint(x: cx + rx, y: botCY))
        appendHalfEllipse(body, cy: botCY, bulge: ry, leftToRight: false)
        body.addLine(to: CGPoint(x: cx - rx, y: topCY))
        body.closeSubpath()

        // Visible front half of the top rim — stroke only, drawn over the body so the full top
        // ellipse reads (back half from the silhouette + this front half).
        let lip = CGMutablePath()
        lip.move(to: CGPoint(x: cx - rx, y: topCY))
        appendHalfEllipse(lip, cy: topCY, bulge: ry, leftToRight: true)

        return [
            .path(body, style: style),
            .path(lip, style: ShapeStyle_(fill: nil, stroke: style.stroke, strokeWidth: style.strokeWidth))
        ]
    }

    private static func linePath(from: CGPoint, to: CGPoint) -> CGPath {
        let p = CGMutablePath()
        p.move(to: from); p.addLine(to: to); return p
    }

    // MARK: - Smoothing

    /// Catmull-Rom → cubic Bezier, the same family Mermaid uses for flowchart edges. For polylines
    /// with only two points, just emit a straight line.
    private static func smoothPath(through pts: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = pts.first else { return path }
        path.move(to: first)
        if pts.count == 2 {
            path.addLine(to: pts[1])
            return path
        }
        for i in 0..<(pts.count - 1) {
            let p0 = i == 0 ? pts[i] : pts[i - 1]
            let p1 = pts[i]
            let p2 = pts[i + 1]
            let p3 = (i + 2 < pts.count) ? pts[i + 2] : pts[i + 1]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }
}
