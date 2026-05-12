import CoreGraphics
import Foundation

enum SequenceRenderer {

    // Layout constants (in points). Roughly match Mermaid's defaults.
    static let headerPaddingV: CGFloat = 16
    static let actorHeaderPadH: CGFloat = 14
    static let actorHeaderPadV: CGFloat = 10
    static let minActorWidth: CGFloat = 60
    static let actorGap: CGFloat = 60
    static let messageSpacing: CGFloat = 36
    static let messageLabelGap: CGFloat = 6
    static let notePadH: CGFloat = 10
    static let notePadV: CGFloat = 8
    static let noteSpacing: CGFloat = 14
    static let groupPaddingTop: CGFloat = 24
    static let groupPaddingBottom: CGFloat = 14
    static let groupLabelBoxW: CGFloat = 50
    static let groupLabelBoxH: CGFloat = 18
    static let activationWidth: CGFloat = 10
    static let outerMargin: CGFloat = 16

    static let actorFont = FontSpec(family: FontSpec.defaultFamily, size: 14, weight: .bold)
    static let messageFont = FontSpec(family: FontSpec.defaultFamily, size: 13)
    static let noteFont = FontSpec(family: FontSpec.defaultFamily, size: 13)
    static let groupLabelFont = FontSpec(family: FontSpec.defaultFamily, size: 11, weight: .bold)
    static let groupTextFont = FontSpec(family: FontSpec.defaultFamily, size: 12)
    static let autonumberFont = FontSpec(family: FontSpec.defaultFamily, size: 11)

    static func render(_ ast: SequenceAST, theme: MermaidTheme) -> MermaidScene {
        let palette = theme.palette

        // Step 1: measure each actor's header width.
        var actorWidth: [String: CGFloat] = [:]
        for actor in ast.actors {
            let block = TextMeasure.layout(actor.label, font: actorFont)
            actorWidth[actor.id] = max(minActorWidth, block.size.width + actorHeaderPadH * 2)
        }

        // Step 2: compute pairwise minimum gaps between adjacent actor centres.
        var gap: [CGFloat] = Array(repeating: actorGap, count: max(0, ast.actors.count - 1))

        func actorIndex(_ id: String) -> Int? { ast.actorIndex[id] }
        func widen(between leftIdx: Int, _ rightIdx: Int, width: CGFloat) {
            let lo = min(leftIdx, rightIdx), hi = max(leftIdx, rightIdx)
            if lo == hi { return }   // self → handled separately
            let per = width / CGFloat(hi - lo)
            for i in lo..<hi { if i < gap.count { gap[i] = max(gap[i], per) } }
        }

        // Walk statements once to collect width constraints.
        var msgCount = 0
        func collectConstraints(_ stmts: [SequenceStatement]) {
            for s in stmts {
                switch s {
                case .message(let m):
                    msgCount += 1
                    let textW = TextMeasure.layout(m.text, font: messageFont).size.width + 16
                    if let li = actorIndex(m.fromID), let ri = actorIndex(m.toID) {
                        widen(between: li, ri, width: textW)
                    }
                case .note(let n):
                    let textW = TextMeasure.layout(n.text, font: noteFont).size.width + notePadH * 2
                    switch n.placement {
                    case .leftOf, .rightOf:
                        break  // single actor — affects margin, not gap
                    case .over(let ids):
                        guard let firstID = ids.first, let lastID = ids.last,
                              let li = actorIndex(firstID), let ri = actorIndex(lastID) else { continue }
                        widen(between: li, ri, width: textW)
                    }
                case .loop(_, let body), .opt(_, let body):
                    collectConstraints(body)
                case .alt(let branches), .par(let branches):
                    for branch in branches { collectConstraints(branch.body) }
                case .activate, .deactivate:
                    break
                }
            }
        }
        collectConstraints(ast.statements)

        // Step 3: compute actor X positions (centres).
        var x: [String: CGFloat] = [:]
        var leftEdgeMargin: CGFloat = 0   // for `Note left of A`
        let leftAdj = ast.statements.compactMap { stmt -> CGFloat? in
            if case let .note(n) = stmt, case .leftOf = n.placement {
                return TextMeasure.layout(n.text, font: noteFont).size.width + notePadH * 2 + 20
            }
            return nil
        }
        leftEdgeMargin = leftAdj.max() ?? 0

        var cursor: CGFloat = outerMargin + leftEdgeMargin
        if !ast.actors.isEmpty {
            cursor += (actorWidth[ast.actors[0].id] ?? minActorWidth) / 2
            x[ast.actors[0].id] = cursor
            for i in 1..<ast.actors.count {
                cursor += gap[i - 1]
                let aw = actorWidth[ast.actors[i].id] ?? minActorWidth
                cursor = max(cursor, (x[ast.actors[i - 1].id] ?? 0) + aw / 2 + (actorWidth[ast.actors[i - 1].id] ?? minActorWidth) / 2 + 20)
                x[ast.actors[i].id] = cursor
            }
        }

        // Step 4: compute Y positions for everything by walking statements.
        var y: CGFloat = outerMargin + actorHeaderHeight() + headerPaddingV
        var laidMessages: [LMessage] = []
        var laidNotes: [LNote] = []
        var laidGroups: [LGroup] = []

        // Activation stacks per actor.
        var activeBars: [String: [CGFloat]] = [:]   // map: actor id → stack of start Ys
        var laidActivations: [LActivation] = []
        var autonumberCounter = 0

        func openActivation(_ id: String, at y: CGFloat) {
            activeBars[id, default: []].append(y)
        }
        func closeActivation(_ id: String, at y: CGFloat) {
            if var stack = activeBars[id], let start = stack.popLast() {
                activeBars[id] = stack
                laidActivations.append(LActivation(actorID: id, startY: start, endY: y))
            }
        }

        func walk(_ stmts: [SequenceStatement]) {
            for s in stmts {
                switch s {
                case .message(let m):
                    autonumberCounter += 1
                    let textBlock = TextMeasure.layout(m.text, font: messageFont)
                    let isSelf = m.fromID == m.toID
                    let height = isSelf ? max(messageSpacing, textBlock.size.height + 28) : max(messageSpacing, textBlock.size.height + messageLabelGap + 12)
                    if m.activates { openActivation(m.toID, at: y + (isSelf ? 0 : 8)) }
                    if m.deactivates { closeActivation(m.fromID, at: y + 0) }
                    laidMessages.append(LMessage(message: m, y: y, number: ast.autonumber ? autonumberCounter : nil,
                                                 textHeight: textBlock.size.height, isSelf: isSelf))
                    y += height
                case .activate(let id):
                    openActivation(id, at: y - 4)
                case .deactivate(let id):
                    closeActivation(id, at: y + 4)
                case .note(let n):
                    let block = TextMeasure.layout(n.text, font: noteFont)
                    let h = block.size.height + notePadV * 2
                    laidNotes.append(LNote(note: n, y: y, height: h, textSize: block.size))
                    y += h + noteSpacing
                case .loop(let label, let body), .opt(let label, let body):
                    let kind: GroupKind = { if case .loop = s { return .loop } else { return .opt } }()
                    let top = y
                    y += groupPaddingTop
                    walk(body)
                    y += groupPaddingBottom
                    laidGroups.append(LGroup(kind: kind, label: label, sectionLabels: [], top: top, bottom: y,
                                              dividerYs: []))
                case .alt(let branches):
                    let top = y
                    y += groupPaddingTop
                    var dividers: [CGFloat] = []
                    var labels: [String] = []
                    for (i, branch) in branches.enumerated() {
                        labels.append(branch.label)
                        if i > 0 { dividers.append(y); y += 4 }
                        walk(branch.body)
                    }
                    y += groupPaddingBottom
                    laidGroups.append(LGroup(kind: .alt, label: branches.first?.label ?? "alt",
                                              sectionLabels: Array(labels.dropFirst()),
                                              top: top, bottom: y, dividerYs: dividers))
                case .par(let branches):
                    let top = y
                    y += groupPaddingTop
                    var dividers: [CGFloat] = []
                    var labels: [String] = []
                    for (i, branch) in branches.enumerated() {
                        labels.append(branch.label)
                        if i > 0 { dividers.append(y); y += 4 }
                        walk(branch.body)
                    }
                    y += groupPaddingBottom
                    laidGroups.append(LGroup(kind: .par, label: branches.first?.label ?? "par",
                                              sectionLabels: Array(labels.dropFirst()),
                                              top: top, bottom: y, dividerYs: dividers))
                }
            }
        }
        walk(ast.statements)

        // Close any still-open activations.
        for (id, stack) in activeBars {
            for start in stack {
                laidActivations.append(LActivation(actorID: id, startY: start, endY: y))
            }
        }

        // Step 5: figure out canvas size.
        let footerTop = y + headerPaddingV
        let footerBottom = footerTop + actorHeaderHeight()
        let rightEdge = (ast.actors.last.flatMap { x[$0.id] } ?? 0) + (ast.actors.last.flatMap { actorWidth[$0.id] } ?? 0) / 2 + outerMargin

        // Also extend right for notes / groups that overflow.
        var maxRight = rightEdge
        for n in laidNotes {
            switch n.note.placement {
            case .rightOf(let id):
                if let cx = x[id] {
                    let right = cx + n.textSize.width + notePadH * 2 + 20
                    maxRight = max(maxRight, right)
                }
            case .leftOf:
                break  // already handled with leftEdgeMargin
            case .over(let ids):
                if let last = ids.last, let cx = x[last] {
                    let right = cx + n.textSize.width / 2 + notePadH + 8
                    maxRight = max(maxRight, right)
                }
            }
        }
        let canvasW = maxRight + outerMargin
        let canvasH = footerBottom + outerMargin

        // Step 6: emit elements.
        var elements: [MermaidElement] = []
        elements.reserveCapacity(64)

        // 6.0: backgrounds for group frames (under everything).
        for group in laidGroups {
            let leftX = leftBoundary(actorIDs: Array(x.keys), x: x, actorWidth: actorWidth) - 8
            let rightX = rightBoundary(actorIDs: Array(x.keys), x: x, actorWidth: actorWidth) + 8
            let frame = CGRect(x: leftX, y: group.top,
                               width: rightX - leftX, height: group.bottom - group.top)
            elements.append(.rect(frame, cornerRadius: 0,
                                  style: ShapeStyle_(fill: nil, stroke: palette.signalColor,
                                                     strokeWidth: 1, dash: [2, 2])))
            // Group label box (top-left).
            let labelBlock = TextMeasure.layout(group.label, font: groupLabelFont)
            let labelWord: String = {
                switch group.kind { case .loop: return "loop"; case .opt: return "opt"; case .alt: return "alt"; case .par: return "par" }
            }()
            let labelBoxW = max(groupLabelBoxW, TextMeasure.layout(labelWord, font: groupLabelFont).size.width + 14)
            let labelBox = CGRect(x: leftX, y: group.top, width: labelBoxW, height: groupLabelBoxH)
            elements.append(.rect(labelBox, cornerRadius: 0,
                                  style: ShapeStyle_(fill: palette.labelBoxFill,
                                                     stroke: palette.labelBoxBorder,
                                                     strokeWidth: 1)))
            let labelBaseline = labelBox.midY + 4
            elements.append(.text(labelWord,
                                  origin: CGPoint(x: labelBox.midX, y: labelBaseline),
                                  font: groupLabelFont, color: palette.actorTextColor, anchor: .middle))
            // Branch label (right of the label box).
            if !group.label.isEmpty {
                elements.append(.text(group.label,
                                      origin: CGPoint(x: labelBox.maxX + 8, y: labelBaseline),
                                      font: groupTextFont, color: palette.signalTextColor, anchor: .start))
            }
            _ = labelBlock
            // Branch dividers + their labels.
            for (i, dy) in group.dividerYs.enumerated() {
                elements.append(.path({
                    let p = CGMutablePath()
                    p.move(to: CGPoint(x: leftX, y: dy))
                    p.addLine(to: CGPoint(x: rightX, y: dy))
                    return p
                }(), style: ShapeStyle_(fill: nil, stroke: palette.signalColor,
                                        strokeWidth: 1, dash: [2, 2])))
                if i < group.sectionLabels.count {
                    elements.append(.text(group.sectionLabels[i],
                                          origin: CGPoint(x: leftX + 8, y: dy + 14),
                                          font: groupTextFont, color: palette.signalTextColor, anchor: .start))
                }
            }
        }

        // 6.1: lifelines.
        for actor in ast.actors {
            guard let cx = x[actor.id] else { continue }
            let path = CGMutablePath()
            path.move(to: CGPoint(x: cx, y: outerMargin + actorHeaderHeight()))
            path.addLine(to: CGPoint(x: cx, y: footerTop))
            elements.append(.path(path, style: ShapeStyle_(fill: nil, stroke: palette.lifelineColor,
                                                          strokeWidth: 1, dash: [4, 3])))
        }

        // 6.2: activations.
        for act in laidActivations {
            guard let cx = x[act.actorID] else { continue }
            let rect = CGRect(x: cx - activationWidth / 2,
                              y: act.startY,
                              width: activationWidth,
                              height: max(0.5, act.endY - act.startY))
            elements.append(.rect(rect, cornerRadius: 0,
                                  style: ShapeStyle_(fill: palette.activationFill,
                                                     stroke: palette.activationBorder,
                                                     strokeWidth: 1)))
        }

        // 6.3: notes.
        for n in laidNotes {
            let (rect, _) = noteRect(n: n, x: x, actorWidth: actorWidth)
            elements.append(.rect(rect, cornerRadius: 0,
                                  style: ShapeStyle_(fill: palette.noteFill,
                                                     stroke: palette.noteBorder,
                                                     strokeWidth: 1)))
            let block = TextMeasure.layout(n.note.text, font: noteFont)
            let firstBaselineY = rect.minY + notePadV + block.firstBaseline
            for (i, line) in block.lines.enumerated() {
                let by = firstBaselineY + block.lineHeight * CGFloat(i)
                elements.append(.text(line.string,
                                      origin: CGPoint(x: rect.midX, y: by),
                                      font: noteFont, color: palette.noteTextColor, anchor: .middle))
            }
        }

        // 6.4: messages.
        for m in laidMessages {
            elements.append(contentsOf: renderMessage(m, palette: palette, x: x))
        }

        // 6.5: actor headers (top) + footers (bottom).
        for actor in ast.actors {
            guard let cx = x[actor.id], let w = actorWidth[actor.id] else { continue }
            let headerRect = CGRect(x: cx - w / 2, y: outerMargin, width: w, height: actorHeaderHeight())
            let footerRect = CGRect(x: cx - w / 2, y: footerTop, width: w, height: actorHeaderHeight())
            for rect in [headerRect, footerRect] {
                elements.append(.rect(rect, cornerRadius: 6,
                                      style: ShapeStyle_(fill: palette.actorFill,
                                                         stroke: palette.actorBorder,
                                                         strokeWidth: 1)))
                let block = TextMeasure.layout(actor.label, font: actorFont)
                let firstBaselineY = rect.midY - block.size.height / 2 + block.firstBaseline
                for (i, line) in block.lines.enumerated() {
                    let by = firstBaselineY + block.lineHeight * CGFloat(i)
                    elements.append(.text(line.string,
                                          origin: CGPoint(x: rect.midX, y: by),
                                          font: actorFont, color: palette.actorTextColor, anchor: .middle))
                }
            }
        }

        return MermaidScene(size: CGSize(width: canvasW, height: canvasH),
                            backgroundColor: palette.background,
                            elements: elements)
    }

    // MARK: - Layout structs

    private struct LMessage {
        var message: SequenceMessage
        var y: CGFloat
        var number: Int?
        var textHeight: CGFloat
        var isSelf: Bool
    }

    private struct LNote {
        var note: SequenceNote
        var y: CGFloat
        var height: CGFloat
        var textSize: CGSize
    }

    private struct LActivation {
        var actorID: String
        var startY: CGFloat
        var endY: CGFloat
    }

    private enum GroupKind { case loop, opt, alt, par }
    private struct LGroup {
        var kind: GroupKind
        var label: String
        var sectionLabels: [String]
        var top: CGFloat
        var bottom: CGFloat
        var dividerYs: [CGFloat]
    }

    // MARK: - Geometry helpers

    private static func actorHeaderHeight() -> CGFloat {
        let h = TextMeasure.layout("Mg", font: actorFont).size.height
        return h + actorHeaderPadV * 2
    }

    private static func leftBoundary(actorIDs: [String], x: [String: CGFloat], actorWidth: [String: CGFloat]) -> CGFloat {
        var minX: CGFloat = .infinity
        for id in actorIDs {
            if let cx = x[id], let w = actorWidth[id] {
                minX = min(minX, cx - w / 2)
            }
        }
        return minX.isFinite ? minX : 0
    }

    private static func rightBoundary(actorIDs: [String], x: [String: CGFloat], actorWidth: [String: CGFloat]) -> CGFloat {
        var maxX: CGFloat = -.infinity
        for id in actorIDs {
            if let cx = x[id], let w = actorWidth[id] {
                maxX = max(maxX, cx + w / 2)
            }
        }
        return maxX.isFinite ? maxX : 0
    }

    private static func noteRect(n: LNote, x: [String: CGFloat], actorWidth: [String: CGFloat]) -> (CGRect, CGPoint) {
        let w = n.textSize.width + notePadH * 2
        switch n.note.placement {
        case .leftOf(let id):
            guard let cx = x[id], let aw = actorWidth[id] else { return (.zero, .zero) }
            let r = CGRect(x: cx - aw / 2 - 12 - w, y: n.y, width: w, height: n.height)
            return (r, CGPoint(x: r.midX, y: r.midY))
        case .rightOf(let id):
            guard let cx = x[id], let aw = actorWidth[id] else { return (.zero, .zero) }
            let r = CGRect(x: cx + aw / 2 + 12, y: n.y, width: w, height: n.height)
            return (r, CGPoint(x: r.midX, y: r.midY))
        case .over(let ids):
            let xs = ids.compactMap { x[$0] }
            let leftCX = xs.min() ?? 0
            let rightCX = xs.max() ?? leftCX
            let centre = (leftCX + rightCX) / 2
            let span = max(w, rightCX - leftCX + 40)
            let r = CGRect(x: centre - span / 2, y: n.y, width: span, height: n.height)
            return (r, CGPoint(x: r.midX, y: r.midY))
        }
    }

    private static func renderMessage(_ m: LMessage, palette: ThemePalette,
                                      x: [String: CGFloat]) -> [MermaidElement] {
        var out: [MermaidElement] = []
        let dash: [CGFloat]? = m.message.arrow == .dashed ? [5, 4] : nil
        let style = ShapeStyle_(fill: nil, stroke: palette.signalColor, strokeWidth: 1, dash: dash)
        guard let fromX = x[m.message.fromID], let toX = x[m.message.toID] else { return out }
        let labelBlock = TextMeasure.layout(m.message.text, font: messageFont)

        if m.isSelf {
            // Self-message: arc to the right.
            let loopW: CGFloat = 40
            let topY = m.y + 12
            let botY = topY + 18
            let path = CGMutablePath()
            path.move(to: CGPoint(x: fromX, y: topY))
            path.addLine(to: CGPoint(x: fromX + loopW, y: topY))
            path.addLine(to: CGPoint(x: fromX + loopW, y: botY))
            path.addLine(to: CGPoint(x: fromX + 1, y: botY))
            out.append(.path(path, style: style))
            out.append(contentsOf: arrowHead(at: CGPoint(x: fromX, y: botY),
                                              from: CGPoint(x: fromX + loopW, y: botY),
                                              kind: m.message.head, palette: palette))
            // Label to the right of the loop.
            let firstBaseline = topY - 6
            let totalH = labelBlock.lineHeight * CGFloat(labelBlock.lines.count)
            let topBaseline = firstBaseline - totalH + labelBlock.firstBaseline
            for (i, line) in labelBlock.lines.enumerated() {
                out.append(.text(line.string,
                                 origin: CGPoint(x: fromX + 8, y: topBaseline + labelBlock.lineHeight * CGFloat(i)),
                                 font: messageFont, color: palette.signalTextColor, anchor: .start))
            }
            if let number = m.number {
                out.append(.text("\(number).",
                                 origin: CGPoint(x: fromX - 6, y: topY + 4),
                                 font: autonumberFont, color: palette.signalTextColor, anchor: .end))
            }
            return out
        }

        let arrowY = m.y + labelBlock.size.height + messageLabelGap
        let path = CGMutablePath()
        path.move(to: CGPoint(x: fromX, y: arrowY))
        path.addLine(to: CGPoint(x: toX, y: arrowY))
        out.append(.path(path, style: style))

        // Arrowhead at target end.
        out.append(contentsOf: arrowHead(at: CGPoint(x: toX, y: arrowY),
                                          from: CGPoint(x: fromX, y: arrowY),
                                          kind: m.message.head, palette: palette))

        // Centred label above the line.
        let labelX = (fromX + toX) / 2
        let firstBaselineY = m.y + labelBlock.firstBaseline
        for (i, line) in labelBlock.lines.enumerated() {
            let by = firstBaselineY + labelBlock.lineHeight * CGFloat(i)
            out.append(.text(line.string,
                             origin: CGPoint(x: labelX, y: by),
                             font: messageFont, color: palette.signalTextColor, anchor: .middle))
        }
        // Autonumber label.
        if let number = m.number {
            out.append(.text("\(number).",
                             origin: CGPoint(x: fromX + (toX > fromX ? 4 : -4),
                                             y: arrowY - 4),
                             font: autonumberFont, color: palette.signalTextColor,
                             anchor: toX > fromX ? .start : .end))
        }
        return out
    }

    private static func arrowHead(at tip: CGPoint, from: CGPoint, kind: SequenceArrowHead,
                                  palette: ThemePalette) -> [MermaidElement] {
        let dx = tip.x - from.x
        let len = max(abs(dx), 0.0001)
        let dir: CGFloat = dx >= 0 ? 1 : -1
        _ = len
        let size: CGFloat = 8
        switch kind {
        case .solid:
            let path = CGMutablePath()
            path.move(to: tip)
            path.addLine(to: CGPoint(x: tip.x - dir * size, y: tip.y - size / 2))
            path.addLine(to: CGPoint(x: tip.x - dir * size, y: tip.y + size / 2))
            path.closeSubpath()
            return [.path(path, style: ShapeStyle_(fill: palette.signalColor, stroke: palette.signalColor, strokeWidth: 1))]
        case .open, .async:
            let path = CGMutablePath()
            path.move(to: CGPoint(x: tip.x - dir * size, y: tip.y - size / 2))
            path.addLine(to: tip)
            path.addLine(to: CGPoint(x: tip.x - dir * size, y: tip.y + size / 2))
            return [.path(path, style: ShapeStyle_(fill: nil, stroke: palette.signalColor, strokeWidth: 1.5))]
        case .cross:
            let d: CGFloat = 5
            let path = CGMutablePath()
            path.move(to: CGPoint(x: tip.x - d, y: tip.y - d))
            path.addLine(to: CGPoint(x: tip.x + d, y: tip.y + d))
            path.move(to: CGPoint(x: tip.x - d, y: tip.y + d))
            path.addLine(to: CGPoint(x: tip.x + d, y: tip.y - d))
            return [.path(path, style: ShapeStyle_(fill: nil, stroke: palette.signalColor, strokeWidth: 1.5))]
        }
    }
}
