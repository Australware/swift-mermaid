import CoreGraphics
import Foundation

/// Turns a `JourneyAST` into a `MermaidScene`. There is no separate layout pass — a journey is a
/// single row of fixed-width task cards under a band per section, so the geometry falls out of one
/// left-to-right walk.
enum JourneyRenderer {

    static let titleFont = FontSpec(family: FontSpec.defaultFamily, size: 18, weight: .bold)
    static let sectionFont = FontSpec(family: FontSpec.defaultFamily, size: 13, weight: .bold)
    static let taskFont = FontSpec(family: FontSpec.defaultFamily, size: 12)
    static let actorFont = FontSpec(family: FontSpec.defaultFamily, size: 9, weight: .bold)

    static let outerMargin: CGFloat = 16
    static let titleGap: CGFloat = 14
    static let bandVPad: CGFloat = 8
    static let bandGap: CGFloat = 8
    static let sectionGap: CGFloat = 16
    static let taskGap: CGFloat = 8
    static let taskPad: CGFloat = 10
    static let minTaskWidth: CGFloat = 110
    static let maxTaskWidth: CGFloat = 190
    static let faceRadius: CGFloat = 13
    static let faceGap: CGFloat = 8
    static let actorRadius: CGFloat = 8
    static let actorSpacing: CGFloat = 19
    static let actorGap: CGFloat = 6

    static func render(_ ast: JourneyAST, theme: MermaidTheme) -> MermaidScene {
        let palette = theme.palette
        let allTasks = ast.sections.flatMap(\.tasks)
        let anyActors = allTasks.contains { !$0.actors.isEmpty }

        // A uniform card width keeps the row on a grid; it grows to fit the longest task name (up
        // to a cap, past which names wrap) and the busiest actor row.
        let widestName = allTasks.map { TextMeasure.lineWidth($0.name, font: taskFont) }.max() ?? 0
        let mostActors = CGFloat(allTasks.map(\.actors.count).max() ?? 0)
        let taskWidth = max(minTaskWidth,
                            min(maxTaskWidth, ceil(widestName) + taskPad * 2),
                            mostActors * actorSpacing + taskPad * 2)
        let innerWidth = taskWidth - taskPad * 2

        let nameBlocks = allTasks.map { TextMeasure.layout($0.name, font: taskFont, maxWidth: innerWidth) }
        let nameHeight = nameBlocks.map(\.size.height).max() ?? 0
        let actorRowHeight = anyActors ? actorRadius * 2 + actorGap : 0
        let taskHeight = ceil(taskPad * 2 + actorRowHeight + faceRadius * 2 + faceGap + nameHeight)

        let sectionBlocks = ast.sections.map { TextMeasure.layout($0.name, font: sectionFont) }
        let bandHeight = ceil((sectionBlocks.map(\.size.height).max() ?? 0) + bandVPad * 2)
        let hasBand = ast.sections.contains { !$0.name.isEmpty }

        // Widths: a section spans its own tasks, or its label if it has none.
        let sectionWidths: [CGFloat] = ast.sections.enumerated().map { i, section in
            guard !section.tasks.isEmpty else {
                return max(taskWidth, ceil(sectionBlocks[i].size.width) + taskPad * 2)
            }
            return CGFloat(section.tasks.count) * taskWidth + CGFloat(section.tasks.count - 1) * taskGap
        }
        let contentWidth = sectionWidths.reduce(0, +)
            + CGFloat(max(0, ast.sections.count - 1)) * sectionGap

        var titleHeight: CGFloat = 0
        var titleBlock: TextMeasure.Block? = nil
        if let title = ast.title, !title.isEmpty {
            let block = TextMeasure.layout(title, font: titleFont)
            titleBlock = block
            titleHeight = block.size.height + titleGap
        }

        let size = CGSize(width: max(contentWidth, 120) + outerMargin * 2,
                          height: outerMargin * 2 + titleHeight
                              + (hasBand ? bandHeight + bandGap : 0)
                              + (allTasks.isEmpty ? 0 : taskHeight))

        var elements: [MermaidElement] = []

        if let block = titleBlock, let title = ast.title {
            elements.append(.text(title, origin: CGPoint(x: size.width / 2, y: outerMargin + block.firstBaseline),
                                  font: titleFont, color: palette.pieTitleColor, anchor: .middle))
        }

        let bandTop = outerMargin + titleHeight
        let taskTop = bandTop + (hasBand ? bandHeight + bandGap : 0)

        var x = outerMargin
        var taskIndex = 0
        for (i, section) in ast.sections.enumerated() {
            let fill = palette.journeySectionFills[i % palette.journeySectionFills.count]
            let sectionWidth = sectionWidths[i]

            if hasBand {
                let band = CGRect(x: x, y: bandTop, width: sectionWidth, height: bandHeight)
                elements.append(.rect(band, cornerRadius: 4,
                                      style: ShapeStyle_(fill: fill, stroke: nil, strokeWidth: 0)))
                if !section.name.isEmpty {
                    let block = sectionBlocks[i]
                    elements.append(.text(section.name,
                                          origin: CGPoint(x: band.midX,
                                                          y: band.midY - block.size.height / 2 + block.firstBaseline),
                                          font: sectionFont, color: palette.textColor, anchor: .middle))
                }
            }

            for task in section.tasks {
                let card = CGRect(x: x, y: taskTop, width: taskWidth, height: taskHeight)
                elements.append(contentsOf: renderTask(task, in: card, nameBlock: nameBlocks[taskIndex],
                                                       fill: fill, actorRowHeight: actorRowHeight,
                                                       ast: ast, palette: palette))
                taskIndex += 1
                x += taskWidth + taskGap
            }
            if !section.tasks.isEmpty { x -= taskGap }
            x += sectionGap
        }

        return MermaidScene(size: size, backgroundColor: palette.background, elements: elements)
    }

    // MARK: - One task card

    private static func renderTask(_ task: JourneyTask, in card: CGRect, nameBlock: TextMeasure.Block,
                                   fill: CGColor, actorRowHeight: CGFloat,
                                   ast: JourneyAST, palette: ThemePalette) -> [MermaidElement] {
        var out: [MermaidElement] = [
            .rect(card, cornerRadius: 5,
                  style: ShapeStyle_(fill: fill, stroke: palette.nodeBorder, strokeWidth: 1))
        ]

        var y = card.minY + taskPad

        // Actor chips: a coloured disc per actor, carrying their initial so the colours mean
        // something without a legend. Colours come from the git-branch set, which is the palette's
        // only high-contrast categorical ramp.
        if actorRowHeight > 0, !task.actors.isEmpty {
            let totalWidth = CGFloat(task.actors.count - 1) * actorSpacing
            var cx = card.midX - totalWidth / 2
            let cy = y + actorRadius
            for actor in task.actors {
                let index = ast.actors.firstIndex(of: actor) ?? 0
                let color = palette.gitBranchColors[index % palette.gitBranchColors.count]
                out.append(.path(circle(CGPoint(x: cx, y: cy), actorRadius),
                                 style: ShapeStyle_(fill: color, stroke: color, strokeWidth: 1)))
                if let initial = actor.first {
                    let text = String(initial).uppercased()
                    let block = TextMeasure.layout(text, font: actorFont)
                    out.append(.text(text,
                                     origin: CGPoint(x: cx, y: cy - block.size.height / 2 + block.firstBaseline),
                                     font: actorFont, color: color.contrastingTextColor, anchor: .middle))
                }
                cx += actorSpacing
            }
        }
        y += actorRowHeight

        out.append(contentsOf: face(score: task.score,
                                    center: CGPoint(x: card.midX, y: y + faceRadius),
                                    palette: palette))
        y += faceRadius * 2 + faceGap

        let firstBaselineY = y + nameBlock.firstBaseline
        for (i, line) in nameBlock.lines.enumerated() {
            out.append(.text(line.string,
                             origin: CGPoint(x: card.midX, y: firstBaselineY + nameBlock.lineHeight * CGFloat(i)),
                             font: taskFont, color: palette.textColor, anchor: .middle))
        }
        return out
    }

    /// Mermaid's mapping: above 3 smiles, below 3 frowns, exactly 3 is ambivalent.
    private static func face(score: Int?, center c: CGPoint, palette: ThemePalette) -> [MermaidElement] {
        let ink = ShapeStyle_(fill: nil, stroke: palette.journeyFaceStroke, strokeWidth: 1.5)
        var out: [MermaidElement] = [
            .path(circle(c, faceRadius),
                  style: ShapeStyle_(fill: palette.journeyFaceFill, stroke: palette.journeyFaceStroke, strokeWidth: 1.5))
        ]
        let eyes = CGMutablePath()
        eyes.addEllipse(in: CGRect(center: CGPoint(x: c.x - 4.5, y: c.y - 3.5), size: CGSize(width: 3, height: 3)))
        eyes.addEllipse(in: CGRect(center: CGPoint(x: c.x + 4.5, y: c.y - 3.5), size: CGSize(width: 3, height: 3)))
        out.append(.path(eyes, style: ShapeStyle_(fill: palette.journeyFaceStroke, stroke: nil, strokeWidth: 0)))

        let mouth = CGMutablePath()
        switch score {
        case .some(let s) where s > 3:
            mouth.move(to: CGPoint(x: c.x - 6, y: c.y + 2))
            mouth.addQuadCurve(to: CGPoint(x: c.x + 6, y: c.y + 2), control: CGPoint(x: c.x, y: c.y + 9))
        case .some(let s) where s < 3:
            mouth.move(to: CGPoint(x: c.x - 6, y: c.y + 6))
            mouth.addQuadCurve(to: CGPoint(x: c.x + 6, y: c.y + 6), control: CGPoint(x: c.x, y: c.y - 1))
        default:
            mouth.move(to: CGPoint(x: c.x - 5.5, y: c.y + 4))
            mouth.addLine(to: CGPoint(x: c.x + 5.5, y: c.y + 4))
        }
        out.append(.path(mouth, style: ink))
        return out
    }

    private static func circle(_ center: CGPoint, _ radius: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.addEllipse(in: CGRect(center: center, size: CGSize(width: radius * 2, height: radius * 2)))
        return p
    }
}
