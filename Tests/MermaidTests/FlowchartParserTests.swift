import XCTest
@testable import Mermaid

final class FlowchartParserTests: XCTestCase {

    private func parse(_ src: String) throws -> FlowchartAST {
        try FlowchartParser.parse(src)
    }

    func testBasicGraph() throws {
        let ast = try parse("flowchart TD\nA --> B")
        XCTAssertEqual(ast.direction, .TB)
        XCTAssertEqual(ast.nodeOrder, ["A", "B"])
        XCTAssertEqual(ast.edges.count, 1)
        XCTAssertEqual(ast.edges[0].from, "A")
        XCTAssertEqual(ast.edges[0].to, "B")
        XCTAssertEqual(ast.edges[0].kind, .solid)
        XCTAssertEqual(ast.edges[0].arrowEnd, .arrow)
    }

    func testDirection() throws {
        let ast = try parse("graph LR\nA --> B")
        XCTAssertEqual(ast.direction, .LR)
    }

    func testShapes() throws {
        let ast = try parse("""
        flowchart TD
        A[rect]
        B(round)
        C([stadium])
        D{rhombus}
        E{{hex}}
        F((circle))
        G[(cyl)]
        """)
        XCTAssertEqual(ast.nodes["A"]?.shape, .rect)
        XCTAssertEqual(ast.nodes["A"]?.label, "rect")
        XCTAssertEqual(ast.nodes["B"]?.shape, .roundRect)
        XCTAssertEqual(ast.nodes["C"]?.shape, .stadium)
        XCTAssertEqual(ast.nodes["D"]?.shape, .rhombus)
        XCTAssertEqual(ast.nodes["E"]?.shape, .hexagon)
        XCTAssertEqual(ast.nodes["F"]?.shape, .circle)
        XCTAssertEqual(ast.nodes["G"]?.shape, .cylinder)
    }

    func testChain() throws {
        let ast = try parse("flowchart TD\nA --> B --> C")
        XCTAssertEqual(ast.edges.count, 2)
        XCTAssertEqual(ast.edges.map(\.from), ["A", "B"])
        XCTAssertEqual(ast.edges.map(\.to), ["B", "C"])
    }

    func testFanOut() throws {
        let ast = try parse("flowchart TD\nA & B --> C & D")
        // 4 edges: A→C, A→D, B→C, B→D.
        XCTAssertEqual(ast.edges.count, 4)
        let pairs = Set(ast.edges.map { "\($0.from)->\($0.to)" })
        XCTAssertEqual(pairs, ["A->C", "A->D", "B->C", "B->D"])
    }

    func testEdgeKindsAndLengths() throws {
        let ast = try parse("""
        flowchart TD
        A --> B
        B -.-> C
        C ==> D
        D --- E
        E ---> F
        """)
        XCTAssertEqual(ast.edges.count, 5)
        XCTAssertEqual(ast.edges[0].kind, .solid)
        XCTAssertEqual(ast.edges[0].arrowEnd, .arrow)
        XCTAssertEqual(ast.edges[0].length, 1)
        XCTAssertEqual(ast.edges[1].kind, .dotted)
        XCTAssertEqual(ast.edges[2].kind, .thick)
        XCTAssertEqual(ast.edges[3].kind, .solid)
        XCTAssertEqual(ast.edges[3].arrowEnd, .none)
        XCTAssertEqual(ast.edges[4].length, 2)
    }

    func testEdgeLabels() throws {
        let ast = try parse("""
        flowchart LR
        A -->|click| B
        B -- text --> C
        """)
        XCTAssertEqual(ast.edges.count, 2)
        XCTAssertEqual(ast.edges[0].label, "click")
        XCTAssertEqual(ast.edges[1].label, "text")
    }

    func testSubgraph() throws {
        let ast = try parse("""
        flowchart TD
        subgraph one
            A --> B
        end
        B --> C
        """)
        XCTAssertEqual(ast.subgraphs.count, 1)
        let sg = ast.subgraphs["one"]
        XCTAssertNotNil(sg)
        XCTAssertEqual(Set(sg?.nodeIDs ?? []), ["A", "B"])
        XCTAssertEqual(ast.nodes["A"]?.subgraphID, "one")
        XCTAssertNil(ast.nodes["C"]?.subgraphID)
    }

    func testParseSkipsStyleDirectives() throws {
        // classDef / class / style / linkStyle / click — should all parse-and-skip.
        let ast = try parse("""
        flowchart TD
        A --> B
        classDef important fill:#f9f
        class A important
        style B fill:#ff0
        linkStyle 0 stroke:#f00
        click A "https://example.com"
        """)
        XCTAssertEqual(ast.edges.count, 1)
        XCTAssertEqual(ast.nodeOrder.count, 2)
    }

    func testBidirectionalEdge() throws {
        let ast = try parse("flowchart TD\nA <--> B")
        XCTAssertEqual(ast.edges.count, 1)
        XCTAssertEqual(ast.edges[0].arrowStart, .arrow)
        XCTAssertEqual(ast.edges[0].arrowEnd, .arrow)
    }

    func testCircleAndCrossEndEdges() throws {
        let ast = try parse("""
        flowchart TD
        A --o B
        A --x C
        """)
        XCTAssertEqual(ast.edges[0].arrowEnd, .circle)
        XCTAssertEqual(ast.edges[1].arrowEnd, .cross)
    }
}
