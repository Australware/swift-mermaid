import CoreGraphics
import CoreText
import Foundation

extension MermaidScene {

    /// Rasterise into a bitmap at the given scale (1 = points, 2 = retina, etc.).
    public func cgImage(scale: CGFloat) -> CGImage? {
        let s = max(scale, 0.01)
        let pixelWidth = Int((size.width * s).rounded(.up))
        let pixelHeight = Int((size.height * s).rounded(.up))
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil,
                                  width: pixelWidth,
                                  height: pixelHeight,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }

        ctx.scaleBy(x: s, y: s)
        // Flip to match SVG (origin at top-left, y growing downward).
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        draw(into: ctx)
        return ctx.makeImage()
    }

    /// A single-page PDF document. Stays vector-correct at any zoom.
    public func pdfData() -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else { return Data() }
        var box = CGRect(origin: .zero, size: size)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        ctx.beginPDFPage(nil)
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        draw(into: ctx)
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    // MARK: - Drawing

    private func draw(into ctx: CGContext) {
        if let bg = backgroundColor {
            ctx.setFillColor(bg)
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        for element in elements {
            draw(element, into: ctx)
        }
    }

    private func draw(_ element: MermaidElement, into ctx: CGContext) {
        switch element {
        case let .rect(rect, cornerRadius, style):
            let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
            stroke(path: path, style: style, into: ctx, fillRule: .winding)
        case let .path(path, style):
            stroke(path: path, style: style, into: ctx, fillRule: .evenOdd)
        case let .text(string, origin, font, color, anchor):
            drawText(string, origin: origin, font: font, color: color, anchor: anchor, into: ctx)
        }
    }

    private func stroke(path: CGPath, style: ShapeStyle_, into ctx: CGContext, fillRule: CGPathFillRule) {
        ctx.saveGState()
        ctx.addPath(path)
        if let fill = style.fill {
            ctx.setFillColor(fill)
            ctx.drawPath(using: fillRule == .evenOdd ? .eoFill : .fill)
        }
        if let stroke = style.stroke {
            ctx.addPath(path)
            ctx.setStrokeColor(stroke)
            ctx.setLineWidth(style.strokeWidth)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            if let dash = style.dash, !dash.isEmpty {
                ctx.setLineDash(phase: 0, lengths: dash)
            }
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    private func drawText(_ string: String,
                          origin: CGPoint,
                          font spec: FontSpec,
                          color: CGColor,
                          anchor: TextAnchor,
                          into ctx: CGContext) {
        let ctFont = TextMeasure.font(spec)
        let attr = NSAttributedString(string: string, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): ctFont,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ])
        let line = CTLineCreateWithAttributedString(attr)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let xOffset: CGFloat
        switch anchor {
        case .start: xOffset = 0
        case .middle: xOffset = -width / 2
        case .end: xOffset = -width
        }

        ctx.saveGState()
        // Undo the Y-flip so CoreText draws right-side-up, then move into position.
        ctx.translateBy(x: origin.x + xOffset, y: origin.y)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
