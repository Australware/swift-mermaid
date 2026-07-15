import XCTest
@testable import Mermaid

final class StateDiagramTests: XCTestCase {

    private func parse(_ src: String) throws -> StateDiagram {
        try StateParser.parse(src)
    }

    // MARK: - Parser

    func testHeaderRequired() {
        XCTAssertThrowsError(try parse("nope\nA --> B"))
        XCTAssertThrowsError(try parse(""))
    }

    func testBothHeaderVariants() throws {
        _ = try parse("stateDiagram\n  A --> B")
        _ = try parse("stateDiagram-v2\n  A --> B")
    }

    func testBasicTransitionsWithStartAndEnd() throws {
        let sd = try parse("""
        stateDiagram-v2
            [*] --> Still
            Still --> [*]
            Still --> Moving
            Moving --> Still
            Moving --> Crash : impact
            Crash --> [*]
        """)
        let ast = sd.ast
        XCTAssertEqual(ast.direction, .TB)
        XCTAssertEqual(ast.edges.count, 6)

        let start = try XCTUnwrap(ast.nodes["__start_"])
        XCTAssertEqual(start.shape, .stateStart)
        XCTAssertEqual(start.label, "")
        let end = try XCTUnwrap(ast.nodes["__end_"])
        XCTAssertEqual(end.shape, .stateEnd)

        XCTAssertEqual(ast.nodes["Still"]?.shape, .roundRect)
        XCTAssertEqual(ast.nodes["Still"]?.label, "Still")

        XCTAssertEqual(ast.edges[0].from, "__start_")
        XCTAssertEqual(ast.edges[0].to, "Still")
        XCTAssertEqual(ast.edges[0].arrowEnd, .arrow)
        XCTAssertEqual(ast.edges[4].label, "impact")
        XCTAssertEqual(ast.edges[5].to, "__end_")

        // Start and end markers are distinct, reused nodes.
        XCTAssertEqual(ast.nodeOrder.filter { $0.hasPrefix("__start_") }.count, 1)
        XCTAssertEqual(ast.nodeOrder.filter { $0.hasPrefix("__end_") }.count, 1)
    }

    func testDescriptions() throws {
        let sd = try parse("""
        stateDiagram-v2
            state "This is a state description" as s2
            s3 : line one
            s3 : line two
            s2 --> s3
        """)
        XCTAssertEqual(sd.ast.nodes["s2"]?.label, "This is a state description")
        XCTAssertEqual(sd.ast.nodes["s3"]?.label, "line one\nline two")
    }

    func testChoiceForkJoin() throws {
        let sd = try parse("""
        stateDiagram-v2
            state if_state <<choice>>
            state fork_state <<fork>>
            state join_state <<join>>
            [*] --> if_state
            if_state --> A : yes
            if_state --> B : no
        """)
        XCTAssertEqual(sd.ast.nodes["if_state"]?.shape, .stateChoice)
        XCTAssertEqual(sd.ast.nodes["if_state"]?.label, "")
        XCTAssertEqual(sd.ast.nodes["fork_state"]?.shape, .stateForkJoin)
        XCTAssertEqual(sd.ast.nodes["join_state"]?.shape, .stateForkJoin)
    }

    func testStereotypeOnPreexistingState() throws {
        let sd = try parse("""
        stateDiagram-v2
            A --> if_state
            state if_state <<choice>>
        """)
        XCTAssertEqual(sd.ast.nodes["if_state"]?.shape, .stateChoice)
        XCTAssertEqual(sd.ast.nodes["if_state"]?.label, "")
    }

    func testCompositeState() throws {
        let sd = try parse("""
        stateDiagram-v2
            [*] --> First
            state First {
                [*] --> Second
                Second --> [*]
            }
            First --> Done
        """)
        let ast = sd.ast
        let sg = try XCTUnwrap(ast.subgraphs["First"])
        XCTAssertNil(ast.nodes["First"], "composite must not remain a plain node")
        XCTAssertTrue(sg.nodeIDs.contains("Second"))
        XCTAssertTrue(sg.nodeIDs.contains("__start_First"))
        XCTAssertTrue(sg.nodeIDs.contains("__end_First"))

        // Edges touching the composite are redirected to a leaf inside it and remembered.
        let inbound = try XCTUnwrap(ast.edges.first { $0.from == "__start_" })
        XCTAssertNotEqual(inbound.to, "First")
        XCTAssertNotNil(sd.compositeEnds[StateEdgeKey(from: inbound.from, to: inbound.to)])
        let outbound = try XCTUnwrap(ast.edges.first { $0.to == "Done" })
        XCTAssertNotEqual(outbound.from, "First")
        XCTAssertEqual(sd.compositeEnds[StateEdgeKey(from: outbound.from, to: outbound.to)]?.fromComposite, "First")
    }

    func testNestedComposite() throws {
        let sd = try parse("""
        stateDiagram-v2
            state Outer {
                state Inner {
                    A --> B
                }
                B --> C
            }
        """)
        let outer = try XCTUnwrap(sd.ast.subgraphs["Outer"])
        let inner = try XCTUnwrap(sd.ast.subgraphs["Inner"])
        XCTAssertEqual(inner.parentID, "Outer")
        XCTAssertTrue(outer.childSubgraphIDs.contains("Inner"))
        XCTAssertEqual(sd.ast.nodes["A"]?.subgraphID, "Inner")
        XCTAssertEqual(sd.ast.nodes["C"]?.subgraphID, "Outer")
    }

    func testCompositeWithQuotedTitle() throws {
        let sd = try parse("""
        stateDiagram-v2
            state "The big picture" as Big {
                A --> B
            }
        """)
        XCTAssertEqual(sd.ast.subgraphs["Big"]?.title, "The big picture")
    }

    func testNotes() throws {
        let sd = try parse("""
        stateDiagram-v2
            Active --> Idle
            note right of Active : quick note
            note left of Idle
                long note
                second line
            end note
        """)
        let ast = sd.ast
        let notes = ast.nodeOrder.filter { ast.nodes[$0]?.shape == .note }
        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(ast.nodes[notes[0]]?.label, "quick note")
        XCTAssertEqual(ast.nodes[notes[1]]?.label, "long note\nsecond line")

        let invisible = ast.edges.filter { $0.kind == .invisible }
        XCTAssertEqual(invisible.count, 2)
        // right of → target before note; left of → note before target.
        XCTAssertEqual(invisible[0].from, "Active")
        XCTAssertEqual(invisible[1].to, "Idle")
    }

    func testDirectionStatement() throws {
        let sd = try parse("""
        stateDiagram-v2
            direction LR
            A --> B
        """)
        XCTAssertEqual(sd.ast.direction, .LR)
    }

    func testUnsupportedLinesSkipped() throws {
        let sd = try parse("""
        stateDiagram-v2
            classDef badBadEvent fill:#f00,color:white
            hide empty description
            accTitle: My title
            A --> B:::badBadEvent
            class B badBadEvent
        """)
        XCTAssertEqual(sd.ast.edges.count, 1)
        XCTAssertEqual(sd.ast.edges[0].to, "B")
        XCTAssertNotNil(sd.ast.nodes["B"])
    }

    func testConcurrencySeparatorSkipped() throws {
        let sd = try parse("""
        stateDiagram-v2
            state Active {
                A --> B
                --
                C --> D
            }
        """)
        let sg = try XCTUnwrap(sd.ast.subgraphs["Active"])
        XCTAssertEqual(Set(sg.nodeIDs), ["A", "B", "C", "D"])
    }

    func testSelfTransition() throws {
        let sd = try parse("""
        stateDiagram-v2
            A --> A : retry
        """)
        XCTAssertEqual(sd.ast.edges.count, 1)
        XCTAssertEqual(sd.ast.edges[0].from, "A")
        XCTAssertEqual(sd.ast.edges[0].to, "A")
    }

    // MARK: - End-to-end render

    private let fullExample = """
    stateDiagram-v2
        [*] --> Still
        Still --> [*]
        Still --> Moving
        Moving --> Still
        Moving --> Crash : impact
        Crash --> [*]
        state Moving {
            [*] --> Slow
            Slow --> Fast : accelerate
            Fast --> Slow : brake
        }
        note right of Crash : ouch
    """

    func testRenderSmokeBothBackendsAndThemes() throws {
        for layout in [Mermaid.LayoutBackend.builtin, .dagre] {
            for theme in [MermaidTheme.default, .dark] {
                let scene = try Mermaid.render(fullExample, theme: theme, layout: layout)
                XCTAssertGreaterThan(scene.size.width, 0)
                XCTAssertGreaterThan(scene.size.height, 0)
                XCTAssertFalse(scene.elements.isEmpty)
                let svg = scene.svgString()
                XCTAssertTrue(svg.contains("<svg"))
            }
        }
    }

    func testRenderPlainStateDiagramHeader() throws {
        let scene = try Mermaid.render("stateDiagram\n    [*] --> A\n    A --> [*]")
        XCTAssertGreaterThan(scene.size.width, 0)
    }

    func testCompositeEdgeClipping() throws {
        let sd = try parse("""
        stateDiagram-v2
            [*] --> Comp
            state Comp {
                A --> B
            }
            Comp --> Done
        """)
        let positioned = try FlowchartLayoutDagre.layout(sd.ast)
        let clipped = StatePostLayout.clipCompositeEdges(positioned, diagram: sd)
        let compRect = try XCTUnwrap(clipped.subgraphs.first { $0.id == "Comp" }?.rect)

        // The inbound edge must stop at (not inside) the composite's border.
        let inbound = try XCTUnwrap(clipped.edges.first { $0.from == "__start_" })
        let tail = try XCTUnwrap(inbound.points.last)
        XCTAssertFalse(compRect.insetBy(dx: 1, dy: 1).contains(tail),
                       "edge endpoint \(tail) should sit on the composite border, not inside \(compRect)")
    }
}
