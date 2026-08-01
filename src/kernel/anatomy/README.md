---
doc_radar:
  counts:
    - description: "anatomy keeps its four source-geometry modules"
      glob: src/kernel/anatomy/*.zig
      unit: files
      equals: 4
  sentinels:
    - description: "token owns the shared identifier vocabulary kinship silhouettes import"
      file: src/kernel/anatomy/token.zig
      contains: ["pub fn isIdentStart", "pub fn isIdentByte", "pub fn nextIdent"]
---

# `src/kernel/anatomy/` — how source text is structured

Source-structure geometry with no product opinion. Not set algebra (that is
[`../compose/`](../compose/)) and not ranking policy (that is
`irregex/src/kernel/rank/`) — this package answers _"where are the comments,
identifiers, and function extents?"_ so every face can agree.

Extracted from the old `compose/` grab-bag because none of these files was
set algebra: their consumers cross all three faces (gist `--in-comments`,
relate’s frag units, irregex blast).

| File | Job |
| ---- | --- |
| `token.zig` | Source-token vocabulary — `isIdentStart` / `isIdentByte` / `nextIdent` / `wordRun`. Kinship silhouettes import this so token boundaries cannot drift between anatomy’s dependency rows and structure fingerprints |
| `lexspan.zig` | Comment / code / string span lexer |
| `spans.zig` | Function / context geometry (frag index, blast, regions) |
| `leans.zig` | Identifier-dependency resolution (blast’s dependency tier); keyword stoplists stay private |

Pure kernel: feed it bytes, get geometry. Walk policy and `-t` tables live in
`corpus/scope/`.
