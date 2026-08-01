---
doc_radar:
  counts:
    - description: "cento quoter — cento (+ test)"
      glob: src/kernel/codex/*.zig
      unit: files
      equals: 2
  sentinels:
    - description: "this package's root re-exports only the cento"
      file: src/root.zig
      contains:
        - 'pub const cento = @import("kernel/codex/cento.zig");'
    - description: "the FM-index lives in the irregex library"
      file: ../irregex/src/root.zig
      contains:
        - 'pub const index = @import("kernel/codex/codex.zig");'
        - 'pub const shelf = @import("corpus/index/shelf/shelf.zig");'
    - file: "../gist/src/surface/face/relate/repertoire.zig"
      contains:
        - '"quote"'
---

# `src/kernel/codex/` — the corpus-quotation parse

The Ziv–Merhav cross-parse (`cento.zig`) that rewrites a query as maximal
verbatim quotations from a corpus, priced in bits. It stands on the FM-index
in the irregex library (`@import("irregex").codex.index`); the index itself
and its persisted shelf moved there so an index tier sits with the other
index tiers.

| file | rôle |
| ---- | ---- |
| `cento.zig` | Ziv–Merhav cross-parse + Shannon phrase pricing |
| `cento_test.zig` | parse ≡ greedy oracle; native < kindred < foreign bits |

Product face: `relate quote <text>` (and `irregex provenance`, which re-checks
each attributed phrase against live bytes). Build the shelf first with
`relate index --shelf` or `gist codex build`.
