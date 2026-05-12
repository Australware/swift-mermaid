import CoreGraphics
import CoreText
import Foundation

/// Deterministic text metrics via CoreText. This is the reason the package is Apple-only: CoreText
/// gives stable measurements on a given OS, which the layout depends on.
enum TextMeasure {

    struct Line {
        var string: String
        var width: CGFloat
        var ascent: CGFloat
        var descent: CGFloat
        var leading: CGFloat
        var height: CGFloat { ascent + descent + leading }
    }

    struct Block {
        var lines: [Line]
        var size: CGSize
        /// Distance from the top of the block to the first line's baseline.
        var firstBaseline: CGFloat
        /// Vertical advance between consecutive baselines.
        var lineHeight: CGFloat
    }

    private static let fontCache = NSCache<NSString, CTFont>()

    static func font(_ spec: FontSpec) -> CTFont {
        let key = "\(spec.family)|\(spec.size)|\(spec.weight.rawValue)|\(spec.italic)" as NSString
        if let cached = fontCache.object(forKey: key) { return cached }

        var base = CTFontCreateWithName(spec.family as CFString, spec.size, nil)
        var traits: CTFontSymbolicTraits = []
        if spec.weight == .bold { traits.insert(.traitBold) }
        if spec.italic { traits.insert(.traitItalic) }
        if !traits.isEmpty, let withTraits = CTFontCreateCopyWithSymbolicTraits(base, spec.size, nil, traits, traits) {
            base = withTraits
        }
        fontCache.setObject(base, forKey: key)
        return base
    }

    /// Width of a single line of text (no wrapping).
    static func lineWidth(_ string: String, font spec: FontSpec) -> CGFloat {
        measureLine(string, font: font(spec)).width
    }

    private static func measureLine(_ string: String, font ctFont: CTFont) -> Line {
        // Bridge directly to CoreText attribute keys so we don't need AppKit/UIKit.
        let attr = NSAttributedString(string: string, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): ctFont
        ])
        let line = CTLineCreateWithAttributedString(attr)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        // Use the font's own metrics for line spacing so empty lines still have height.
        let fAscent = CTFontGetAscent(ctFont)
        let fDescent = CTFontGetDescent(ctFont)
        let fLeading = CTFontGetLeading(ctFont)
        return Line(string: string,
                    width: max(0, width),
                    ascent: max(ascent, fAscent),
                    descent: max(descent, fDescent),
                    leading: max(leading, fLeading))
    }

    /// Lay out `text` with optional hard wrapping to `maxWidth` (word wrap). `<br/>` / `<br>` and
    /// literal `\n` always force a break. Returns per-line metrics and the bounding size.
    static func layout(_ text: String, font spec: FontSpec, maxWidth: CGFloat? = nil, lineSpacing: CGFloat = 1.15) -> Block {
        let ctFont = font(spec)
        let hardLines = TextMeasure.splitHardLines(text)
        var lines: [Line] = []

        for hard in hardLines {
            if let maxWidth, maxWidth > 0 {
                lines.append(contentsOf: wrap(hard, font: ctFont, maxWidth: maxWidth))
            } else {
                lines.append(measureLine(hard, font: ctFont))
            }
        }
        if lines.isEmpty { lines = [measureLine("", font: ctFont)] }

        let lineHeight = (CTFontGetAscent(ctFont) + CTFontGetDescent(ctFont) + CTFontGetLeading(ctFont)) * lineSpacing
        let width = lines.map(\.width).max() ?? 0
        let height = lineHeight * CGFloat(lines.count)
        let firstBaseline = CTFontGetAscent(ctFont) + (lineHeight - (CTFontGetAscent(ctFont) + CTFontGetDescent(ctFont))) / 2
        return Block(lines: lines, size: CGSize(width: ceil(width), height: ceil(height)),
                     firstBaseline: firstBaseline, lineHeight: lineHeight)
    }

    static func splitHardLines(_ text: String) -> [String] {
        var s = text
        // Normalise the handful of <br> spellings Mermaid accepts.
        for token in ["<br/>", "<br />", "<br>", "<BR/>", "<BR />", "<BR>"] {
            s = s.replacingOccurrences(of: token, with: "\n")
        }
        s = s.replacingOccurrences(of: "\\n", with: "\n")
        let parts = s.components(separatedBy: "\n")
        return parts.isEmpty ? [""] : parts
    }

    private static func wrap(_ text: String, font ctFont: CTFont, maxWidth: CGFloat) -> [Line] {
        let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        if words.isEmpty { return [measureLine("", font: ctFont)] }
        var result: [Line] = []
        var current = ""
        for word in words {
            let candidate = current.isEmpty ? word : current + " " + word
            if measureLine(candidate, font: ctFont).width <= maxWidth || current.isEmpty {
                current = candidate
            } else {
                result.append(measureLine(current, font: ctFont))
                current = word
            }
        }
        if !current.isEmpty || result.isEmpty {
            result.append(measureLine(current, font: ctFont))
        }
        return result
    }
}
