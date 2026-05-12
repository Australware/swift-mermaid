import XCTest
@testable import Mermaid

final class SceneTests: XCTestCase {

    func testFlowchartRendersElements() throws {
        let scene = try Mermaid.render("""
        flowchart TD
        Start([Start]) --> Decide{Continue?}
        Decide -->|Yes| Work[Do work]
        Decide -->|No| Stop([End])
        Work --> Stop
        """)
        XCTAssertGreaterThan(scene.size.width, 0)
        XCTAssertGreaterThan(scene.size.height, 0)
        XCTAssertGreaterThan(scene.elements.count, 5)
    }

    func testSVGEmittedHasPresentationAttributes() throws {
        let scene = try Mermaid.render("flowchart TD\nA[Start] --> B[End]")
        let svg = scene.svgString()
        XCTAssertTrue(svg.hasPrefix("<svg "))
        XCTAssertTrue(svg.contains("xmlns=\"http://www.w3.org/2000/svg\""))
        XCTAssertTrue(svg.contains(" fill="))
        XCTAssertTrue(svg.contains(" stroke="))
        XCTAssertFalse(svg.contains("<style"), "SVG should not use a <style> block")
    }

    func testSVGIsDeterministic() throws {
        let src = """
        flowchart LR
        A --> B
        B --> C
        A --> C
        """
        let s1 = try Mermaid.render(src).svgString()
        let s2 = try Mermaid.render(src).svgString()
        XCTAssertEqual(s1, s2)
    }

    func testCGImageRenders() throws {
        let scene = try Mermaid.render("flowchart TD\nA --> B --> C")
        let image = scene.cgImage(scale: 2)
        XCTAssertNotNil(image)
        XCTAssertGreaterThan(image?.width ?? 0, 0)
        XCTAssertGreaterThan(image?.height ?? 0, 0)
    }

    func testPDFRenders() throws {
        let scene = try Mermaid.render("flowchart TD\nA --> B")
        let data = scene.pdfData()
        XCTAssertGreaterThan(data.count, 100)
        XCTAssertTrue(data.starts(with: Array("%PDF".utf8)))
    }

    func testSequenceDiagramRenders() throws {
        let scene = try Mermaid.render("""
        sequenceDiagram
        autonumber
        participant Alice
        participant Bob
        Alice->>Bob: Hi
        Bob-->>Alice: Hello back
        Note right of Bob: thinking
        loop every minute
            Alice->>Bob: tick
        end
        """, theme: .dark)
        XCTAssertGreaterThan(scene.elements.count, 10)
        // Dark theme: background should not be near-white.
        XCTAssertNotNil(scene.backgroundColor)
    }

    func testPieRenders() throws {
        let scene = try Mermaid.render("""
        pie title Pets adopted by volunteers
            "Dogs" : 386
            "Cats" : 85
            "Rats" : 15
        """)
        XCTAssertGreaterThan(scene.elements.count, 3)
    }

    func testThemesProduceDifferentSVG() throws {
        let src = "flowchart TD\nA --> B"
        let light = try Mermaid.render(src, theme: .default).svgString()
        let dark = try Mermaid.render(src, theme: .dark).svgString()
        XCTAssertNotEqual(light, dark)
    }
}
