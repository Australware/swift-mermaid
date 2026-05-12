import XCTest
@testable import Mermaid

final class ClassDiagramTests: XCTestCase {

    private func parse(_ src: String) throws -> ClassDiagramAST {
        try ClassParser.parse(src)
    }

    // MARK: - Parser

    func testHeaderRequired() {
        XCTAssertThrowsError(try parse("nope\nA <|-- B"))
    }

    func testBasicInheritance() throws {
        let ast = try parse("""
        classDiagram
            Animal <|-- Duck
            Animal <|-- Fish
        """)
        XCTAssertEqual(ast.direction, .TB)
        XCTAssertEqual(ast.classOrder, ["Animal", "Duck", "Fish"])
        XCTAssertEqual(ast.relations.count, 2)
        let r = ast.relations[0]
        XCTAssertEqual(r.id1, "Animal")
        XCTAssertEqual(r.id2, "Duck")
        XCTAssertEqual(r.startKind, .extends)
        XCTAssertEqual(r.endKind, .none)
        XCTAssertEqual(r.lineStyle, .solid)
    }

    func testRelationMarkerKinds() throws {
        let ast = try parse("""
        classDiagram
            A --|> B
            C *-- D
            E o-- F
            G --> H
            I ..> J
            K ..|> L
            M -- N
        """)
        XCTAssertEqual(ast.relations.count, 7)
        XCTAssertEqual(ast.relations[0].endKind, .extends)
        XCTAssertEqual(ast.relations[0].lineStyle, .solid)
        XCTAssertEqual(ast.relations[1].startKind, .composition)
        XCTAssertEqual(ast.relations[2].startKind, .aggregation)
        XCTAssertEqual(ast.relations[3].endKind, .association)
        XCTAssertEqual(ast.relations[4].endKind, .association)
        XCTAssertEqual(ast.relations[4].lineStyle, .dashed)
        XCTAssertEqual(ast.relations[5].endKind, .extends)
        XCTAssertEqual(ast.relations[5].lineStyle, .dashed)
        XCTAssertEqual(ast.relations[6].startKind, .none)
        XCTAssertEqual(ast.relations[6].endKind, .none)
    }

    func testCardinalitiesAndLabel() throws {
        let ast = try parse("""
        classDiagram
            Customer "1" --> "*" Order : places
        """)
        let r = try XCTUnwrap(ast.relations.first)
        XCTAssertEqual(r.id1, "Customer")
        XCTAssertEqual(r.id2, "Order")
        XCTAssertEqual(r.startCardinality, "1")
        XCTAssertEqual(r.endCardinality, "*")
        XCTAssertEqual(r.label, "places")
        XCTAssertEqual(r.endKind, .association)
    }

    func testMembersViaColonAndBlock() throws {
        let ast = try parse("""
        classDiagram
            Animal : +int age
            Animal : +mate()
            class Duck {
                +String beakColor
                +swim()
                +quack()
            }
        """)
        let animal = try XCTUnwrap(ast.classes["Animal"])
        XCTAssertEqual(animal.members.map(\.text), ["+int age"])
        XCTAssertEqual(animal.methods.map(\.text), ["+mate()"])
        let duck = try XCTUnwrap(ast.classes["Duck"])
        XCTAssertEqual(duck.members.map(\.text), ["+String beakColor"])
        XCTAssertEqual(duck.methods.map(\.text), ["+swim()", "+quack()"])
    }

    func testAnnotationAndGenericsAndDisplayLabel() throws {
        let ast = try parse("""
        classDiagram
            class Shape {
                <<interface>>
                +draw()
            }
            class Square~Shape~
            class BankAccount["A bank account"]
            <<service>> BankAccount
        """)
        XCTAssertEqual(ast.classes["Shape"]?.annotation, "interface")
        XCTAssertEqual(ast.classes["Square"]?.name, "Square<Shape>")
        XCTAssertEqual(ast.classes["BankAccount"]?.name, "A bank account")
        XCTAssertEqual(ast.classes["BankAccount"]?.annotation, "service")
    }

    func testDirectionStatement() throws {
        let ast = try parse("classDiagram\ndirection LR\nA <|-- B")
        XCTAssertEqual(ast.direction, .LR)
    }

    func testNotesAndStylingSkipped() throws {
        let ast = try parse("""
        classDiagram
            class A
            note "a floating note"
            note for A "a note for A"
            style A fill:#f9f
            classDef big font-size:20px
        """)
        XCTAssertEqual(ast.classOrder, ["A"])
        XCTAssertTrue(ast.relations.isEmpty)
    }

    func testMemberStatementNotMistakenForRelation() throws {
        // The `:` line is a member, not a relationship — even though it has no spaces.
        let ast = try parse("classDiagram\nFoo:+bar()")
        XCTAssertEqual(ast.classes["Foo"]?.methods.map(\.text), ["+bar()"])
        XCTAssertTrue(ast.relations.isEmpty)
    }

    func testReversedInheritanceLayoutOrientation() throws {
        // `Duck --|> Animal` and `Animal <|-- Duck` should produce the same picture: Animal above.
        let a = ClassLayout.layout(try parse("classDiagram\nAnimal <|-- Duck"))
        let b = ClassLayout.layout(try parse("classDiagram\nDuck --|> Animal"))
        func centreY(_ d: PositionedClassDiagram, _ id: String) -> CGFloat {
            d.boxes.first { $0.def.id == id }!.rect.midY
        }
        XCTAssertLessThan(centreY(a, "Animal"), centreY(a, "Duck"))
        XCTAssertLessThan(centreY(b, "Animal"), centreY(b, "Duck"))
    }

    // MARK: - Scene

    func testRendersScene() throws {
        let scene = try Mermaid.render("""
        classDiagram
            Animal <|-- Duck
            Animal <|-- Fish
            Animal : +int age
            Animal : +mate()
            class Duck {
                +String beakColor
                +swim()
            }
        """)
        XCTAssertGreaterThan(scene.size.width, 0)
        XCTAssertGreaterThan(scene.size.height, 0)
        XCTAssertGreaterThan(scene.elements.count, 8)
    }

    func testSceneDeterministic() throws {
        let src = """
        classDiagram
            class Shape {
                <<interface>>
                +area() float
            }
            Shape <|.. Circle
            Shape <|.. Rectangle
            Circle : -float radius
            Rectangle : -float width
        """
        XCTAssertEqual(try Mermaid.render(src).svgString(), try Mermaid.render(src).svgString())
    }

    func testEmptyDiagramDoesNotCrash() throws {
        let scene = try Mermaid.render("classDiagram")
        XCTAssertGreaterThan(scene.size.width, 0)
    }
}
