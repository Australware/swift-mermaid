// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "swift-mermaid",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        // Only the umbrella `Mermaid` library is exposed. `MermaidLayoutDagre` is a vendored copy
        // of lukilabs/dagre-swift used internally as the flowchart layout backend
        .library(name: "Mermaid", targets: ["Mermaid"])
    ],
    targets: [
        // Vendored copy of lukilabs/dagre-swift — see Vendor/MermaidLayoutDagre/VENDORED.md and
        // THIRD-PARTY-NOTICES.md. Internal: not a product, so consumers can't couple to it.
        .target(
            name: "MermaidLayoutDagre",
            path: "Vendor/MermaidLayoutDagre",
            exclude: ["LICENSE", "VENDORED.md", "UPSTREAM-README.md"]
        ),
        .target(
            name: "Mermaid",
            dependencies: ["MermaidLayoutDagre"],
            path: "Sources/Mermaid"
        ),
        .testTarget(
            name: "MermaidTests",
            dependencies: ["Mermaid"],
            path: "Tests/MermaidTests"
        )
    ]
)
