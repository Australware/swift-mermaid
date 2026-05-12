import CoreGraphics
import Foundation

// MARK: - Font

/// Resolution-independent description of a font run used by a `MermaidElement.text`.
public struct FontSpec: Hashable, Sendable {
    public enum Weight: String, Hashable, Sendable {
        case regular
        case bold
    }

    public var family: String
    public var size: CGFloat
    public var weight: Weight
    public var italic: Bool

    public init(family: String = FontSpec.defaultFamily,
                size: CGFloat = 16,
                weight: Weight = .regular,
                italic: Bool = false) {
        self.family = family
        self.size = size
        self.weight = weight
        self.italic = italic
    }

    /// The CoreText font name used for measurement. We deliberately measure with a font that is
    /// always present on macOS so layout is deterministic across machines; the SVG output advertises
    /// a broader `font-family` stack (see `FontSpec.cssFamily`).
    public static let defaultFamily = "Helvetica"

    /// `font-family` value emitted into SVG / used as a hint for external renderers.
    public var cssFamily: String {
        // Mermaid's stack is "trebuchet ms", verdana, arial, sans-serif. We lead with the font we
        // actually measured with so a CoreGraphics-backed consumer matches our metrics exactly.
        "\(family), 'Helvetica Neue', Helvetica, Arial, sans-serif"
    }
}

// MARK: - Text anchor

public enum TextAnchor: String, Hashable, Sendable {
    case start
    case middle
    case end
}

// MARK: - Stroke / fill style

/// Paint + stroke description shared by rects and paths. (`ShapeStyle` collides with SwiftUI, hence
/// the trailing underscore in the public name, matching the spec.)
public struct ShapeStyle_: @unchecked Sendable {
    public var fill: CGColor?
    public var stroke: CGColor?
    public var strokeWidth: CGFloat
    /// Dash pattern in points (e.g. `[4, 3]`); `nil` means a solid line.
    public var dash: [CGFloat]?

    public init(fill: CGColor? = nil,
                stroke: CGColor? = nil,
                strokeWidth: CGFloat = 1,
                dash: [CGFloat]? = nil) {
        self.fill = fill
        self.stroke = stroke
        self.strokeWidth = strokeWidth
        self.dash = dash
    }
}

// MARK: - Scene elements

public enum MermaidElement {
    case rect(CGRect, cornerRadius: CGFloat, style: ShapeStyle_)
    case path(CGPath, style: ShapeStyle_)
    case text(String, origin: CGPoint, font: FontSpec, color: CGColor, anchor: TextAnchor)
}

// MARK: - Scene

/// A resolution-independent geometry + style model produced by `Mermaid.render`.
public struct MermaidScene {
    public let size: CGSize
    public let backgroundColor: CGColor?
    public let elements: [MermaidElement]

    public init(size: CGSize, backgroundColor: CGColor?, elements: [MermaidElement]) {
        self.size = size
        self.backgroundColor = backgroundColor
        self.elements = elements
    }
}

// `CGColor` / `CGPath` are immutable reference types that are safe to share. Recent SDKs vend
// Sendable conformances for them, so the structs above suffice. If you build against an SDK that
// doesn't, drop in `@unchecked Sendable` here.
extension MermaidElement: @unchecked Sendable {}
extension MermaidScene: @unchecked Sendable {}
