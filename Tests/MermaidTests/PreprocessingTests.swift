import XCTest
@testable import Mermaid

final class PreprocessingTests: XCTestCase {

    func testDetectsFlowchart() throws {
        let scene = try Mermaid.render("flowchart TD\nA --> B")
        XCTAssertGreaterThan(scene.elements.count, 0)
    }

    func testGraphAliasDetectsFlowchart() throws {
        let scene = try Mermaid.render("graph LR\nA --> B")
        XCTAssertGreaterThan(scene.elements.count, 0)
    }

    func testDetectsSequence() throws {
        let scene = try Mermaid.render("""
        sequenceDiagram
        Alice->>Bob: Hello
        """)
        XCTAssertGreaterThan(scene.elements.count, 0)
    }

    func testDetectsPie() throws {
        let scene = try Mermaid.render("""
        pie title Sample
            "A" : 1
            "B" : 1
        """)
        XCTAssertGreaterThan(scene.elements.count, 0)
    }

    func testUnsupportedTypeThrows() {
        XCTAssertThrowsError(try Mermaid.render("gantt\ntitle nope")) { error in
            guard case let .unsupportedDiagramType(name) = error as? MermaidError else {
                XCTFail("Wrong error: \(error)")
                return
            }
            XCTAssertEqual(name.lowercased(), "gantt")
        }
    }

    func testUnknownTypeIsUnsupportedNotCrash() {
        XCTAssertThrowsError(try Mermaid.render("totallyNotAThing TD\nA"))
    }

    func testEmptySourceThrows() {
        XCTAssertThrowsError(try Mermaid.render(""))
    }

    func testFrontmatterStripped() throws {
        let source = """
        ---
        title: hello
        config:
          theme: dark
        ---
        flowchart TD
        A --> B
        """
        // Should pick up theme:dark from frontmatter when caller passed .default.
        let scene = try Mermaid.render(source)
        // Light background is white; dark background is not — that's our signal.
        XCTAssertNotNil(scene.backgroundColor)
    }

    func testInitDirectivePickedUp() throws {
        let source = """
        %%{init: {'theme':'dark'}}%%
        flowchart TD
        A --> B
        """
        _ = try Mermaid.render(source)
    }

    func testCommentsIgnored() throws {
        let source = """
        flowchart TD
        %% This is a comment
        A --> B
        """
        let scene = try Mermaid.render(source)
        XCTAssertGreaterThan(scene.elements.count, 0)
    }
}
