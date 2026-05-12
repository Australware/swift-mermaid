# Third-party notices

`swift-mermaid` bundles ("vendors") a copy of the following third-party code. Each is under a
license compatible with this project's MIT license, and the original license text and copyright
notices are preserved alongside the vendored sources.

## SwiftDagre (vendored)

- **Location in this repo:** [`Vendor/MermaidLayoutDagre/`](Vendor/MermaidLayoutDagre/)
- **Upstream:** https://github.com/lukilabs/dagre-swift
- **Pinned to:** commit `92efb78` (the single commit on `main` as of 2026-05-11)
- **License:** MIT — see [`Vendor/MermaidLayoutDagre/LICENSE`](Vendor/MermaidLayoutDagre/LICENSE)
- **Copyright:** Copyright (c) 2026 Luki Labs
- **What it is:** A Swift port of `@dagrejs/dagre`, used as the default layout backend for
  flowchart-family diagrams. The SPM module was renamed from `SwiftDagre` to `MermaidLayoutDagre`
  to avoid a collision if a host app also depends on `SwiftDagre` directly; the Swift sources are
  otherwise unmodified. It is *not* exposed as a library product, so consumers of `swift-mermaid`
  cannot couple to it.
- **Why vendored rather than depended-on:** upstream is currently a single-commit, untagged
  repository. See [`Vendor/MermaidLayoutDagre/VENDORED.md`](Vendor/MermaidLayoutDagre/VENDORED.md).

`SwiftDagre` is itself a port of [`@dagrejs/dagre`](https://github.com/dagrejs/dagre) (MIT,
Copyright (c) 2013 Chris Pettitt) and [`graphlib`](https://github.com/dagrejs/graphlib) (MIT).
