import CoreGraphics
import Foundation

extension MermaidScene {
    /// A standalone SVG document. Uses presentation attributes only (no `<style>` block) so it renders
    /// in `NSImage`'s SVG engine and other simple renderers. Coordinates are rounded to 2 dp, so the
    /// output is byte-stable for a given `(source, theme, OS)`.
    public func svgString() -> String {
        var out = ""
        let w = r2s(size.width)
        let h = r2s(size.height)
        out += #"<svg xmlns="http://www.w3.org/2000/svg" width="\#(w)" height="\#(h)" viewBox="0 0 \#(w) \#(h)">"#
        out += "\n"
        if let bg = backgroundColor {
            out += #"<rect x="0" y="0" width="\#(w)" height="\#(h)" fill="\#(bg.svgString)"/>"# + "\n"
        }
        for element in elements {
            out += svg(for: element)
            out += "\n"
        }
        out += "</svg>\n"
        return out
    }

    private func svg(for element: MermaidElement) -> String {
        switch element {
        case let .rect(rect, cornerRadius, style):
            var s = #"<rect x="\#(r2s(rect.minX))" y="\#(r2s(rect.minY))" width="\#(r2s(rect.width))" height="\#(r2s(rect.height))""#
            if cornerRadius > 0 { s += #" rx="\#(r2s(cornerRadius))" ry="\#(r2s(cornerRadius))""# }
            s += paintAttributes(style)
            s += "/>"
            return s
        case let .path(path, style):
            return #"<path d="\#(SVGPath.string(for: path))"\#(paintAttributes(style, fillRule: true))/>"#
        case let .text(string, origin, font, color, anchor):
            var s = #"<text x="\#(r2s(origin.x))" y="\#(r2s(origin.y))""#
            s += #" font-family="\#(escapeAttr(font.cssFamily))" font-size="\#(r2s(font.size))""#
            if font.weight == .bold { s += #" font-weight="bold""# }
            if font.italic { s += #" font-style="italic""# }
            s += #" fill="\#(color.svgString)""#
            s += #" text-anchor="\#(anchor.rawValue)""#
            // We measured the baseline ourselves, so keep the renderer from re-aligning.
            s += #" dominant-baseline="alphabetic""#
            s += ">\(escapeText(string))</text>"
            return s
        }
    }

    private func paintAttributes(_ style: ShapeStyle_, fillRule: Bool = false) -> String {
        var s = ""
        s += #" fill="\#(style.fill?.svgString ?? "none")""#
        if fillRule { s += #" fill-rule="evenodd""# }
        if let stroke = style.stroke {
            s += #" stroke="\#(stroke.svgString)""#
            s += #" stroke-width="\#(r2s(style.strokeWidth))""#
            if let dash = style.dash, !dash.isEmpty {
                s += #" stroke-dasharray="\#(dash.map { r2s($0) }.joined(separator: ","))""#
            }
            s += #" stroke-linecap="round" stroke-linejoin="round""#
        }
        return s
    }
}

enum SVGPath {
    static func string(for path: CGPath) -> String {
        var out = ""
        path.applyWithBlock { elementPtr in
            let e = elementPtr.pointee
            switch e.type {
            case .moveToPoint:
                let p = e.points[0]
                out += "M\(r2s(p.x)) \(r2s(p.y))"
            case .addLineToPoint:
                let p = e.points[0]
                out += "L\(r2s(p.x)) \(r2s(p.y))"
            case .addQuadCurveToPoint:
                let c = e.points[0], p = e.points[1]
                out += "Q\(r2s(c.x)) \(r2s(c.y)) \(r2s(p.x)) \(r2s(p.y))"
            case .addCurveToPoint:
                let c1 = e.points[0], c2 = e.points[1], p = e.points[2]
                out += "C\(r2s(c1.x)) \(r2s(c1.y)) \(r2s(c2.x)) \(r2s(c2.y)) \(r2s(p.x)) \(r2s(p.y))"
            case .closeSubpath:
                out += "Z"
            @unknown default:
                break
            }
        }
        return out
    }
}

func escapeText(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count)
    for ch in s {
        switch ch {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        default: out.append(ch)
        }
    }
    return out
}

func escapeAttr(_ s: String) -> String {
    var out = escapeText(s)
    out = out.replacingOccurrences(of: "\"", with: "&quot;")
    return out
}
