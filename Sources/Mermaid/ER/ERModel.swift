import CoreGraphics
import Foundation

// MARK: - AST

/// Crow's-foot cardinality for one end of a relationship.
///
/// Mermaid spells these with a two-character token whose orientation depends on which end it sits
/// on — `|o`/`o|` (zero or one), `||`/`||` (exactly one), `}o`/`o{` (zero or more),
/// `}|`/`|{` (one or more). Both spellings map onto the cases here.
enum ERCardinality {
    case zeroOrOne
    case exactlyOne
    case zeroOrMore
    case oneOrMore
}

enum ERLineStyle {
    case identifying      // `--`
    case nonIdentifying   // `..`
}

/// One row in an entity's attribute table.
struct ERAttribute {
    var type: String
    var name: String
    /// `PK` / `FK` / `UK` tokens, in the order written.
    var keys: [String]
    var comment: String?
}

struct EREntity {
    var id: String
    /// Display name — the `[alias]` if one was given, otherwise the id.
    var name: String
    var attributes: [ERAttribute]
}

struct ERRelationship {
    var lhsID: String
    var rhsID: String
    var lhsCardinality: ERCardinality
    var rhsCardinality: ERCardinality
    var lineStyle: ERLineStyle
    var label: String?
}

enum ERDirection: String {
    case TB, BT, LR, RL
}

struct ERDiagramAST {
    /// Mermaid's `er.layoutDirection` defaults to `TB`.
    var direction: ERDirection
    var entities: [String: EREntity]
    /// Order of first appearance — keeps layout deterministic regardless of dictionary iteration.
    var entityOrder: [String]
    var relationships: [ERRelationship]
}

// MARK: - Positioned model (layout output)

struct PositionedEREntity {
    let entity: EREntity
    /// Outer box rect. `rect.size` equals `EREntityMetrics.measure(entity).size`.
    var rect: CGRect
}

struct PositionedERRelationship {
    let lhsID: String
    let rhsID: String
    /// Polyline from the lhs entity's border to the rhs entity's border.
    var points: [CGPoint]
    let lhsCardinality: ERCardinality
    let rhsCardinality: ERCardinality
    let lineStyle: ERLineStyle
    let label: String?
    var labelPoint: CGPoint?
}

struct PositionedERDiagram {
    let size: CGSize
    let entities: [PositionedEREntity]
    let relationships: [PositionedERRelationship]
}
