# Spec: a pure-Swift Mermaid rendering library

> **For whoever picks this up:** this is a self-contained brief to build a standalone Swift package
> that parses [Mermaid](https://mermaid.js.org) diagram source and renders it — with no JavaScript
> engine, no WebKit, and no network access. The package will be added as a dependency to **MaiD**, a
> macOS Markdown editor (Mac App Store target), and called from its preview renderer. You will not
> have the conversation that produced this doc; everything you need should be below. Where a repo URL
> or name is marked `[TBD — ask the maintainer]`, get it from them before starting that part.

---

## 1. Why this exists / context

MaiD renders Markdown previews with a hand-rolled SwiftUI renderer (parses with Apple's
`swift-markdown`, emits plain SwiftUI views). It supports ```` ```mermaid ```` fenced blocks.

The **current** Mermaid implementation in MaiD (which this library will replace) works like this:
spin up a short-lived off-screen `WKWebView`, load a bundled `mermaid.min.js` (~3 MB) + a tiny HTML
shell, call `mermaid.render()`, capture the result with `WKWebView.createPDF()`, cache the PDF, and
display it as an `NSImage`. It works, but:

- It drags WebKit into a project that deliberately moved off it for memory reasons.
- A sandboxed app can't run WKWebView's WebContent process without the
  `com.apple.security.network.client` entitlement — so the app *declares* outbound network access
  even though it makes none. The maintainer wants to **remove that entitlement entirely**, which
  means removing WKWebView from the picture.
- It ships a 3 MB JS blob.

So: a pure-Swift implementation. It doesn't need to be a pixel-perfect Mermaid clone — "renders the
common diagram types clearly and correctly, deterministically, offline" is the bar.

A working WKWebView-based implementation is preserved on a branch in the MaiD repo
(`[TBD — ask the maintainer for the branch name]`) — useful as a reference for the integration
points and as a fallback.

---

## 2. Deliverable

A **standalone Swift Package** (its own git repo), e.g. `swift-mermaid` / module `Mermaid`
(final name TBD with the maintainer). Apple-platforms only is fine — target **macOS 14+** (MaiD's
floor; uses Core Text for text metrics). No third-party runtime dependencies other than, optionally,
a Swift port of dagre (see §6).

### Public API (proposed — refine as needed, keep it small)

```swift
public enum Mermaid {
    /// Parse → layout → render. The returned scene is a resolution-independent geometry+style model.
    public static func render(_ source: String, theme: MermaidTheme = .default) throws -> MermaidScene
}

public enum MermaidTheme: Sendable {
    case `default`   // light
    case dark
    // later: forest, neutral, base
}

public struct MermaidScene: Sendable {
    public let size: CGSize                 // intrinsic size in points
    public let backgroundColor: CGColor?    // nil = transparent
    public let elements: [MermaidElement]   // z-ordered: shapes, paths, text, ...
    // Serialize to a standalone SVG document string. MUST use presentation attributes
    // (fill="…", stroke="…", font-size="…", text-anchor="…") — NOT an embedded <style> block —
    // so it renders correctly in NSImage's SVG engine and other simple renderers.
    public func svgString() -> String
    // Render via Core Graphics. Vector-correct; pdfData() stays crisp at any zoom.
    public func cgImage(scale: CGFloat) -> CGImage?
    public func pdfData() -> Data
}

public enum MermaidElement: Sendable {
    case rect(CGRect, cornerRadius: CGFloat, style: ShapeStyle_)
    case path(CGPath, style: ShapeStyle_)        // edges, polygons (diamonds, etc.), arrowheads
    case text(String, origin: CGPoint, font: FontSpec, color: CGColor, anchor: TextAnchor)
    // (extend as needed: images, groups, …)
}

public enum MermaidError: Error, Sendable {
    case unsupportedDiagramType(String)
    case parse(message: String, line: Int)
    case layout(message: String)
}
```

Layered outputs on purpose:
- `MermaidScene` is the core IR — advanced hosts can draw it themselves (SwiftUI `Canvas`, Core Graphics).
- `svgString()` doubles as the path for **HTML/PDF *export*** elsewhere in MaiD (emit `<svg>` directly, no JS).
- `cgImage` / `pdfData` is what MaiD's preview will actually call — simplest, full fidelity, no external SVG renderer.

**Determinism is a hard requirement.** Same `(source, theme, OS)` ⇒ identical output. Round SVG/PDF
coordinates to a fixed precision. Don't depend on dictionary iteration order, etc.

---

## 3. Scope & priorities

Mermaid has ~15 diagram types. Don't try to do them all. Ship in this order; each milestone should
be independently usable:

1. **Flowchart** (`flowchart` / `graph`) — the most common by far. **v1 must-have.**
2. **Sequence diagram** (`sequenceDiagram`) — second most common. **v1 must-have.**
3. **Pie chart** (`pie`) — trivial, nice quick win.
4. **State diagram** (`stateDiagram-v2`) — reuses much of the flowchart layout machinery.
5. **Class diagram** (`classDiagram`).
6. Everything else (ER, gantt, gitGraph, journey, mindmap, timeline, quadrant, …) — later / as needed.

For any diagram type not yet implemented, `Mermaid.render` should `throw .unsupportedDiagramType`
**cleanly** (MaiD will catch it and fall back to showing the raw source) — never crash, never hang.

Within a supported type, gracefully ignore syntax you don't handle yet (unknown directives, `click`
handlers, `%%{init}%%` config blocks beyond `theme`, YAML frontmatter inside the diagram, styling
directives like `classDef`/`style`/`linkStyle` if not implemented, etc.) — parse-and-skip, don't bail.

---

## 4. Architecture

Mirror Mermaid's own pipeline:

```
source ──▶ [strip comments / frontmatter / %%{init}%% ] ──▶ [detect diagram type]
        ──▶ [type-specific parser → AST] ──▶ [type-specific layout → positioned model]
        ──▶ [renderer → MermaidScene] ──▶ svg() / cgImage() / pdfData()
                              ▲
                          [theme]
```

Suggested module layout (one package, can be one module to start):

- **`MermaidCore`** — diagram-type detection, common geometry types, `MermaidScene`, the SVG and
  Core Graphics serializers, text measurement, theming, error types.
- **`MermaidFlowchart`** — flowchart parser + layout (uses the dagre layer) + renderer.
- **`MermaidSequence`** — sequence-diagram parser + (bespoke, deterministic) layout + renderer.
- **`MermaidLayoutDagre`** — a layered-graph layout (Sugiyama). Either vendor/depend on the existing
  Swift dagre port (see §6) or implement it. Used by flowchart & state diagrams.
- **`Mermaid`** — umbrella that picks the right sub-pipeline by detected type.

### 4.1 Diagram-type detection

After stripping leading whitespace, `%% …` line comments, a leading `---\n…\n---` YAML frontmatter
block, and `%%{init: …}%%` directives (capture `theme` from there if present), the first significant
token determines the type: `flowchart`/`graph` → flowchart; `sequenceDiagram` → sequence;
`stateDiagram`/`stateDiagram-v2` → state; `classDiagram` → class; `pie` → pie; `erDiagram` → ER;
`gantt` → gantt; etc. (See Mermaid's `detectType` for the full list of patterns.)

### 4.2 Parsing

Hand-written recursive-descent parsers (don't try to port Mermaid's Jison grammars verbatim, but use
the `.jison` files and the Python reference as the authoritative spec for what syntax exists). Each
parser produces a small typed AST. Track line numbers for `MermaidError.parse`.

### 4.3 Text measurement

Node sizes depend on label text size. Use **Core Text** (`CTLine` / `NSAttributedString.boundingRect`
/ `CTFramesetterSuggestFrameSizeWithConstraints`) to measure. This is deterministic on a given OS and
is why the package is Apple-only. Font: Mermaid's default is the system sans (`trebuchet ms`/Helvetica
family at ~16px for nodes, smaller for edge labels) — pick a reasonable system font (`-apple-system` /
`NSFont.systemFont`) and document the mapping. Support multi-line labels (Mermaid wraps long node text)
and a small subset of inline markdown in labels (`**bold**`, `*italic*`, `<br/>`) — or punt on that in
v1 and treat labels as plain text.

### 4.4 Layout

- **Flowchart / state:** build a directed graph; assign each node its measured size; run the layered
  layout (dagre): rank assignment → cycle breaking → ordering / crossing reduction → x-coordinate
  assignment → edge routing (with bend points). Honor the direction keyword (`TD`/`TB`, `LR`, `RL`,
  `BT`). Edge labels become dummy nodes inserted on the edge (dagre handles this). Self-loops and
  subgraphs/clusters need special handling (dagre supports compound graphs for subgraphs). Read back
  node centers + sizes and edge point lists; that's the positioned model.
- **Sequence:** no graph layout needed. Lay actors left-to-right with fixed spacing (widened to fit
  the widest message that spans them); draw lifelines down; place messages top-to-bottom in order;
  handle activations (overlapping bars on a lifeline), notes, and `loop`/`alt`/`opt`/`par` framed
  groups, `autonumber`. This is straightforward bookkeeping — see Mermaid's `sequenceRenderer` and the
  Python reference.
- **Pie:** compute slice angles from values; that's it.

### 4.5 Rendering → `MermaidScene`

Walk the positioned model and emit elements:
- Node shapes: rounded rect `[text]`, stadium `([text])`, subroutine `[[text]]`, cylinder `[(text)]`,
  circle `((text))`, rhombus/decision `{text}`, hexagon `{{text}}`, parallelogram `[/text/]` & `[\text\]`,
  trapezoid `[/text\]` & `[\text/]`, double-circle `(((text)))`, asymmetric `>text]`, etc. (full list in
  Mermaid's flowchart shapes module). Each is a `CGPath` or `rect`.
- Edges: a polyline/spline through the dagre bend points, smoothed (Catmull-Rom → bezier is what
  Mermaid does), with an arrowhead marker at the end (and/or start) depending on edge type
  (`-->` arrow, `---` none, `-.->` dotted+arrow, `==>` thick+arrow, `--o`/`--x` circle/cross ends, etc.).
  Edge labels as `text` elements at the label dummy-node position, optionally with a small background rect.
- Text: node labels (centered), edge labels, titles, subgraph titles.
- Theme supplies fills, strokes, text colors, stroke widths, fonts.

---

## 5. Theming

Implement at least `default` (light) and `dark`. Mermaid's theme variables (node fill, node border,
edge stroke, edge label background, text color, cluster fill, etc.) are defined in
`packages/mermaid/src/themes/theme-default.js` and `theme-dark.js` — copy the relevant color values.
Keep a `MermaidTheme` → concrete palette mapping in `MermaidCore`. (MaiD will pass `.dark` when its
preview is in dark mode, `.default` otherwise.)

---

## 6. Reference materials

Authoritative:

- **Mermaid source** — `https://github.com/mermaid-js/mermaid`
  - Diagram-type detection: `packages/mermaid/src/diagram-api/detectType.ts`
  - Grammars (the spec for *what syntax exists*): `packages/mermaid/src/diagrams/<type>/parser/*.jison`
    — e.g. `flowchart/parser/flow.jison`, `sequence/parser/sequenceDiagram.jison`
  - Flowchart layout/render: `packages/mermaid/src/dagre-wrapper/` and `rendering-util/`,
    `diagrams/flowchart/flowRenderer-v3.ts`, node shapes in `rendering-util/rendering-elements/shapes/`
  - Sequence render: `packages/mermaid/src/diagrams/sequence/sequenceRenderer.ts`
  - Themes: `packages/mermaid/src/themes/`
- **dagre** (the layered-graph layout algorithm Mermaid uses for flowcharts) — JS source at
  `https://github.com/dagrejs/dagre` (and `graphlib`). The wiki there explains the algorithm
  (Gansner et al., "A Technique for Drawing Directed Graphs"). The **Swift dagre port the maintainer
  mentioned**: `[TBD — ask the maintainer for the repo URL]`. Evaluate it; if it's a faithful,
  maintained port, depend on it (SPM) or vendor it; otherwise port from the JS or implement the
  Sugiyama pipeline directly.
- **The pure-Python Mermaid reference the maintainer mentioned** — `[TBD — ask the maintainer for the
  repo URL]`. Useful as a second, readable implementation to cross-check parsing and layout behavior
  against.
- General: the Sugiyama framework for layered graph drawing; Brandes–Köpf for x-coordinate assignment
  (what dagre uses).

Sanity-check your output visually against the **Mermaid Live Editor** (`https://mermaid.live`) for the
same source — it won't match pixel-for-pixel (different layout impl) but should be recognizably the
same diagram.

---

## 7. Flowchart syntax to support in v1 (representative — see `flow.jison` for the full grammar)

- Header: `flowchart TD` / `graph LR` / `flowchart` (default TD). Directions: `TB`/`TD`, `BT`, `LR`, `RL`.
- Nodes & shapes: `id`, `id[rect text]`, `id(round)`, `id([stadium])`, `id[[subroutine]]`,
  `id[(database)]`, `id((circle))`, `id>asymmetric]`, `id{rhombus}`, `id{{hexagon}}`,
  `id[/parallelogram/]`, `id[\parallelogram\]`, `id[/trapezoid\]`, `id[\trapezoid/]`, `id(((double circle)))`.
  A node may appear multiple times; first shape/label wins (or last — match Mermaid).
- Edges: `A --> B`, `A --- B` (open), `A -.-> B` (dotted), `A ==> B` (thick), `A --o B`, `A --x B`,
  `A <--> B` (bi-dir). With labels: `A -->|text| B` or `A -- text --> B` (and `-.text.->`, `== text ==>`).
  Variable length: `A ---> B` (extra dashes = more rank distance).
- Chains: `A --> B --> C`; `A & B --> C & D` (fan-out/in).
- Subgraphs: `subgraph title ... end` (nestable; `direction` inside).
- Comments: `%% …`. Init: `%%{init: {'theme':'dark', 'flowchart': {...}}}%%` (honor `theme`, ignore the rest in v1).
- Ignore-in-v1 (parse & skip): `classDef`, `class A foo`, `style A fill:#f9f`, `linkStyle`, `click A "url"`,
  `:::className` shorthand, font-awesome icons, markdown in labels (or do a tiny subset). Don't crash on them.

## 8. Sequence diagram syntax to support in v1 (see `sequenceDiagram.jison`)

- `sequenceDiagram` header; `autonumber`.
- `participant Alice`, `participant A as Alice`, `actor Bob` (actor = person icon).
- Messages: `A->>B: text` (solid arrow), `A-->>B: text` (dashed arrow), `A->B`/`A-->B` (open),
  `A-xB`/`A--xB` (cross end), `A-)B`/`A--)B` (async/open arrow). `A->>A: text` (self-message loop).
- Activations: `activate A` / `deactivate A`, or `A->>+B: …` / `B-->>-A: …` shorthand.
- Notes: `Note right of A: text`, `Note left of A: …`, `Note over A,B: …`.
- Grouping frames: `loop label … end`, `alt label … else label … end`, `opt label … end`,
  `par label … and label … end`, `critical … option … end`, `break … end`. (At minimum loop/alt/opt/par.)
- `box ... end` (grouped participants), `participant background colors` — v1 can skip.
- Comments `%% …`.

---

## 9. Testing strategy

- **Parser tests:** a corpus of `.mmd` snippets → expected AST (or at least: parses without error,
  right node/edge counts, right labels). Include malformed inputs that should `throw .parse` cleanly.
- **Layout/scene tests:** for a set of fixture diagrams, assert on the `MermaidScene` — node count,
  approximate positions/sizes (with a tolerance, since exact layout numbers will shift), edge routing
  sanity (each edge connects the right two nodes, stays within bounds). Don't exact-match SVG strings.
- **Snapshot tests:** render a handful of representative diagrams to PNG via `cgImage` and snapshot
  them (e.g. with `swift-snapshot-testing` or hand-rolled). These catch visual regressions; expect to
  re-record when you intentionally change rendering.
- **Unsupported-type test:** `Mermaid.render("gantt\n …")` (until gantt is implemented) throws
  `.unsupportedDiagramType("gantt")` and does not crash/hang.
- **Determinism test:** render the same source twice, assert byte-identical `svgString()`.
- Build the fixture corpus from real diagrams (Mermaid's own docs/examples are a good source).

---

## 10. Milestones (ship incrementally)

- **M0 — skeleton.** SPM package; `MermaidCore` with geometry types, `MermaidScene`, SVG serializer
  (presentation-attributes), Core Graphics renderer, text measurement, theme palettes, error types,
  diagram-type detection + `%%` / frontmatter / `%%{init}%%` stripping. `Mermaid.render` exists and
  throws `.unsupportedDiagramType` for everything. CI + test scaffolding.
- **M1 — flowchart parser.** `flow.jison`-equivalent: nodes/shapes, edges/labels/types, directions,
  chains, `&`, subgraphs, comments, init (theme only). AST + parse tests.
- **M2 — flowchart layout.** Integrate the dagre layer; wire measured node sizes in; honor direction;
  edge-label dummy nodes; self-loops; subgraph clusters. Positioned-model tests.
- **M3 — flowchart render.** All node shapes, smoothed edge paths, arrowheads/markers, labels, theme
  colors (default + dark). Scene/snapshot tests. **→ first usable release; MaiD can integrate here.**
- **M4 — sequence diagrams.** Parser, deterministic layout, renderer (actors, lifelines, messages,
  activations, notes, loop/alt/opt/par, autonumber, self-messages).
- **M5 — pie charts.**
- **M6 — state diagrams** (`stateDiagram-v2`; reuse flowchart layout).
- **M7 — class diagrams.**
- **M8 — polish:** more themes, label markdown, more sequence/flowchart edge cases, perf.

---

## 11. Integrating back into MaiD (do this after M3 ships)

In MaiD:

1. Add the package as an SPM dependency (in `project.yml` under `packages:` and the target's
   `dependencies:`), then `xcodegen generate`.
2. Replace the body of `Sources/Maid/Preview/MermaidRenderer.swift` — delete the `WKWebView` /
   `WKScriptMessageHandler` / parking-window / `loadFileURL` / `createPDF` machinery and the JS shell;
   keep `MermaidDiagramView` (the SwiftUI view) and a thin async (or even sync) `MermaidRenderer` that
   just calls `Mermaid.render(source, theme: colorScheme == .dark ? .dark : .default)` and turns the
   result into an `NSImage` (`NSImage(data: scene.pdfData())` or directly from `scene.cgImage(scale:)`)
   plus its `size`. Caching by `(source, theme)` can stay (cheap; renders are fast now). The
   `MDBlock.mermaid(source:)` case in `MarkdownRenderer.swift` and the `code.language == "mermaid"`
   mapping stay unchanged. Keep the "scale up to ~1.6×, hug the box" presentation.
3. Remove `Resources/mermaid.min.js` (and its line in `project.yml` `sources:`).
4. **Remove `com.apple.security.network.client` from `Resources/Maid.entitlements`** — this is the
   point of the whole exercise.
5. Bonus: in `Sources/Maid/Export/HTMLExporter.swift`, make ```` ```mermaid ```` blocks emit
   `scene.svgString()` inline (instead of the raw source as a code block) — now there's no JS or
   render-timing problem for PDF export either.
6. Delete the `Log.mermaid` web-pipeline tracing (or keep a slimmed version).

---

## 12. Open questions / risks

- **Layout fidelity.** Flowchart layout won't be pixel-identical to Mermaid's (different dagre impl,
  different rounding). Acceptable, as long as it's clean and readable. Sequence/pie/state should be
  very close since their layout is mostly deterministic bookkeeping.
- **Text-metric drift.** Core Text results can shift slightly between macOS versions. Diagrams stay
  correct (just ±a pixel here and there). If exact stability across OS versions ever matters, ship
  precomputed font metrics tables for the default font — but don't do that up front.
- **The long tail of Mermaid syntax** is large. Stay disciplined: parse-and-skip the unsupported,
  never crash. MaiD's fallback (show the raw source) is the safety net.
- **`htmlLabels`-style rich labels** (HTML in flowchart node labels) — Mermaid supports markdown/HTML
  in labels. v1: plain text (or a tiny `**bold**`/`*italic*`/`<br/>` subset). Don't block M3 on it.
- **Package name & repo location** — confirm with the maintainer.
