import XCTest
@testable import Mermaid

final class ERDiagramTests: XCTestCase {

    private func parse(_ src: String) throws -> ERDiagramAST {
        try ERParser.parse(src)
    }

    // MARK: - Parser

    func testHeaderRequired() {
        XCTAssertThrowsError(try parse("nope\nA ||--o{ B : has"))
    }

    func testBasicRelationship() throws {
        let ast = try parse("""
        erDiagram
            CUSTOMER ||--o{ ORDER : places
        """)
        XCTAssertEqual(ast.entityOrder, ["CUSTOMER", "ORDER"])
        let rel = try XCTUnwrap(ast.relationships.first)
        XCTAssertEqual(rel.lhsID, "CUSTOMER")
        XCTAssertEqual(rel.rhsID, "ORDER")
        XCTAssertEqual(rel.lhsCardinality, .exactlyOne)
        XCTAssertEqual(rel.rhsCardinality, .zeroOrMore)
        XCTAssertEqual(rel.lineStyle, .identifying)
        XCTAssertEqual(rel.label, "places")
    }

    func testAllCardinalityTokens() throws {
        let ast = try parse("""
        erDiagram
            A |o--o| B : a
            C ||--|| D : b
            E }o--o{ F : c
            G }|--|{ H : d
            I }|..|{ J : e
        """)
        XCTAssertEqual(ast.relationships.count, 5)
        XCTAssertEqual(ast.relationships[0].lhsCardinality, .zeroOrOne)
        XCTAssertEqual(ast.relationships[0].rhsCardinality, .zeroOrOne)
        XCTAssertEqual(ast.relationships[1].lhsCardinality, .exactlyOne)
        XCTAssertEqual(ast.relationships[1].rhsCardinality, .exactlyOne)
        XCTAssertEqual(ast.relationships[2].lhsCardinality, .zeroOrMore)
        XCTAssertEqual(ast.relationships[2].rhsCardinality, .zeroOrMore)
        XCTAssertEqual(ast.relationships[3].lhsCardinality, .oneOrMore)
        XCTAssertEqual(ast.relationships[3].rhsCardinality, .oneOrMore)
        XCTAssertEqual(ast.relationships[4].lineStyle, .nonIdentifying)
    }

    func testHyphenatedEntityNamesAreNotMistakenForTheConnector() throws {
        let ast = try parse("""
        erDiagram
            ORDER ||--|{ LINE-ITEM : contains
        """)
        XCTAssertEqual(ast.entityOrder, ["ORDER", "LINE-ITEM"])
        XCTAssertEqual(ast.relationships.first?.rhsID, "LINE-ITEM")
    }

    func testAttributeBlock() throws {
        let ast = try parse("""
        erDiagram
            CUSTOMER {
                string name
                string custNumber PK
                int(11) sector FK, UK "the sector code"
            }
        """)
        let customer = try XCTUnwrap(ast.entities["CUSTOMER"])
        XCTAssertEqual(customer.attributes.count, 3)
        XCTAssertEqual(customer.attributes[0].type, "string")
        XCTAssertEqual(customer.attributes[0].name, "name")
        XCTAssertTrue(customer.attributes[0].keys.isEmpty)
        XCTAssertNil(customer.attributes[0].comment)
        XCTAssertEqual(customer.attributes[1].keys, ["PK"])
        XCTAssertEqual(customer.attributes[2].type, "int(11)")
        XCTAssertEqual(customer.attributes[2].keys, ["FK", "UK"])
        XCTAssertEqual(customer.attributes[2].comment, "the sector code")
    }

    func testAliasesAndQuotedNames() throws {
        let ast = try parse("""
        erDiagram
            p[Person] {
                string name
            }
            "DELIVERY ADDRESS" ||--o{ p : uses
        """)
        XCTAssertEqual(ast.entities["p"]?.name, "Person")
        XCTAssertNotNil(ast.entities["DELIVERY ADDRESS"])
        XCTAssertEqual(ast.relationships.first?.lhsID, "DELIVERY ADDRESS")
    }

    func testBareEntityAndDirection() throws {
        let ast = try parse("""
        erDiagram
            direction LR
            STANDALONE
        """)
        XCTAssertEqual(ast.direction, .LR)
        XCTAssertEqual(ast.entityOrder, ["STANDALONE"])
        XCTAssertTrue(ast.relationships.isEmpty)
    }

    func testRecursiveRelationship() throws {
        let ast = try parse("erDiagram\nEMPLOYEE ||--o{ EMPLOYEE : manages")
        XCTAssertEqual(ast.entityOrder, ["EMPLOYEE"])
        XCTAssertEqual(ast.relationships.count, 1)
    }

    // MARK: - Metrics

    func testMetricsAddColumnsOnlyWhenUsed() {
        let bare = EREntity(id: "A", name: "A", attributes: [
            ERAttribute(type: "string", name: "x", keys: [], comment: nil)
        ])
        XCTAssertEqual(EREntityMetrics.measure(bare).columns, [.type, .name])

        let full = EREntity(id: "A", name: "A", attributes: [
            ERAttribute(type: "string", name: "x", keys: ["PK"], comment: "c")
        ])
        XCTAssertEqual(EREntityMetrics.measure(full).columns, [.type, .name, .keys, .comment])
    }

    func testColumnWidthsFillTheBox() {
        let entity = EREntity(id: "A", name: "A very wide entity name indeed", attributes: [
            ERAttribute(type: "int", name: "id", keys: [], comment: nil)
        ])
        let m = EREntityMetrics.measure(entity)
        XCTAssertEqual(m.columnWidths.reduce(0, +), m.size.width, accuracy: 0.01)
    }

    // MARK: - Scene

    func testRendersScene() throws {
        let scene = try Mermaid.render("""
        erDiagram
            CUSTOMER ||--o{ ORDER : places
            ORDER ||--|{ LINE-ITEM : contains
            CUSTOMER {
                string name
                string custNumber PK
            }
        """)
        XCTAssertGreaterThan(scene.size.width, 0)
        XCTAssertGreaterThan(scene.size.height, 0)
        XCTAssertGreaterThan(scene.elements.count, 10)
    }

    func testSVGIsDeterministic() throws {
        let src = "erDiagram\nA ||--o{ B : has\nB }o--|| C : of"
        XCTAssertEqual(try Mermaid.render(src).svgString(), try Mermaid.render(src).svgString())
    }

    func testDegenerateSourcesRenderWithoutCrashing() throws {
        for src in ["erDiagram",
                    "erDiagram\nA",
                    "erDiagram\nA {\n}",
                    "erDiagram\nA ||--|| A : self",
                    "erDiagram\nA[\"\"] ||--o{ B : \"\""] {
            let scene = try Mermaid.render(src)
            XCTAssertGreaterThan(scene.size.width, 0, src)
            XCTAssertNotNil(scene.cgImage(scale: 1), src)
        }
    }

    func testSelfLoopLabelStaysInsideTheCanvas() {
        let laid = ERLayout.layout(try! ERParser.parse("erDiagram\nEMPLOYEE ||--o{ EMPLOYEE : manages"))
        let rel = laid.relationships[0]
        let box = ERLayout.labelRect(rel.label!, at: rel.labelPoint!)
        XCTAssertLessThanOrEqual(box.maxX, laid.size.width)
        XCTAssertLessThanOrEqual(box.maxY, laid.size.height)
        XCTAssertGreaterThanOrEqual(box.minX, 0)
        XCTAssertGreaterThanOrEqual(box.minY, 0)
    }
}
