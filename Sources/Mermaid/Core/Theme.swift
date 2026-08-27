import CoreGraphics
import Foundation

public enum MermaidTheme: String, Sendable, CaseIterable {
    case `default`   // light
    case dark
    // later: forest, neutral, base
}

/// Concrete colour + metric palette derived from a `MermaidTheme`. Colour values are lifted from
/// Mermaid's `theme-default.js` / `theme-dark.js`.
public struct ThemePalette: Sendable {
    // General
    public var background: CGColor
    public var textColor: CGColor

    // Flowchart nodes
    public var nodeFill: CGColor
    public var nodeBorder: CGColor
    public var nodeTextColor: CGColor
    public var clusterFill: CGColor
    public var clusterBorder: CGColor

    // Edges
    public var edgeStroke: CGColor
    public var edgeLabelBackground: CGColor
    public var edgeLabelColor: CGColor

    // Sequence diagram
    public var actorFill: CGColor
    public var actorBorder: CGColor
    public var actorTextColor: CGColor
    public var signalColor: CGColor       // message lines + arrowheads
    public var signalTextColor: CGColor
    public var lifelineColor: CGColor
    public var labelBoxFill: CGColor      // loop/alt/opt frame label box
    public var labelBoxBorder: CGColor
    public var noteFill: CGColor
    public var noteBorder: CGColor
    public var noteTextColor: CGColor
    public var activationFill: CGColor
    public var activationBorder: CGColor

    // ER diagram
    public var erEntityFill: CGColor
    public var erEntityBorder: CGColor
    public var erAttributeFillOdd: CGColor
    public var erAttributeFillEven: CGColor

    // Git graph — one colour per branch lane, cycled.
    public var gitBranchColors: [CGColor]

    // User journey
    public var journeySectionFills: [CGColor]
    public var journeyFaceFill: CGColor
    public var journeyFaceStroke: CGColor

    // Pie chart
    public var pieStroke: CGColor
    public var pieTitleColor: CGColor
    public var pieSlices: [CGColor]

    public var fontFamily: String { FontSpec.defaultFamily }
}

extension MermaidTheme {
    public var palette: ThemePalette {
        switch self {
        case .default: return .lightDefault
        case .dark: return .darkDefault
        }
    }
}

// MARK: - sRGB helpers

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func hex(_ value: UInt32, alpha: CGFloat = 1) -> CGColor {
    rgb(CGFloat((value >> 16) & 0xFF), CGFloat((value >> 8) & 0xFF), CGFloat(value & 0xFF), alpha)
}

extension CGColor {
    /// Black or white, whichever reads better on top of this colour. Used for text drawn inside a
    /// palette-coloured swatch, where the theme's own text colour may not have enough contrast.
    var contrastingTextColor: CGColor {
        guard let c = converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
              let comps = c.components, comps.count >= 3 else {
            return hex(0x000000)
        }
        func linearise(_ v: CGFloat) -> CGFloat {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linearise(comps[0]) + 0.7152 * linearise(comps[1]) + 0.0722 * linearise(comps[2])
        return luminance > 0.42 ? hex(0x000000) : hex(0xFFFFFF)
    }

    /// `#rrggbb` (or `rgba(...)` when partially transparent) — suitable for an SVG presentation attribute.
    var svgString: String {
        guard let c = converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
              let comps = c.components, comps.count >= 3 else {
            return "#000000"
        }
        let r = Int((comps[0] * 255).rounded())
        let g = Int((comps[1] * 255).rounded())
        let b = Int((comps[2] * 255).rounded())
        let a = comps.count >= 4 ? comps[3] : 1
        let clamp = { (v: Int) in max(0, min(255, v)) }
        if a >= 0.999 {
            return String(format: "#%02x%02x%02x", clamp(r), clamp(g), clamp(b))
        }
        return "rgba(\(clamp(r)),\(clamp(g)),\(clamp(b)),\(r2s(a)))"
    }
}

// MARK: - Palettes

extension ThemePalette {
    static let lightDefault: ThemePalette = {
        let text = hex(0x333333)
        return ThemePalette(
            background: hex(0xFFFFFF),
            textColor: text,
            nodeFill: hex(0xECECFF),
            nodeBorder: hex(0x9370DB),
            nodeTextColor: text,
            clusterFill: hex(0xFFFFDE),
            clusterBorder: hex(0xAAAA33),
            edgeStroke: hex(0x333333),
            edgeLabelBackground: hex(0xE8E8E8),
            edgeLabelColor: text,
            actorFill: hex(0xECECFF),
            actorBorder: hex(0x9370DB),
            actorTextColor: hex(0x000000),
            signalColor: hex(0x333333),
            signalTextColor: hex(0x333333),
            lifelineColor: hex(0x999999),
            labelBoxFill: hex(0xECECFF),
            labelBoxBorder: hex(0x9370DB),
            noteFill: hex(0xFFF5AD),
            noteBorder: hex(0xAAAA33),
            noteTextColor: hex(0x333333),
            activationFill: hex(0xF4F4F4),
            activationBorder: hex(0x666666),
            erEntityFill: hex(0xECECFF),
            erEntityBorder: hex(0x9370DB),
            erAttributeFillOdd: hex(0xFFFFFF),
            erAttributeFillEven: hex(0xF2F2F2),
            gitBranchColors: ThemePalette.lightGitBranchColors,
            journeySectionFills: ThemePalette.lightJourneySectionFills,
            journeyFaceFill: hex(0xFFF4DD),
            journeyFaceStroke: hex(0x999999),
            pieStroke: hex(0x000000),
            pieTitleColor: hex(0x000000),
            pieSlices: ThemePalette.lightPieSlices
        )
    }()

    static let darkDefault: ThemePalette = {
        let text = hex(0xCCCCCC)
        return ThemePalette(
            background: hex(0x1E1E1E),
            textColor: text,
            nodeFill: hex(0x1F2020),
            nodeBorder: hex(0x81B1DB),
            nodeTextColor: hex(0xCCCCCC),
            clusterFill: hex(0x2B2B2B),
            clusterBorder: hex(0x81B1DB),
            edgeStroke: hex(0xCCCCCC),
            edgeLabelBackground: hex(0x2B2B2B),
            edgeLabelColor: text,
            actorFill: hex(0x1F2020),
            actorBorder: hex(0x81B1DB),
            actorTextColor: hex(0xCCCCCC),
            signalColor: hex(0xCCCCCC),
            signalTextColor: hex(0xCCCCCC),
            lifelineColor: hex(0x9F9F9F),
            labelBoxFill: hex(0x1F2020),
            labelBoxBorder: hex(0x81B1DB),
            noteFill: hex(0xE6D2A9),
            noteBorder: hex(0xAAAA33),
            noteTextColor: hex(0x000000),
            activationFill: hex(0x2B2B2B),
            activationBorder: hex(0x81B1DB),
            erEntityFill: hex(0x1F2020),
            erEntityBorder: hex(0x81B1DB),
            erAttributeFillOdd: hex(0x272727),
            erAttributeFillEven: hex(0x2E2E2E),
            gitBranchColors: ThemePalette.darkGitBranchColors,
            journeySectionFills: ThemePalette.darkJourneySectionFills,
            journeyFaceFill: hex(0xE6D2A9),
            journeyFaceStroke: hex(0x8A8A8A),
            pieStroke: hex(0x000000),
            pieTitleColor: hex(0xCCCCCC),
            pieSlices: ThemePalette.darkPieSlices
        )
    }()
}

// Mermaid's pie palette is generated from the theme's primary colour by stepping the hue; we use the
// fixed 12-colour set the Live Editor produces for the default/dark themes.
extension ThemePalette {
    static let lightPieSlices: [CGColor] = [
        hex(0xECECFF), hex(0xffffde), hex(0xb3e6ff), hex(0xffd9d9),
        hex(0xd9f2d9), hex(0xffe6cc), hex(0xe6ccff), hex(0xcce6ff),
        hex(0xfff0b3), hex(0xc2f0c2), hex(0xffc2b3), hex(0xd9d9f2)
    ]
    static let darkPieSlices: [CGColor] = [
        hex(0x4a4a8a), hex(0x8a8a4a), hex(0x4a7a8a), hex(0x8a4a4a),
        hex(0x4a8a5a), hex(0x8a6a4a), hex(0x6a4a8a), hex(0x4a6a8a),
        hex(0x8a7a4a), hex(0x5a8a5a), hex(0x8a5a4a), hex(0x5a5a8a)
    ]
}

// Mermaid derives `git0…git7` and `fillType0…fillType7` from the theme's primary colour at runtime.
// We use fixed sets in the same spirit: eight readable, mutually distinguishable hues per theme.
extension ThemePalette {
    static let lightGitBranchColors: [CGColor] = [
        hex(0x7E57C2), hex(0x26A69A), hex(0xEF6C00), hex(0x42A5F5),
        hex(0xEC407A), hex(0x7CB342), hex(0x8D6E63), hex(0xFFA726)
    ]
    static let darkGitBranchColors: [CGColor] = [
        hex(0xB39DDB), hex(0x4DB6AC), hex(0xFFB74D), hex(0x64B5F6),
        hex(0xF06292), hex(0xAED581), hex(0xBCAAA4), hex(0xFFCC80)
    ]

    static let lightJourneySectionFills: [CGColor] = [
        hex(0xECECFF), hex(0xffffde), hex(0xb3e6ff), hex(0xffd9d9),
        hex(0xd9f2d9), hex(0xffe6cc), hex(0xe6ccff), hex(0xcce6ff)
    ]
    static let darkJourneySectionFills: [CGColor] = [
        hex(0x4a4a8a), hex(0x8a8a4a), hex(0x4a7a8a), hex(0x8a4a4a),
        hex(0x4a8a5a), hex(0x8a6a4a), hex(0x6a4a8a), hex(0x4a6a8a)
    ]
}
