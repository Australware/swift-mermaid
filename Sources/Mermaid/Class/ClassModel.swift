import CoreGraphics
import Foundation

// MARK: - AST

/// Decoration drawn at one end of a relationship line.
enum ClassRelationKind {
    /// `<|` / `|>` — inheritance (when the line is solid) or realization (when dashed). Hollow triangle.
    case extends
    /// `*` — composition. Filled diamond.
    case composition
    /// `o` — aggregation. Hollow diamond.
    case aggregation
    /// `<` / `>` — association / dependency. Open ("V") arrowhead.
    case association
    /// No marker on this end.
    case none
}

enum ClassLineStyle {
    case solid     // `--`
    case dashed    // `..`
}

/// One line inside a class box. `isMethod` is `true` for operations (the text contains `(`),
/// `false` for attributes/fields. The text is kept as written (visibility token included).
struct ClassMember {
    var text: String
    var isMethod: Bool
}

struct ClassDef {
    var id: String
    /// Display name. `label` if `class X["label"]` was used; otherwise the id with any `~Generic~`
    /// rewritten to `<Generic>`.
    var name: String
    /// `«stereotype»` line drawn above the name (e.g. `interface`, `abstract`, `enumeration`).
    var annotation: String?
    var members: [ClassMember]   // attributes, in declaration order
    var methods: [ClassMember]   // operations, in declaration order
}

struct ClassRelation {
    var id1: String
    var id2: String
    /// Marker drawn at `id1`'s end of the line.
    var startKind: ClassRelationKind
    /// Marker drawn at `id2`'s end of the line.
    var endKind: ClassRelationKind
    var lineStyle: ClassLineStyle
    var label: String?
    var startCardinality: String?    // e.g. "1"
    var endCardinality: String?      // e.g. "0..*"
}

enum ClassDirection: String {
    case TB, BT, LR, RL
}

struct ClassDiagramAST {
    var direction: ClassDirection
    var classes: [String: ClassDef]
    /// Order of first appearance — keeps layout deterministic regardless of dictionary iteration.
    var classOrder: [String]
    var relations: [ClassRelation]
}

// MARK: - Positioned model (layout output)

struct PositionedClassBox {
    let def: ClassDef
    /// Outer box rect. `rect.size` equals `ClassBoxMetrics.measure(def).size`.
    var rect: CGRect
}

struct PositionedClassRelation {
    let id1: String
    let id2: String
    /// Polyline from `id1`'s border to `id2`'s border (already clipped, already retracted behind
    /// any end markers).
    var points: [CGPoint]
    let startKind: ClassRelationKind
    let endKind: ClassRelationKind
    let lineStyle: ClassLineStyle
    let label: String?
    var labelPoint: CGPoint?
    let startCardinality: String?
    let endCardinality: String?
}

struct PositionedClassDiagram {
    let size: CGSize
    let boxes: [PositionedClassBox]
    let relations: [PositionedClassRelation]
}
