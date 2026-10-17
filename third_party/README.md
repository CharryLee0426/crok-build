# Third-party vendored crates

This directory holds **upstream source** vendored into the repository. It is
**not** first-party application code.

## Why vendor

This directory holds in-tree third-party Rust (and similar) sources: the
mermaid layout stack that renders **untrusted model output**, the
grove-on-NFS userspace server (`nfsserve`), grove's FUSE client
(`fuser`), and the terminal emulator embedded in the macOS desktop app
(`SwiftTerm`). Vendoring gives a full audit surface, pins exact source, and
avoids crates.io yanks. Local patches and upgrade checklists live in each
crate’s `Cargo.toml` header comments (for SwiftTerm, its `Package.swift`
header) — treat those as the source of truth when re-vendoring.

## Vendored crates

| Crate | Version | License | Upstream | Full license text |
|-------|---------|---------|----------|-------------------|
| [`mermaid-to-svg`](./mermaid-to-svg/) | (path) | MIT | [warpdotdev/mermaid-to-svg](https://github.com/warpdotdev/mermaid-to-svg) | [`LICENSE`](./mermaid-to-svg/LICENSE) |
| [`dagre_rust`](./dagre_rust/) | 0.0.5 | Apache-2.0 | [r3alst/dagre-rust](https://github.com/r3alst/dagre-rust) / Warp re-vendor | [`LICENCE`](./dagre_rust/LICENCE) |
| [`graphlib_rust`](./graphlib_rust/) | 0.0.2 | Apache-2.0 | [r3alst/graphlib-rust](https://github.com/r3alst/graphlib-rust) | [`LICENCE`](./graphlib_rust/LICENCE) |
| [`ordered_hashmap`](./ordered_hashmap/) | 0.0.3 | Apache-2.0 | [r3alst/ordered-hashmap](https://github.com/r3alst/ordered-hashmap) | [`LICENCE`](./ordered_hashmap/LICENCE) |
| [`nfsserve`](./nfsserve/) | 0.11.0 | BSD-3-Clause | [huggingface/nfsserve](https://github.com/huggingface/nfsserve) | [`LICENSE`](./nfsserve/LICENSE) |
| [`fuser`](./fuser/) | 0.18.0 | MIT | [cberner/fuser](https://github.com/cberner/fuser) | [`LICENSE.md`](./fuser/LICENSE.md) |
| [`SwiftTerm`](./SwiftTerm/) | 1.20.0 | MIT | [migueldeicaza/SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | [`LICENSE`](./SwiftTerm/LICENSE) |
| [`LibrariesDev`](./LibrariesDev/) | `bfcb863` | MIT (Paper Shaders material: Apache-2.0) | [Jakubantalik/Libraries.dev](https://github.com/Jakubantalik/Libraries.dev) | [`LICENSE`](./LibrariesDev/LICENSE), [`NOTICE`](./LibrariesDev/NOTICE) |

SwiftTerm is a Swift package, used by `desktop/macOS` as a local path
dependency so the desktop app builds without fetching anything.

LibrariesDev holds the SwiftUI ports of the Libraries.dev effects (liquid
metal, border beam, thinking orbs, voice glow) that Crok Desktop's look is
built with, also a local path dependency of `desktop/macOS`. Its Metal shaders
are compiled by its `build-shaders.sh`; its `README.md` lists the local
patches.

Mermaid layout stack:

```text
xai-grok-mermaid
  └── mermaid-to-svg          (MIT)
        ├── dagre_rust        (Apache-2.0)
        │     ├── graphlib_rust
        │     └── ordered_hashmap
        └── graphlib_rust     (Apache-2.0)
              └── ordered_hashmap
```

## Notices and ancestry

- **[`NOTICE`](./NOTICE)** — short index of the crates above (names, licenses,
  upstream links, paths to full text). Prefer that file for a one-page overview.
- **[`mermaid-to-svg/THIRD_PARTY_NOTICES`](./mermaid-to-svg/THIRD_PARTY_NOTICES)** —
  additional ancestry for the SVG engine (e.g. mermaid.js, dagre.js MIT notices).

British spelling **`LICENCE`** is intentional on the Apache crates (as upstream
vendored); grepping only for `LICENSE` will miss them.

## crates.io dependencies

Normal Cargo dependencies (tokio, serde, …) are **not** under `third_party/`.
They resolve via `Cargo.lock` / crates.io. Full attribution and license texts
for the Grok CLI dependency closure are maintained in
[`THIRD-PARTY-NOTICES`](../THIRD-PARTY-NOTICES).

This directory is only for **in-tree vendored** sources.

## Upgrading

1. Read the `VENDORING NOTES` block at the top of the crate’s `Cargo.toml`
   (SwiftTerm: `Package.swift`; LibrariesDev: `README.md`).
2. Re-apply listed local patches (fmt, hermetic env, unsafe fixes, dropped bins/tests).
3. Confirm the license file still matches the declared `license =` field.
4. Refresh [`NOTICE`](./NOTICE) if versions or upstream URLs change.
