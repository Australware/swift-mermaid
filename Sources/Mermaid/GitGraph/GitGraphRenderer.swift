import CoreGraphics
import Foundation

/// Turns a `PositionedGitGraph` into a `MermaidScene`: a coloured line per branch lane, a dot per
/// commit shaped by its type, and the commit / tag / branch labels.
enum GitGraphRenderer {

    private static let laneLineWidth: CGFloat = 2
    private static let edgeLineWidth: CGFloat = 2
    private static let innerDotRatio: CGFloat = 0.45      // merge commit's hole
    private static let cherryDotRadius: CGFloat = 2.5

    static func render(_ graph: PositionedGitGraph, theme: MermaidTheme) -> MermaidScene {
        let palette = theme.palette
        var elements: [MermaidElement] = []

        func branchColor(_ index: Int) -> CGColor {
            palette.gitBranchColors[index % palette.gitBranchColors.count]
        }

        // Lane lines sit behind everything.
        for lane in graph.lanes where lane.lineStart != lane.lineEnd {
            elements.append(.path(line(lane.lineStart, lane.lineEnd),
                                  style: ShapeStyle_(fill: nil, stroke: branchColor(lane.colorIndex),
                                                     strokeWidth: laneLineWidth)))
        }

        for edge in graph.edges {
            elements.append(.path(edgePath(edge.points),
                                  style: ShapeStyle_(fill: nil, stroke: branchColor(edge.colorIndex),
                                                     strokeWidth: edgeLineWidth,
                                                     dash: edge.dashed ? [5, 4] : nil)))
        }

        for positioned in graph.commits {
            elements.append(contentsOf: dot(positioned, color: branchColor(positioned.colorIndex), palette: palette))
        }

        // Decorations last so they sit above the lines.
        for positioned in graph.commits {
            if let tag = positioned.commit.tag, !tag.isEmpty {
                elements.append(contentsOf: tagElements(tag, at: positioned.tagPoint,
                                                        pointingAt: positioned.center, palette: palette))
            }
            if let label = positioned.commit.label, !label.isEmpty {
                elements.append(contentsOf: pill(label,
                                                 center: positioned.labelPoint,
                                                 size: GitGraphLayout.labelSize(label),
                                                 font: GitGraphLayout.commitLabelFont,
                                                 fill: palette.edgeLabelBackground,
                                                 stroke: nil,
                                                 textColor: palette.edgeLabelColor,
                                                 cornerRadius: 3))
            }
        }

        for lane in graph.lanes {
            let color = branchColor(lane.colorIndex)
            elements.append(contentsOf: pill(lane.name,
                                             center: lane.labelRect.center,
                                             size: lane.labelRect.size,
                                             font: GitGraphLayout.branchLabelFont,
                                             fill: color,
                                             stroke: nil,
                                             textColor: color.contrastingTextColor,
                                             cornerRadius: lane.labelRect.height / 2))
        }

        return MermaidScene(size: graph.size, backgroundColor: palette.background, elements: elements)
    }

    // MARK: - Commit dots

    private static func dot(_ positioned: PositionedGitCommit, color: CGColor, palette: ThemePalette) -> [MermaidElement] {
        let c = positioned.center
        let r = GitGraphLayout.dotRadius
        let filled = ShapeStyle_(fill: color, stroke: color, strokeWidth: 1)

        switch positioned.commit.type {
        case .normal:
            return [.path(circle(c, r), style: filled)]

        case .highlight:
            // A square reads as "this one matters" at a glance, and can't be confused with a dot.
            return [.rect(CGRect(center: c, size: CGSize(width: r * 2, height: r * 2)), cornerRadius: 2,
                          style: ShapeStyle_(fill: color, stroke: palette.textColor, strokeWidth: 2))]

        case .reverse:
            let cross = CGMutablePath()
            let d = r * 0.5
            cross.move(to: CGPoint(x: c.x - d, y: c.y - d)); cross.addLine(to: CGPoint(x: c.x + d, y: c.y + d))
            cross.move(to: CGPoint(x: c.x + d, y: c.y - d)); cross.addLine(to: CGPoint(x: c.x - d, y: c.y + d))
            return [.path(circle(c, r), style: filled),
                    .path(cross, style: ShapeStyle_(fill: nil, stroke: palette.background, strokeWidth: 2))]

        case .merge:
            return [.path(circle(c, r), style: filled),
                    .path(circle(c, r * innerDotRatio),
                          style: ShapeStyle_(fill: palette.background, stroke: palette.background, strokeWidth: 1))]

        case .cherryPick:
            let offset = r * 0.38
            return [.path(circle(c, r), style: ShapeStyle_(fill: palette.background, stroke: color, strokeWidth: 2)),
                    .path(circle(CGPoint(x: c.x - offset, y: c.y + offset), cherryDotRadius), style: filled),
                    .path(circle(CGPoint(x: c.x + offset, y: c.y + offset), cherryDotRadius), style: filled)]
        }
    }

    // MARK: - Decorations

    /// A rounded rect with a notch pointing back at the commit it belongs to.
    private static func tagElements(_ text: String, at center: CGPoint, pointingAt commit: CGPoint,
                                    palette: ThemePalette) -> [MermaidElement] {
        let size = GitGraphLayout.tagSize(text)
        let d = commit - center
        let len = max(d.length, 0.0001)
        let dir = CGPoint(x: d.x / len, y: d.y / len)
        let perp = CGPoint(x: -dir.y, y: dir.x)
        // The tag is always offset along one axis, so the notch leaves the box through one edge.
        let halfExtent = abs(dir.x) > 0.5 ? size.width / 2 : size.height / 2
        let base = center + dir * halfExtent
        let notch = CGMutablePath()
        notch.move(to: base + perp * 4)
        notch.addLine(to: base + dir * GitGraphLayout.tagNotch)
        notch.addLine(to: base - perp * 4)
        notch.closeSubpath()

        var out = pill(text, center: center, size: size, font: GitGraphLayout.tagFont,
                       fill: palette.noteFill, stroke: palette.noteBorder,
                       textColor: palette.noteTextColor, cornerRadius: 3)
        out.append(.path(notch, style: ShapeStyle_(fill: palette.noteFill, stroke: palette.noteBorder, strokeWidth: 1)))
        return out
    }

    private static func pill(_ text: String, center: CGPoint, size: CGSize, font: FontSpec,
                             fill: CGColor, stroke: CGColor?, textColor: CGColor,
                             cornerRadius: CGFloat) -> [MermaidElement] {
        let rect = CGRect(center: center, size: size)
        let block = TextMeasure.layout(text, font: font)
        return [
            .rect(rect, cornerRadius: cornerRadius,
                  style: ShapeStyle_(fill: fill, stroke: stroke, strokeWidth: stroke == nil ? 0 : 1)),
            .text(text,
                  origin: CGPoint(x: rect.midX, y: rect.midY - block.size.height / 2 + block.firstBaseline),
                  font: font, color: textColor, anchor: .middle)
        ]
    }

    // MARK: - Path helpers

    private static func circle(_ center: CGPoint, _ radius: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.addEllipse(in: CGRect(center: center, size: CGSize(width: radius * 2, height: radius * 2)))
        return p
    }

    private static func line(_ a: CGPoint, _ b: CGPoint) -> CGPath {
        let p = CGMutablePath(); p.move(to: a); p.addLine(to: b); return p
    }

    /// Two points draw a straight segment; four draw the cubic the layout produced for a lane change.
    private static func edgePath(_ points: [CGPoint]) -> CGPath {
        let p = CGMutablePath()
        guard let first = points.first else { return p }
        p.move(to: first)
        if points.count == 4 {
            p.addCurve(to: points[3], control1: points[1], control2: points[2])
        } else {
            for pt in points.dropFirst() { p.addLine(to: pt) }
        }
        return p
    }
}
