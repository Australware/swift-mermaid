import CoreGraphics
import Foundation

enum SequenceActorKind {
    case participant
    case actor          // person icon
}

struct SequenceActor {
    let id: String
    let label: String
    let kind: SequenceActorKind
}

enum SequenceArrow {
    case solid          // -> / ->>
    case dashed         // --> / -->>
}

enum SequenceArrowHead {
    case open           // ->
    case solid          // ->>
    case cross          // -x
    case async          // -)
}

struct SequenceMessage {
    let fromID: String
    let toID: String
    let text: String
    let arrow: SequenceArrow
    let head: SequenceArrowHead
    /// `+` shorthand: activate target after sending.
    let activates: Bool
    /// `-` shorthand: deactivate sender after sending.
    let deactivates: Bool
}

enum SequenceNotePlacement {
    case leftOf(String)
    case rightOf(String)
    case over([String])
}

struct SequenceNote {
    let text: String
    let placement: SequenceNotePlacement
}

indirect enum SequenceStatement {
    case message(SequenceMessage)
    case activate(String)
    case deactivate(String)
    case note(SequenceNote)
    case loop(label: String, body: [SequenceStatement])
    case opt(label: String, body: [SequenceStatement])
    case alt(branches: [(label: String, body: [SequenceStatement])])
    case par(branches: [(label: String, body: [SequenceStatement])])
}

struct SequenceAST {
    var actors: [SequenceActor]
    var actorIndex: [String: Int]
    var statements: [SequenceStatement]
    var autonumber: Bool
}
