import CoreGraphics
import Foundation

/// Places commits on a lane-per-branch grid. There is no graph solver involved: commits sit at
/// their declaration position along the main axis, and at their branch's lane across it — which is
/// what Mermaid does too.
///
/// Everything is computed in `(along, across)` space and mapped to `(x, y)` at the end, so the three
/// directions differ only in that final mapping.
enum GitGraphLayout {

    static let dotRadius: CGFloat = 10
    static let outerMargin: CGFloat = 16
    static let labelGap: CGFloat = 6
    static let tagGap: CGFloat = 6
    static let tagNotch: CGFloat = 5
    static let laneLabelGap: CGFloat = 12
    static let minCommitSpacing: CGFloat = 56
    static let minLaneSpacing: CGFloat = 52

    static let commitLabelFont = FontSpec(family: FontSpec.defaultFamily, size: 11)
    static let tagFont = FontSpec(family: FontSpec.defaultFamily, size: 11, weight: .bold)
    static let branchLabelFont = FontSpec(family: FontSpec.defaultFamily, size: 12, weight: .bold)

    static let labelPadH: CGFloat = 5
    static let labelPadV: CGFloat = 3
    static let tagPadH: CGFloat = 6
    static let tagPadV: CGFloat = 3
    static let branchLabelPadH: CGFloat = 8
    static let branchLabelPadV: CGFloat = 4

    static func labelSize(_ text: String) -> CGSize {
        let s = TextMeasure.layout(text, font: commitLabelFont).size
        return CGSize(width: ceil(s.width) + labelPadH * 2, height: ceil(s.height) + labelPadV * 2)
    }

    static func tagSize(_ text: String) -> CGSize {
        let s = TextMeasure.layout(text, font: tagFont).size
        return CGSize(width: ceil(s.width) + tagPadH * 2, height: ceil(s.height) + tagPadV * 2)
    }

    static func branchLabelSize(_ text: String) -> CGSize {
        let s = TextMeasure.layout(text, font: branchLabelFont).size
        return CGSize(width: ceil(s.width) + branchLabelPadH * 2, height: ceil(s.height) + branchLabelPadV * 2)
    }

    // MARK: - Layout

    static func layout(_ ast: GitGraphAST) -> PositionedGitGraph {
        let horizontal = (ast.direction == .LR)

        // Lane order: explicit `order:` first, declaration order as the tie-break (Swift's sort
        // isn't stable, so the index is part of the comparison rather than relied upon).
        let ordered = ast.branches.enumerated()
            .sorted { a, b in
                a.element.order == b.element.order ? a.offset < b.offset : a.element.order < b.element.order
            }
            .map(\.element)
        var lane: [String: Int] = [:]
        for (i, branch) in ordered.enumerated() { lane[branch.name] = i }

        // Widest decorations decide the spacing, so nothing overlaps regardless of direction.
        var maxLabel = CGSize.zero, maxTag = CGSize.zero
        for commit in ast.commits {
            if let text = commit.label {
                let s = labelSize(text)
                maxLabel = CGSize(width: max(maxLabel.width, s.width), height: max(maxLabel.height, s.height))
            }
            if let text = commit.tag {
                let s = tagSize(text)
                maxTag = CGSize(width: max(maxTag.width, s.width), height: max(maxTag.height, s.height))
            }
        }
        let anyLabel = maxLabel.width > 0
        let anyTag = maxTag.width > 0
        let branchLabelSizes = ordered.map { branchLabelSize($0.name) }
        let maxBranchLabel = CGSize(width: branchLabelSizes.map(\.width).max() ?? 0,
                                    height: branchLabelSizes.map(\.height).max() ?? 0)

        // Room needed either side of a dot, measured across the lanes.
        let leadingAcross: CGFloat
        let trailingAcross: CGFloat
        let laneSpacing: CGFloat
        let commitSpacing: CGFloat
        let bandSize: CGFloat
        if horizontal {
            // Tags sit above the dot, commit labels below; branch labels are a gutter on the left.
            leadingAcross = max(dotRadius + (anyTag ? tagGap + tagNotch + maxTag.height : 0),
                                maxBranchLabel.height / 2)
            trailingAcross = max(dotRadius + (anyLabel ? labelGap + maxLabel.height : 0),
                                 maxBranchLabel.height / 2)
            laneSpacing = max(minLaneSpacing, leadingAcross + trailingAcross + 8)
            commitSpacing = max(minCommitSpacing, maxLabel.width + 12, maxTag.width + 12)
            bandSize = maxBranchLabel.width
        } else {
            // Tags sit left of the dot, commit labels right; branch labels are a band at the start.
            leadingAcross = max(dotRadius + (anyTag ? tagGap + tagNotch + maxTag.width : 0),
                                maxBranchLabel.width / 2)
            trailingAcross = max(dotRadius + (anyLabel ? labelGap + maxLabel.width : 0),
                                 maxBranchLabel.width / 2)
            laneSpacing = max(minLaneSpacing, leadingAcross + trailingAcross + 10)
            commitSpacing = max(46, dotRadius * 2 + 14, maxLabel.height + 10)
            bandSize = maxBranchLabel.height
        }

        // Room needed at each end of the main axis for the first/last commit's decorations.
        let alongOverhang = horizontal
            ? max(dotRadius, maxLabel.width / 2, maxTag.width / 2)
            : dotRadius
        let alongStart = outerMargin + bandSize + laneLabelGap + alongOverhang
        let lastPos = CGFloat(max(0, ast.commits.count - 1))
        let alongTotal = alongStart + lastPos * commitSpacing + alongOverhang + outerMargin

        let acrossStart = outerMargin + leadingAcross
        let lastLane = CGFloat(max(0, ordered.count - 1))
        let acrossTotal = acrossStart + lastLane * laneSpacing + trailingAcross + outerMargin

        func alongOf(_ pos: Int) -> CGFloat { alongStart + CGFloat(pos) * commitSpacing }
        func acrossOf(_ laneIndex: Int) -> CGFloat { acrossStart + CGFloat(laneIndex) * laneSpacing }
        func point(along: CGFloat, across: CGFloat) -> CGPoint {
            switch ast.direction {
            case .LR: return CGPoint(x: r2(along), y: r2(across))
            case .TB: return CGPoint(x: r2(across), y: r2(along))
            case .BT: return CGPoint(x: r2(across), y: r2(alongTotal - along))
            }
        }

        // MARK: commits

        var commitAlong: [String: CGFloat] = [:]
        var commitAcross: [String: CGFloat] = [:]
        var commitLane: [String: Int] = [:]
        var commits: [PositionedGitCommit] = []

        for commit in ast.commits {
            let laneIndex = lane[commit.branch] ?? 0
            let along = alongOf(commit.seq)
            let across = acrossOf(laneIndex)
            commitAlong[commit.id] = along
            commitAcross[commit.id] = across
            commitLane[commit.id] = laneIndex

            // Decorations are always offset across the lanes, never along them, so the same maths
            // works for all three directions.
            let labelOffset: CGFloat
            let tagOffset: CGFloat
            if horizontal {
                labelOffset = dotRadius + labelGap + maxLabel.height / 2
                tagOffset = dotRadius + tagGap + tagNotch + maxTag.height / 2
            } else {
                labelOffset = dotRadius + labelGap + (commit.label.map { labelSize($0).width } ?? 0) / 2
                tagOffset = dotRadius + tagGap + tagNotch + (commit.tag.map { tagSize($0).width } ?? 0) / 2
            }

            commits.append(PositionedGitCommit(
                commit: commit,
                center: point(along: along, across: across),
                colorIndex: laneIndex,
                labelPoint: point(along: along, across: across + labelOffset),
                tagPoint: point(along: along, across: across - tagOffset)
            ))
        }

        // MARK: edges

        var edges: [PositionedGitEdge] = []
        for commit in ast.commits {
            guard let childAlong = commitAlong[commit.id], let childAcross = commitAcross[commit.id] else { continue }
            for (parentIndex, parentID) in commit.parents.enumerated() {
                guard let parentAlong = commitAlong[parentID], let parentAcross = commitAcross[parentID] else { continue }
                // The first parent continues the child's own branch; a second parent is the side
                // being merged (or cherry-picked) in, so it keeps its own branch's colour.
                let colorIndex = parentIndex == 0
                    ? (commitLane[commit.id] ?? 0)
                    : (commitLane[parentID] ?? 0)
                let dashed = (commit.type == .cherryPick && parentIndex == 1)

                let points: [CGPoint]
                if parentAcross == childAcross {
                    points = [point(along: parentAlong, across: parentAcross),
                              point(along: childAlong, across: childAcross)]
                } else {
                    let mid = (parentAlong + childAlong) / 2
                    points = [point(along: parentAlong, across: parentAcross),
                              point(along: mid, across: parentAcross),
                              point(along: mid, across: childAcross),
                              point(along: childAlong, across: childAcross)]
                }
                edges.append(PositionedGitEdge(points: points, colorIndex: colorIndex, dashed: dashed))
            }
        }

        // MARK: lanes

        var lastAlongOnBranch: [String: CGFloat] = [:]
        for commit in ast.commits {
            lastAlongOnBranch[commit.branch] = max(lastAlongOnBranch[commit.branch] ?? 0, alongOf(commit.seq))
        }
        let laneLineStart = outerMargin + bandSize + laneLabelGap
        var lanes: [PositionedGitLane] = []
        for (i, branch) in ordered.enumerated() {
            let across = acrossOf(i)
            let end = lastAlongOnBranch[branch.name] ?? laneLineStart
            lanes.append(PositionedGitLane(
                name: branch.name,
                labelRect: CGRect(center: point(along: outerMargin + bandSize / 2, across: across),
                                  size: branchLabelSizes[i]),
                lineStart: point(along: laneLineStart, across: across),
                lineEnd: point(along: max(end, laneLineStart), across: across),
                colorIndex: i
            ))
        }

        let size = horizontal ? CGSize(width: alongTotal, height: acrossTotal)
                              : CGSize(width: acrossTotal, height: alongTotal)
        return PositionedGitGraph(size: CGSize(width: r2(size.width), height: r2(size.height)),
                                  direction: ast.direction,
                                  commits: commits, edges: edges, lanes: lanes)
    }
}
