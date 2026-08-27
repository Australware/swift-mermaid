import CoreGraphics
import Foundation

// MARK: - AST

enum GitCommitType {
    case normal
    case reverse
    case highlight
    case merge
    case cherryPick
}

struct GitCommit {
    /// Unique within the diagram. Explicit when the source wrote `id: "…"`, otherwise synthesised.
    var id: String
    /// Drawn beneath (LR) or beside (TB/BT) the commit dot. `nil` for a synthesised id.
    ///
    /// Mermaid labels un-named commits with a random hash, which would break this package's
    /// byte-identical-output guarantee, so those commits are drawn as bare dots instead.
    var label: String?
    var branch: String
    /// `[primary]`, or `[primary, secondary]` for a merge (the merged-in head) or a cherry-pick
    /// (the picked commit).
    var parents: [String]
    var type: GitCommitType
    var tag: String?
    /// Declaration order, which is also the commit's position along the diagram's main axis.
    var seq: Int
}

struct GitBranch {
    var name: String
    /// Explicit `order: n`. Branches without one keep their declaration order, ahead of any
    /// explicitly ordered branch — matching Mermaid's `getBranchesAsObjArray`.
    var order: Double
}

enum GitGraphDirection: String {
    case LR, TB, BT
}

struct GitGraphAST {
    var direction: GitGraphDirection
    /// Declaration order. `main` is always first.
    var branches: [GitBranch]
    /// Declaration order.
    var commits: [GitCommit]
}

// MARK: - Positioned model (layout output)

struct PositionedGitCommit {
    let commit: GitCommit
    var center: CGPoint
    /// Index into `ThemePalette.gitBranchColors`, cycled.
    var colorIndex: Int
    /// Anchor for the commit label, already offset off the dot.
    var labelPoint: CGPoint
    /// Anchor for the tag, already offset off the dot.
    var tagPoint: CGPoint
}

struct PositionedGitEdge {
    /// Two points for a straight segment, or four (`p0, c1, c2, p3`) for a cubic bezier used when
    /// the edge crosses between branch lanes.
    var points: [CGPoint]
    var colorIndex: Int
    /// Cherry-pick provenance is drawn dashed.
    var dashed: Bool
}

struct PositionedGitLane {
    let name: String
    var labelRect: CGRect
    var lineStart: CGPoint
    var lineEnd: CGPoint
    var colorIndex: Int
}

struct PositionedGitGraph {
    let size: CGSize
    let direction: GitGraphDirection
    let commits: [PositionedGitCommit]
    let edges: [PositionedGitEdge]
    let lanes: [PositionedGitLane]
}
