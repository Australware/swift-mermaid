# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] - 2026-08-27

### Added

- **`erDiagram` support.** Entity boxes are laid out with the vendored dagre backend, the same one
  the flowchart and class pipelines use. Covers all four symbolic cardinality tokens on both ends
  (`|o`/`o|`, `||`, `}o`/`o{`, `}|`/`|{`), identifying (`--`) and non-identifying (`..`) line
  styles, `: label`s, attribute blocks with types, `PK`/`FK`/`UK` key constraints and quoted
  comments, quoted entity names, `ENTITY[alias]` display names, `direction`, and recursive
  relationships. Cardinality is drawn in textbook crow's-foot notation: the symbol nearest the
  entity carries the cardinality, the one further along the line carries the optionality.
- **`gitGraph` support.** `commit`, `branch`, `checkout` / `switch`, `merge`, and `cherry-pick`,
  with their `id:` / `tag:` / `type:` / `order:` / `parent:` options, plus the `gitGraph LR:`
  direction header — `LR` (default), `TB`, and `BT` all render. Commits get a distinct dot shape per
  type (normal, `REVERSE`, `HIGHLIGHT`, merge, cherry-pick); cherry-pick provenance is drawn dashed
  in the source branch's colour. Branch lanes are ordered by explicit `order:` first, declaration
  order otherwise.
- **`journey` support.** `title`, `section`, and `taskName: score: actor, actor` lines. Section
  bands sit over a row of uniform task cards; each card carries a face using Mermaid's score
  mapping (above 3 smiles, below 3 frowns, exactly 3 is ambivalent) and a coloured chip per actor
  bearing their initial.
- iOS 16 as a supported platform, alongside macOS 14.
- `ThemePalette` gains `erEntityFill`, `erEntityBorder`, `erAttributeFillOdd`,
  `erAttributeFillEven`, `gitBranchColors`, `journeySectionFills`, `journeyFaceFill`, and
  `journeyFaceStroke`. Reading existing palette properties is unaffected.

### Fixed

- Class-diagram self-relationships (`A --> A : label`) no longer clip at the canvas edge. Layout
  sized the canvas from the relationship polyline alone, but a self-loop's label box sits outside
  its polyline, so the label was cut off. The label box is now part of the bounds, via a single
  `labelRect` shared between layout and renderer so the two can't drift apart.

### Notes

- `gitGraph` commits written without an explicit `id:` are drawn as bare dots. Mermaid labels them
  with a random hash, which would break this package's byte-identical-output guarantee. Write
  `commit id: "…"` when you want a label.
- `erDiagram` cardinality must use the symbolic tokens; the `one or more` word aliases are not
  recognised.

## [0.2.1] - 2026-08-21

### Added

- iOS target

## [0.2.0] - 2026-07-15

### Added

- `stateDiagram` / `stateDiagram-v2` support. State syntax is lowered into a `FlowchartAST`, so
  layout and rendering are shared with the flowchart pipeline. Concurrency (`--`) regions lay out
  together, without a divider.

## [0.1.0] - 2026-05-12

### Added

- Initial release: a pure-Swift Mermaid renderer for Apple platforms, with no JavaScript engine,
  no `WKWebView`, and no network access.
- Diagram types: `flowchart` / `graph`, `sequenceDiagram`, `pie`, `classDiagram` /
  `classDiagram-v2`, and `architecture-beta` (built-in icons only).
- Three output paths off one `MermaidScene` geometry + style IR: SVG (presentation attributes, no
  `<style>` block), `CGImage`, and single-page vector PDF.
- Two interchangeable flowchart layout backends: the vendored `MermaidLayoutDagre` (a copy of
  lukilabs/dagre-swift, the default) and a hand-rolled Sugiyama-style fallback, selectable per call
  or globally with `MERMAID_DAGRE`.
- `default` (light) and `dark` theme palettes, with in-source `%%{init}%%` and YAML frontmatter
  `theme` honoured when the caller passes `.default`.
- Determinism as a hard requirement: the same `(source, theme, OS)` produces byte-identical SVG.

[0.3.0]: https://github.com/Australware/swift-mermaid/compare/0.2.1...HEAD
[0.2.1]: https://github.com/Australware/swift-mermaid/compare/0.2.0...0.2.1
[0.2.0]: https://github.com/Australware/swift-mermaid/compare/0.1.0...0.2.0
[0.1.0]: https://github.com/Australware/swift-mermaid/releases/tag/0.1.0
