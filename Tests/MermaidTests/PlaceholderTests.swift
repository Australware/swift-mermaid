import XCTest
@testable import Mermaid

// Smoke check that the package builds. Real coverage lives in the sibling files.
final class PlaceholderTests: XCTestCase {
    func testPackageBuilds() {
        XCTAssertEqual(MermaidTheme.allCases.count, 2)
    }
}
