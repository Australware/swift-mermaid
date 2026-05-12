import CoreGraphics
import Foundation

// Small geometry conveniences used across layout and rendering. Everything here is pure value math
// so it stays deterministic.

extension CGPoint {
    static func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint { CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y) }
    static func - (lhs: CGPoint, rhs: CGPoint) -> CGPoint { CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y) }
    static func * (lhs: CGPoint, rhs: CGFloat) -> CGPoint { CGPoint(x: lhs.x * rhs, y: lhs.y * rhs) }

    var length: CGFloat { (x * x + y * y).squareRoot() }

    func distance(to other: CGPoint) -> CGFloat { (self - other).length }

    /// Linear interpolation: `0` → self, `1` → other.
    func lerp(to other: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: x + (other.x - x) * t, y: y + (other.y - y) * t)
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }

    init(center: CGPoint, size: CGSize) {
        self.init(x: center.x - size.width / 2, y: center.y - size.height / 2,
                  width: size.width, height: size.height)
    }

    /// Intersection of the segment from this rect's center towards `point` with the rect's border.
    /// Used to clip an edge so it touches the node outline rather than its centre.
    func borderIntersection(towards point: CGPoint) -> CGPoint {
        let c = center
        let dx = point.x - c.x
        let dy = point.y - c.y
        if dx == 0 && dy == 0 { return c }
        let hw = width / 2
        let hh = height / 2
        // Scale so that the larger of |dx|/hw, |dy|/hh equals 1.
        let scale: CGFloat
        if abs(dx) * hh >= abs(dy) * hw {
            scale = hw / max(abs(dx), 0.0001)
        } else {
            scale = hh / max(abs(dy), 0.0001)
        }
        return CGPoint(x: c.x + dx * scale, y: c.y + dy * scale)
    }
}

/// Round to a fixed precision. Used everywhere coordinates reach a serialized form so that the same
/// `(source, theme, OS)` produces byte-identical SVG / PDF output.
@inline(__always)
func r2(_ value: CGFloat) -> CGFloat {
    (value * 100).rounded() / 100
}

@inline(__always)
func r2s(_ value: CGFloat) -> String {
    let rounded = (value * 100).rounded() / 100
    if rounded == rounded.rounded() {
        return String(Int(rounded))
    }
    // Trim trailing zeros from a 2-dp representation.
    var s = String(format: "%.2f", rounded)
    while s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s.removeLast() }
    if s == "-0" { s = "0" }
    return s
}
