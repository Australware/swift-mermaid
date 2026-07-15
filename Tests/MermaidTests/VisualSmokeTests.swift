import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Mermaid

/// Writes representative diagrams to the test bundle's temp dir as SVG + PNG. These aren't
/// snapshot-compared yet — they're a sanity check for "does it produce a plausible image at all"
/// and let a human eyeball the output by opening the printed paths.
final class VisualSmokeTests: XCTestCase {

    private static let outputDir: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-mermaid-visual", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private func dump(_ name: String, source: String, theme: MermaidTheme = .default) throws {
        // For flowchart-family diagrams, dump both layout backends so we can compare. For sequence
        // and pie the backend choice is irrelevant.
        try dumpOne("\(name)", source: source, theme: theme, layout: .builtin)
        // The dagre dump is suffixed; only meaningful for flowcharts but harmless for other types
        // because the umbrella API only consults `layout` on the flowchart branch.
        try dumpOne("\(name)-dagre", source: source, theme: theme, layout: .dagre)
    }

    private func dumpOne(_ name: String, source: String, theme: MermaidTheme, layout: Mermaid.LayoutBackend) throws {
        let scene = try Mermaid.render(source, theme: theme, layout: layout)
        let svgURL = Self.outputDir.appendingPathComponent("\(name).svg")
        try scene.svgString().write(to: svgURL, atomically: true, encoding: .utf8)

        if let image = scene.cgImage(scale: 2) {
            let pngURL = Self.outputDir.appendingPathComponent("\(name).png")
            try writePNG(image, to: pngURL)
        }

        let pdfURL = Self.outputDir.appendingPathComponent("\(name).pdf")
        try scene.pdfData().write(to: pdfURL)
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "VisualSmoke", code: 1)
        }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    func testFlowchart_basicLightAndDark() throws {
        let src = """
        flowchart TD
            Start([Start]) --> Check{Valid?}
            Check -->|yes| Process[Process data]
            Check -->|no| Error[/Show error/]
            Process --> Save[(Database)]
            Save --> Done([End])
            Error --> Done
        """
        try dump("flowchart-basic-light", source: src, theme: .default)
        try dump("flowchart-basic-dark", source: src, theme: .dark)
        print("Visual output: \(Self.outputDir.path)")
    }

    func testFlowchart_subgraph() throws {
        try dump("flowchart-subgraph", source: """
        flowchart LR
            A[Client] --> B
            subgraph Server
                B[API] --> C[Worker]
                C --> D[(DB)]
            end
            D --> E[Reply]
        """)
    }

    func testSequence_full() throws {
        try dump("sequence-full", source: """
        sequenceDiagram
            autonumber
            participant U as User
            participant S as Server
            participant D as Database
            U->>+S: GET /items
            S->>+D: SELECT
            D-->>-S: rows
            S-->>-U: 200 OK
            Note right of U: render list
            loop poll
                U->>S: ping
            end
            alt cache hit
                S-->>U: cached
            else miss
                S->>D: query
                D-->>S: rows
                S-->>U: fresh
            end
        """)
    }

    func testClassDiagram() throws {
        try dump("class-basic", source: """
        classDiagram
            direction TB
            Animal <|-- Duck
            Animal <|-- Fish
            Animal <|-- Zebra
            Animal : +int age
            Animal : +String gender
            Animal : +isMammal() bool
            Animal : +mate()
            class Duck {
                +String beakColor
                +swim()
                +quack()
            }
            class Fish {
                -int sizeInFeet
                -canEat() bool
            }
        """)

        try dump("class-relations", source: """
        classDiagram
            class Shape {
                <<interface>>
                +area() float
            }
            Shape <|.. Circle
            Shape <|.. Rectangle
            Vehicle "1" *-- "1..*" Wheel : has
            Garage o-- Vehicle
            Driver --> Vehicle : drives
            Order ..> Payment
            Circle : -float radius
            Rectangle : -float w
            Rectangle : -float h
        """, theme: .dark)
    }

    func testStateDiagram() throws {
        let src = """
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
        try dump("state-basic-light", source: src, theme: .default)
        try dump("state-basic-dark", source: src, theme: .dark)

        try dump("state-choice-fork", source: """
        stateDiagram-v2
            direction LR
            state if_state <<choice>>
            state fork_state <<fork>>
            state join_state <<join>>
            [*] --> if_state
            if_state --> Retry : error
            if_state --> fork_state : ok
            fork_state --> WriteLog
            fork_state --> UpdateUI
            WriteLog --> join_state
            UpdateUI --> join_state
            join_state --> [*]
            Retry --> if_state
        """)
        print("Visual output: \(Self.outputDir.path)")
    }

    func testPie() throws {
        try dump("pie-basic", source: """
        pie title NETFLIX
            "Time spent looking for movie" : 90
            "Time spent watching it" : 10
        """)
    }

    func testArchitecture() throws {
        try dumpOne("architecture-basic", source: """
        architecture-beta
            group api(cloud)[API]

            service db(database)[Database] in api
            service disk1(disk)[Storage] in api
            service disk2(disk)[Storage] in api
            service server(server)[Server] in api

            db:L -- R:server
            disk1:T -- B:server
            disk2:T -- B:db
            server:T -- B:db
        """, theme: .default, layout: .builtin)

        try dumpOne("architecture-junctions", source: """
        architecture-beta
            service left_disk(disk)[Disk]
            service top_disk(disk)[Disk]
            service bottom_disk(disk)[Disk]
            service top_gateway(internet)[Gateway]
            service bottom_gateway(internet)[Gateway]
            junction junctionCenter
            junction junctionRight

            left_disk:R -- L:junctionCenter
            top_disk:B -- T:junctionCenter
            bottom_disk:T -- B:junctionCenter
            junctionCenter:R -- L:junctionRight
            top_gateway:B -- T:junctionRight
            bottom_gateway:T -- B:junctionRight
        """, theme: .default, layout: .builtin)

        try dumpOne("architecture-groups", source: """
        architecture-beta
            group federated(cloud)[Federated Environment]
                service server1(server)[Server] in federated
                service edge(internet)[Edge Device] in federated

            group on_prem(cloud)[Local Environment]
                service server2(server)[Server] in on_prem
                service db(database)[Database] in on_prem

            server1:R --> L:edge
            edge:R --> L:server2
            server2:R --> L:db
        """, theme: .dark, layout: .builtin)
    }
}
