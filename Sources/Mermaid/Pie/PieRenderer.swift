import CoreGraphics
import Foundation

enum PieRenderer {

    static let titleFont = FontSpec(family: FontSpec.defaultFamily, size: 18, weight: .bold)
    static let legendFont = FontSpec(family: FontSpec.defaultFamily, size: 13)
    static let percentFont = FontSpec(family: FontSpec.defaultFamily, size: 13, weight: .bold)
    static let outerMargin: CGFloat = 16
    static let pieRadius: CGFloat = 160
    static let legendGap: CGFloat = 24
    static let legendSwatchSize: CGFloat = 14
    static let legendLineHeight: CGFloat = 22

    static func render(_ ast: PieAST, theme: MermaidTheme) -> MermaidScene {
        let palette = theme.palette

        // Measure legend column width.
        let labelWidth = ast.slices.map { TextMeasure.layout(formatLegendLine(slice: $0, total: totalOf(ast)),
                                                              font: legendFont).size.width }.max() ?? 0
        let legendWidth = legendSwatchSize + 6 + labelWidth
        let legendHeight = CGFloat(ast.slices.count) * legendLineHeight

        let titleHeight: CGFloat
        let titleBlock: TextMeasure.Block?
        if let t = ast.title, !t.isEmpty {
            let b = TextMeasure.layout(t, font: titleFont)
            titleBlock = b
            titleHeight = b.size.height + 12
        } else {
            titleBlock = nil
            titleHeight = 0
        }

        let pieSize = pieRadius * 2 + 8
        let chartArea = CGSize(width: pieSize + legendGap + legendWidth,
                               height: max(pieSize, legendHeight))
        let totalSize = CGSize(width: chartArea.width + outerMargin * 2,
                               height: chartArea.height + titleHeight + outerMargin * 2)

        var elements: [MermaidElement] = []

        // Title (centred at top).
        if let block = titleBlock, let title = ast.title {
            let baselineY = outerMargin + block.firstBaseline
            elements.append(.text(title,
                                  origin: CGPoint(x: totalSize.width / 2, y: baselineY),
                                  font: titleFont, color: palette.pieTitleColor, anchor: .middle))
        }

        let chartTop = outerMargin + titleHeight
        let pieCentre = CGPoint(x: outerMargin + pieSize / 2,
                                y: chartTop + max(pieSize, legendHeight) / 2)

        let total = totalOf(ast)
        if total <= 0 || ast.slices.isEmpty {
            elements.append(.text("(no data)",
                                  origin: CGPoint(x: pieCentre.x, y: pieCentre.y),
                                  font: legendFont, color: palette.textColor, anchor: .middle))
        } else {
            // Slices, starting from -π/2 (top), clockwise. SVG/CG y is down, so +angle goes clockwise.
            var startAngle: CGFloat = -.pi / 2
            for (i, slice) in ast.slices.enumerated() {
                let fraction = CGFloat(slice.value / total)
                let endAngle = startAngle + fraction * 2 * .pi
                let path = CGMutablePath()
                path.move(to: pieCentre)
                path.addArc(center: pieCentre, radius: pieRadius,
                            startAngle: startAngle, endAngle: endAngle, clockwise: false)
                path.closeSubpath()
                let colour = palette.pieSlices[i % palette.pieSlices.count]
                elements.append(.path(path, style: ShapeStyle_(fill: colour,
                                                               stroke: palette.pieStroke,
                                                               strokeWidth: 1)))
                // Percentage label centred along the bisector.
                let midAngle = (startAngle + endAngle) / 2
                let labelR = pieRadius * 0.65
                let pct = Int((fraction * 100).rounded())
                if pct >= 4 {  // only label slices with enough room
                    let cx = pieCentre.x + labelR * cos(midAngle)
                    let cy = pieCentre.y + labelR * sin(midAngle)
                    let pctText = "\(pct)%"
                    let b = TextMeasure.layout(pctText, font: percentFont)
                    elements.append(.text(pctText,
                                          origin: CGPoint(x: cx, y: cy + b.firstBaseline - b.size.height / 2),
                                          font: percentFont, color: palette.textColor, anchor: .middle))
                }
                startAngle = endAngle
            }
        }

        // Legend (right of the pie).
        let legendX = outerMargin + pieSize + legendGap
        let legendY0 = chartTop + max(0, (max(pieSize, legendHeight) - legendHeight) / 2)
        for (i, slice) in ast.slices.enumerated() {
            let rowY = legendY0 + CGFloat(i) * legendLineHeight
            let swatch = CGRect(x: legendX, y: rowY + (legendLineHeight - legendSwatchSize) / 2,
                                width: legendSwatchSize, height: legendSwatchSize)
            elements.append(.rect(swatch, cornerRadius: 0,
                                  style: ShapeStyle_(fill: palette.pieSlices[i % palette.pieSlices.count],
                                                     stroke: palette.pieStroke, strokeWidth: 1)))
            let text = formatLegendLine(slice: slice, total: totalOf(ast))
            let block = TextMeasure.layout(text, font: legendFont)
            let baselineY = swatch.midY + block.firstBaseline - block.size.height / 2
            elements.append(.text(text,
                                  origin: CGPoint(x: swatch.maxX + 6, y: baselineY),
                                  font: legendFont, color: palette.textColor, anchor: .start))
        }

        return MermaidScene(size: totalSize, backgroundColor: palette.background, elements: elements)
    }

    private static func totalOf(_ ast: PieAST) -> Double {
        max(0.0, ast.slices.reduce(0) { $0 + $1.value })
    }

    private static func formatLegendLine(slice: PieSlice, total: Double) -> String {
        if total <= 0 { return slice.label }
        // Show the value with up to one decimal place, dropping trailing .0.
        let v = slice.value
        let valueString: String
        if v == v.rounded() {
            valueString = String(Int(v))
        } else {
            valueString = String(format: "%.1f", v)
        }
        return "\(slice.label) — \(valueString)"
    }
}
