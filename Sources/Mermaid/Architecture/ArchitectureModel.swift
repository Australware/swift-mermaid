import CoreGraphics
import Foundation

// MARK: - AST for `architecture-beta` diagrams

enum ArchSide: String {
    case L, R, T, B

    var isHorizontal: Bool { self == .L || self == .R }

    /// Unit vector pointing *out of* the side (SVG/CG coords, y down).
    var outward: CGPoint {
        switch self {
        case .L: return CGPoint(x: -1, y: 0)
        case .R: return CGPoint(x: 1, y: 0)
        case .T: return CGPoint(x: 0, y: -1)
        case .B: return CGPoint(x: 0, y: 1)
        }
    }

    /// Grid step from a node towards the node attached to this side. `db:L -- R:server` means
    /// db's left side faces server, i.e. server sits one cell to the left of db.
    var gridDelta: (dc: Int, dr: Int) {
        switch self {
        case .L: return (-1, 0)
        case .R: return (1, 0)
        case .T: return (0, -1)
        case .B: return (0, 1)
        }
    }
}

/// The five icon names Mermaid ships natively. Anything else (including custom `"pack:icon"`
/// references) maps to `.generic` — custom icon packs are out of scope for now.
enum ArchIcon: String {
    case cloud
    case database
    case disk
    case internet
    case server
    case generic

    init(name: String?) {
        guard let name, !name.isEmpty else { self = .generic; return }
        self = ArchIcon(rawValue: name.lowercased()) ?? .generic
    }
}

struct ArchService {
    let id: String
    let title: String
    let icon: ArchIcon
    /// Immediate parent group, if any.
    var groupID: String?
    /// Junctions are invisible 0-size connection points.
    let isJunction: Bool
}

struct ArchGroup {
    let id: String
    let title: String
    let icon: ArchIcon
    var parentID: String?
}

/// One edge endpoint: a node id, the side it attaches to, and whether the `{group}` marker was
/// present (meaning the edge connects to the node's containing group's boundary, not the node).
struct ArchEdgeEnd {
    let id: String
    let side: ArchSide
    let viaGroup: Bool
}

struct ArchEdge {
    let lhs: ArchEdgeEnd
    let rhs: ArchEdgeEnd
    /// `<--` puts an arrowhead on the lhs; `-->` on the rhs; `<-->` on both; `--` on neither.
    let arrowLhs: Bool
    let arrowRhs: Bool
}

struct ArchitectureAST {
    var services: [String: ArchService] = [:]
    var serviceOrder: [String] = []
    var groups: [String: ArchGroup] = [:]
    var groupOrder: [String] = []
    var edges: [ArchEdge] = []

    var isEmpty: Bool { services.isEmpty && groups.isEmpty }
}
