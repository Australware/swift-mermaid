# MermaidLayoutDagre — vendored SwiftDagre

This target is a vendored copy of [`lukilabs/dagre-swift`](https://github.com/lukilabs/dagre-swift)
@ commit **92efb78** (the single commit on `main` as of 2026-05-11), used as the flowchart layout
backend for `swift-mermaid`. MIT-licensed; the original `LICENSE` file is preserved next to this README
and the upstream README is preserved as `UPSTREAM-README.md`.

The SPM module name has been changed from `SwiftDagre` to `MermaidLayoutDagre` so it doesn't
conflict if a host app also adds `SwiftDagre` directly. The Swift sources are otherwise unmodified.

It's deliberately not exposed as a library product — `Package.swift` only ships the `Mermaid`
product, so consumers cannot accidentally couple to dagre's API. 
