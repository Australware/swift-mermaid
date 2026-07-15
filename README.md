# swift-mermaid

[![Swift 5.10+](https://img.shields.io/badge/Swift-5.10+-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-macOS%2014-blue.svg)](https://developer.apple.com)
[![SPM Compatible](https://img.shields.io/badge/SPM-Compatible-brightgreen.svg)](https://swift.org/package-manager)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A pure-Swift [Mermaid](https://mermaid.js.org) diagram renderer for Apple platforms - no
JavaScript engine, no `WKWebView`, no network access. Built to be embedded in sandboxed apps that
need to render Markdown previews containing ```` ```mermaid ```` fenced blocks without dragging
WebKit (or its `com.apple.security.network.client` entitlement) along.

The pipeline mirrors Mermaid's own: source → preprocess → detect type → type-specific parser →
type-specific layout → renderer → `MermaidScene` (geometry + style IR) → SVG / `CGImage` / PDF.

## Status

| Diagram type            | Status         |
| ----------------------- | -------------- |
| `flowchart` / `graph`   | ✅ v1          |
| `sequenceDiagram`       | ✅ v1          |
| `pie`                   | ✅ v1          |
| `architecture-beta`     | ✅ v1 (built-in icons only — no custom iconify packs) |
| `classDiagram(-v2)`     | ✅ v1 (notes & namespaces parsed-and-skipped) |
| `stateDiagram(-v2)`     | ✅ v1 (concurrency `--` regions lay out together, without a divider) |
| `ER`                    | ⏳ planned     |
| `gantt`                 | ⏳ planned     |
| `journey`               | ⏳ planned     |
| `quadrantchart`         | ⏳ planned     |
| `gitgraph`              | ⏳ planned     |
| `mindmap`               | ⏳ planned     |
| `timeline`              | ⏳ planned     |
| `zenuml`                | ⏳ planned     |
| `requirementdiagram`    | ⏳ planned     |
| `sankey`                | ⏳ planned     |
| `xychart`               | ⏳ planned     |
| `block`                 | ⏳ planned     |
| `kanban`                | ⏳ planned     |
| `eventmodeling`         | ⏳ planned     |
| `treemap-beta`          | ⏳ planned     |
| `venn-beta`             | ⏳ planned     |


Unsupported diagram types throw `.unsupportedDiagramType` cleanly.

Determinism is a hard requirement: same `(source, theme, OS)` → byte-identical SVG output.

## Installation

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/australware/swift-mermaid.git", from: "0.1.0")
],
targets: [
    .target(name: "YourApp", dependencies: [
        .product(name: "Mermaid", package: "swift-mermaid")
    ])
]
```

Platforms: **macOS 14+**. (Uses Core Text for deterministic text measurement.) Only the `Mermaid`
library product is exported — there's nothing to vendor; add the package and `import Mermaid`.

## Usage

```swift
import Mermaid

let scene = try Mermaid.render("""
flowchart TD
    Start([Start]) --> Check{Valid?}
    Check -->|yes| Process[Process data]
    Check -->|no| Error[/Show error/]
    Process --> Save[(Database)]
    Save --> Done([End])
    Error --> Done
""", theme: .dark)

// Three output paths, all derived from the same MermaidScene:
let svg: String   = scene.svgString()      // presentation-attribute SVG (no <style> block)
let png: CGImage? = scene.cgImage(scale: 2)
let pdf: Data     = scene.pdfData()         // single-page vector PDF
```

`MermaidScene` is also a public IR if you want to draw it yourself (SwiftUI `Canvas`,
`CoreGraphics`, …):

```swift
public struct MermaidScene {
    public let size: CGSize
    public let backgroundColor: CGColor?
    public let elements: [MermaidElement]
}

public enum MermaidElement {
    case rect(CGRect, cornerRadius: CGFloat, style: ShapeStyle_)
    case path(CGPath, style: ShapeStyle_)
    case text(String, origin: CGPoint, font: FontSpec, color: CGColor, anchor: TextAnchor)
}
```

## Errors

For any diagram type not yet implemented, `Mermaid.render` throws
`MermaidError.unsupportedDiagramType(_:)` so hosts can fall back to showing the raw source. Syntax
errors throw `.parse(message:line:)`; unknown directives (`classDef`, `style`, `linkStyle`, `click`,
`%%{init}%%` keys beyond `theme`, …) are parse-and-skipped.

## Architecture

```
Sources/Mermaid/
  Core/              # Scene, errors, geometry, theme palettes, text measurement,
                     #  SVG / Core Graphics renderers, diagram-type detection.
  Flowchart/         # Parser, two interchangeable layout backends, renderer.
  Sequence/          # Parser, bespoke deterministic layout, renderer.
  Pie/               # Parser, renderer.
  Class/             # Parser, dagre-backed layout (shares the vendored backend), renderer.
  Architecture/      # Parser, grid-constraint layout, renderer (built-in icon glyphs).
  Mermaid.swift      # Umbrella entry point.
Vendor/MermaidLayoutDagre/
                     # Vendored copy of lukilabs/dagre-swift @ 92efb78 (MIT). Network-simplex
                     # ranking, Brandes–Köpf x-coords, real compound-graph (subgraph) layout.
                     # Drives the flowchart and class-diagram layouts. Internal target — not
                     # exported as a product, so consumers can't couple to it. See
                     # Vendor/MermaidLayoutDagre/VENDORED.md and THIRD-PARTY-NOTICES.md.
```

### Flowchart layout backends

`Mermaid.render(source, theme: …, layout: .dagre)` (the default) uses the vendored dagre. Pass
`.builtin` for the hand-rolled Sugiyama fallback. Override globally with `MERMAID_DAGRE=0`.

## Tests

```sh
swift test
```

Parser tests, scene tests (determinism, SVG presentation attrs, sizes), and a
`VisualSmokeTests` suite that dumps PNG/SVG/PDF samples to a temp directory for visual review:

```
Visual output: /var/folders/.../swift-mermaid-visual/
```

## Known limitations

- Node labels are plain text. `**bold**` / `*italic*` / `<br/>` inside labels are not yet honoured
  (multi-line via `\n` works).
- The hand-rolled fallback (`.builtin`) layout is intentionally simple: the long-edge bend-point
  smoothing can dip near intermediate nodes on complex graphs, and `LR`/`RL`/`BT` reuse the TB
  pipeline with a final rotation. Use `.dagre` (the default) to avoid both. The fallback exists
  for when you want zero compiled-in dependencies and acceptable-not-great layout.



