import XCTest
@testable import Mermaid

final class JourneyTests: XCTestCase {

    private func parse(_ src: String) throws -> JourneyAST {
        try JourneyParser.parse(src)
    }

    // MARK: - Parser

    func testHeaderRequired() {
        XCTAssertThrowsError(try parse("nope\ntitle x"))
    }

    func testTitleSectionsAndTasks() throws {
        let ast = try parse("""
        journey
            title My working day
            section Go to work
              Make tea: 5: Me
              Go upstairs: 3: Me
              Do work: 1: Me, Cat
            section Go home
              Sit down: 5: Me
        """)
        XCTAssertEqual(ast.title, "My working day")
        XCTAssertEqual(ast.sections.map(\.name), ["Go to work", "Go home"])
        XCTAssertEqual(ast.sections[0].tasks.map(\.name), ["Make tea", "Go upstairs", "Do work"])
        XCTAssertEqual(ast.sections[0].tasks.map(\.score), [5, 3, 1])
        XCTAssertEqual(ast.sections[0].tasks[2].actors, ["Me", "Cat"])
        XCTAssertEqual(ast.sections[1].tasks.count, 1)
    }

    func testActorsAreDeduplicatedInFirstAppearanceOrder() throws {
        let ast = try parse("""
        journey
            section S
              A: 5: Cat, Me
              B: 5: Me, Dog
        """)
        XCTAssertEqual(ast.actors, ["Cat", "Me", "Dog"])
    }

    func testOptionalScoreAndActors() throws {
        let ast = try parse("""
        journey
            section S
              No actors: 4
              No score: : Me
        """)
        XCTAssertEqual(ast.sections[0].tasks[0].score, 4)
        XCTAssertTrue(ast.sections[0].tasks[0].actors.isEmpty)
        XCTAssertNil(ast.sections[0].tasks[1].score)
        XCTAssertEqual(ast.sections[0].tasks[1].actors, ["Me"])
    }

    func testTasksBeforeAnySectionGetAnUnnamedOne() throws {
        let ast = try parse("""
        journey
            title T
            Lone task: 3: Me
        """)
        XCTAssertEqual(ast.sections.count, 1)
        XCTAssertEqual(ast.sections[0].name, "")
        XCTAssertEqual(ast.sections[0].tasks.map(\.name), ["Lone task"])
    }

    func testAccessibilityStatementsSkipped() throws {
        let ast = try parse("""
        journey
            accTitle: an accessible title
            accDescr: a description
            section S
              A: 5: Me
        """)
        XCTAssertNil(ast.title)
        XCTAssertEqual(ast.sections.count, 1)
        XCTAssertEqual(ast.sections[0].tasks.count, 1)
    }

    // MARK: - Scene

    func testRendersScene() throws {
        let scene = try Mermaid.render("""
        journey
            title My working day
            section Go to work
              Make tea: 5: Me
              Do work: 1: Me, Cat
            section Go home
              Sit down: 5: Me
        """)
        XCTAssertGreaterThan(scene.size.width, 0)
        XCTAssertGreaterThan(scene.size.height, 0)
        XCTAssertGreaterThan(scene.elements.count, 10)
    }

    func testEmptyJourneyStillRenders() throws {
        let scene = try Mermaid.render("journey\ntitle Nothing here")
        XCTAssertGreaterThan(scene.size.width, 0)
        XCTAssertGreaterThan(scene.size.height, 0)
    }

    func testSVGIsDeterministic() throws {
        let src = "journey\ntitle T\nsection S\n  A: 5: Me\n  B: 2: You"
        XCTAssertEqual(try Mermaid.render(src).svgString(), try Mermaid.render(src).svgString())
    }

    func testDegenerateSourcesRenderWithoutCrashing() throws {
        for src in ["journey",
                    "journey\nsection Empty",
                    "journey\nsection S\n  : 5: Me"] {
            let scene = try Mermaid.render(src)
            XCTAssertGreaterThan(scene.size.width, 0, src)
            XCTAssertNotNil(scene.cgImage(scale: 1), src)
        }
    }
}
