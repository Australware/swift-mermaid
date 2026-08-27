import XCTest
@testable import Mermaid

final class GitGraphTests: XCTestCase {

    private func parse(_ src: String) throws -> GitGraphAST {
        try GitGraphParser.parse(src)
    }

    // MARK: - Parser

    func testHeaderRequired() {
        XCTAssertThrowsError(try parse("nope\ncommit"))
    }

    func testHeaderVariantsAndDirection() throws {
        XCTAssertEqual(try parse("gitGraph\ncommit").direction, .LR)
        XCTAssertEqual(try parse("gitGraph:\ncommit").direction, .LR)
        XCTAssertEqual(try parse("gitGraph TB:\ncommit").direction, .TB)
        XCTAssertEqual(try parse("gitGraph BT:\ncommit").direction, .BT)
    }

    func testCommitsChainOnTheDefaultBranch() throws {
        let ast = try parse("""
        gitGraph
            commit
            commit
            commit
        """)
        XCTAssertEqual(ast.branches.map(\.name), ["main"])
        XCTAssertEqual(ast.commits.count, 3)
        XCTAssertTrue(ast.commits.allSatisfy { $0.branch == "main" })
        XCTAssertTrue(ast.commits[0].parents.isEmpty)
        XCTAssertEqual(ast.commits[1].parents, [ast.commits[0].id])
        XCTAssertEqual(ast.commits[2].parents, [ast.commits[1].id])
    }

    func testCommitOptions() throws {
        let ast = try parse("""
        gitGraph
            commit id: "Alpha" tag: "v1.0.0" type: HIGHLIGHT
            commit id:"Beta" type:REVERSE
        """)
        XCTAssertEqual(ast.commits[0].id, "Alpha")
        XCTAssertEqual(ast.commits[0].label, "Alpha")
        XCTAssertEqual(ast.commits[0].tag, "v1.0.0")
        XCTAssertEqual(ast.commits[0].type, .highlight)
        XCTAssertEqual(ast.commits[1].id, "Beta")
        XCTAssertEqual(ast.commits[1].type, .reverse)
    }

    func testUnnamedCommitsGetNoDrawnLabel() throws {
        let ast = try parse("gitGraph\ncommit")
        XCTAssertNil(ast.commits[0].label, "auto-generated ids would not be deterministic to draw")
        XCTAssertFalse(ast.commits[0].id.isEmpty)
    }

    func testBranchCreatesAndChecksOut() throws {
        let ast = try parse("""
        gitGraph
            commit id: "one"
            branch develop
            commit id: "two"
        """)
        XCTAssertEqual(ast.branches.map(\.name), ["main", "develop"])
        XCTAssertEqual(ast.commits[1].branch, "develop")
        XCTAssertEqual(ast.commits[1].parents, ["one"], "the branch point is the source branch's head")
    }

    func testMergeHasTwoParents() throws {
        let ast = try parse("""
        gitGraph
            commit id: "one"
            branch develop
            commit id: "two"
            checkout main
            commit id: "three"
            merge develop tag: "v2"
        """)
        let merge = try XCTUnwrap(ast.commits.last)
        XCTAssertEqual(merge.type, .merge)
        XCTAssertEqual(merge.branch, "main")
        XCTAssertEqual(merge.parents, ["three", "two"])
        XCTAssertEqual(merge.tag, "v2")
    }

    func testCherryPickReferencesTheSourceCommit() throws {
        let ast = try parse("""
        gitGraph
            commit id: "one"
            branch develop
            commit id: "two"
            checkout main
            cherry-pick id: "two"
        """)
        let picked = try XCTUnwrap(ast.commits.last)
        XCTAssertEqual(picked.type, .cherryPick)
        XCTAssertEqual(picked.branch, "main")
        XCTAssertEqual(picked.parents, ["one", "two"])
        XCTAssertEqual(picked.label, "two")
    }

    func testSwitchIsAnAliasForCheckout() throws {
        let ast = try parse("""
        gitGraph
            commit
            branch develop
            checkout main
            commit id: "on-main"
            switch develop
            commit id: "on-develop"
        """)
        XCTAssertEqual(ast.commits.first { $0.id == "on-main" }?.branch, "main")
        XCTAssertEqual(ast.commits.first { $0.id == "on-develop" }?.branch, "develop")
    }

    func testSemanticErrors() {
        XCTAssertThrowsError(try parse("gitGraph\ncheckout nope"))
        XCTAssertThrowsError(try parse("gitGraph\nmerge nope"))
        XCTAssertThrowsError(try parse("gitGraph\ncommit\nmerge main"))
        XCTAssertThrowsError(try parse("gitGraph\nbranch dev\nbranch dev"))
        XCTAssertThrowsError(try parse("gitGraph\ncommit id: \"x\"\ncommit id: \"x\""))
        XCTAssertThrowsError(try parse("gitGraph\ncommit\ncherry-pick id: \"nope\""))
    }

    // MARK: - Layout

    func testLaneOrder() throws {
        let ast = try parse("""
        gitGraph
            commit
            branch late order: 5
            branch early
        """)
        let laid = GitGraphLayout.layout(ast)
        XCTAssertEqual(laid.lanes.map(\.name), ["main", "early", "late"],
                       "explicit `order:` sorts last; unordered branches keep declaration order")
    }

    func testCommitsAdvanceAlongTheMainAxis() throws {
        let lr = GitGraphLayout.layout(try parse("gitGraph\ncommit\ncommit\ncommit"))
        XCTAssertEqual(lr.commits.map(\.center.y), Array(repeating: lr.commits[0].center.y, count: 3))
        XCTAssertTrue(zip(lr.commits, lr.commits.dropFirst()).allSatisfy { $0.center.x < $1.center.x })

        let tb = GitGraphLayout.layout(try parse("gitGraph TB:\ncommit\ncommit\ncommit"))
        XCTAssertEqual(tb.commits.map(\.center.x), Array(repeating: tb.commits[0].center.x, count: 3))
        XCTAssertTrue(zip(tb.commits, tb.commits.dropFirst()).allSatisfy { $0.center.y < $1.center.y })

        let bt = GitGraphLayout.layout(try parse("gitGraph BT:\ncommit\ncommit\ncommit"))
        XCTAssertTrue(zip(bt.commits, bt.commits.dropFirst()).allSatisfy { $0.center.y > $1.center.y })
    }

    func testCrossLaneEdgesAreCurves() throws {
        let laid = GitGraphLayout.layout(try parse("""
        gitGraph
            commit
            commit
            branch develop
            commit
        """))
        XCTAssertEqual(laid.edges.filter { $0.points.count == 2 }.count, 1, "one same-lane edge")
        XCTAssertEqual(laid.edges.filter { $0.points.count == 4 }.count, 1, "one branch-off curve")
    }

    func testCherryPickEdgeIsDashed() throws {
        let laid = GitGraphLayout.layout(try parse("""
        gitGraph
            commit id: "one"
            branch develop
            commit id: "two"
            checkout main
            cherry-pick id: "two"
        """))
        XCTAssertEqual(laid.edges.filter(\.dashed).count, 1)
    }

    // MARK: - Scene

    func testRendersScene() throws {
        let scene = try Mermaid.render("""
        gitGraph
            commit id: "init"
            branch develop
            commit id: "work" tag: "v1"
            checkout main
            merge develop
        """)
        XCTAssertGreaterThan(scene.size.width, 0)
        XCTAssertGreaterThan(scene.size.height, 0)
        XCTAssertGreaterThan(scene.elements.count, 10)
    }

    func testSVGIsDeterministic() throws {
        let src = "gitGraph\ncommit\nbranch dev\ncommit\ncheckout main\nmerge dev"
        XCTAssertEqual(try Mermaid.render(src).svgString(), try Mermaid.render(src).svgString())
    }

    func testDegenerateSourcesRenderWithoutCrashing() throws {
        for src in ["gitGraph",
                    "gitGraph TB:",
                    "gitGraph\nbranch dev",
                    "gitGraph\ncommit tag: \"only-a-tag\""] {
            let scene = try Mermaid.render(src)
            XCTAssertGreaterThan(scene.size.width, 0, src)
            XCTAssertNotNil(scene.cgImage(scale: 1), src)
        }
    }
}
