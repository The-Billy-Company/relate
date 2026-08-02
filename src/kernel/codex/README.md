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
