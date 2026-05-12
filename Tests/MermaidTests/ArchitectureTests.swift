import XCTest
@testable import Mermaid

final class ArchitectureTests: XCTestCase {

    private func parse(_ src: String) throws -> ArchitectureAST {
        try ArchitectureParser.parse(src)
    }

    func testBasicParse() throws {
        let ast = try parse("""
        architecture-beta
            group api(cloud)[API]
            service db(database)[Database] in api
            service server(server)[Server] in api
            db:L -- R:server
        """)
        XCTAssertEqual(ast.groupOrder, ["api"])
        XCTAssertEqual(ast.serviceOrder, ["db", "server"])
        XCTAssertEqual(ast.services["db"]?.icon, .database)
        XCTAssertEqual(ast.services["db"]?.title, "Database")
        XCTAssertEqual(ast.services["db"]?.groupID, "api")
        XCTAssertEqual(ast.services["server"]?.icon, .server)
        XCTAssertEqual(ast.groups["api"]?.icon, .cloud)
        XCTAssertEqual(ast.edges.count, 1)
        XCTAssertEqual(ast.edges[0].lhs.id, "db")
        XCTAssertEqual(ast.edges[0].lhs.side, .L)
        XCTAssertEqual(ast.edges[0].rhs.id, "server")
        XCTAssertEqual(ast.edges[0].rhs.side, .R)
        XCTAssertFalse(ast.edges[0].arrowLhs)
        XCTAssertFalse(ast.edges[0].arrowRhs)
    }

    func testArrowsAndGroupMarkers() throws {
        let ast = try parse("""
        architecture-beta
            service a(server)[A]
            service b(server)[B] in g
            group g(cloud)[G]
            a:R --> L:b
            b{group}:T <-- B:a
        """)
        XCTAssertEqual(ast.edges.count, 2)
        XCTAssertTrue(ast.edges[0].arrowRhs)
        XCTAssertFalse(ast.edges[0].arrowLhs)
        XCTAssertFalse(ast.edges[0].rhs.viaGroup)
        XCTAssertTrue(ast.edges[1].lhs.viaGroup)
        XCTAssertTrue(ast.edges[1].arrowLhs)
        XCTAssertFalse(ast.edges[1].arrowRhs)
    }

    func testJunctions() throws {
        let ast = try parse("""
        architecture-beta
            service a(disk)[A]
            junction jc
            service b(disk)[B]
            a:R -- L:jc
            jc:R -- L:b
        """)
        XCTAssertEqual(ast.services["jc"]?.isJunction, true)
        XCTAssertEqual(ast.edges.count, 2)
    }

    func testCustomIconBecomesGeneric() throws {
        let ast = try parse("""
        architecture-beta
            service x("aws:lambda")[Lambda]
        """)
        XCTAssertEqual(ast.services["x"]?.icon, .generic)
    }

    func testUnknownLinesSkipped() throws {
        let ast = try parse("""
        architecture-beta
            service a(server)[A]
            this is not valid syntax
            service b(server)[B]
            a:R -- L:b
        """)
        XCTAssertEqual(ast.serviceOrder, ["a", "b"])
        XCTAssertEqual(ast.edges.count, 1)
    }

    func testRendersThroughUmbrella() throws {
        let scene = try Mermaid.render("""
        architecture-beta
            group api(cloud)[API]
            service db(database)[Database] in api
            service disk1(disk)[Storage] in api
            service server(server)[Server] in api
            service gateway(internet)[Gateway]
            db:L -- R:server
            disk1:T -- B:server
            server:T -- B:db
            gateway:R --> L:server
        """)
        XCTAssertGreaterThan(scene.size.width, 0)
        XCTAssertGreaterThan(scene.size.height, 0)
        XCTAssertGreaterThan(scene.elements.count, 8)
        // Determinism.
        let again = try Mermaid.render("""
        architecture-beta
            group api(cloud)[API]
            service db(database)[Database] in api
            service disk1(disk)[Storage] in api
            service server(server)[Server] in api
            service gateway(internet)[Gateway]
            db:L -- R:server
            disk1:T -- B:server
            server:T -- B:db
            gateway:R --> L:server
        """)
        XCTAssertEqual(scene.svgString(), again.svgString())
    }

    func testEmptyDiagramThrows() {
        XCTAssertThrowsError(try Mermaid.render("architecture-beta"))
    }

    func testWrongHeaderThrows() {
        XCTAssertThrowsError(try ArchitectureParser.parse("flowchart TD\nA --> B"))
    }
}
