# `src/kernel/anatomy/` — how source text is structured

Source-structure geometry with no product opinion. Not set algebra (that is
[`../compose/`](../compose/)) and not ranking policy (that is
`irregex/src/kernel/rank/`) — this package answers _"where are the comments,
identifiers, and function extents?"_ so every face can agree.

Extracted from the old `compose/` grab-bag because none of these files was
set algebra: their consumers cross all three faces (gist `--in-comments`,
relate’s frag units, blast’s radius).

| File | Job |
| ---- | --- |
| `token.zig` | Source-token vocabulary — `isIdentStart` / `isIdentByte` / `nextIdent` / `wordRun`. Kinship silhouettes import this so token boundaries cannot drift between anatomy’s dependency rows and structure fingerprints |
| `lexspan.zig` (in irregex) | Comment / code / string span lexer, reached as `irregex.inner.lexspan` |
| `spans.zig` | Function / context geometry (frag index, blast, regions) |
| `leans.zig` | Identifier-dependency resolution (blast’s dependency tier); keyword stoplists stay private |

Pure kernel: feed it bytes, get geometry. Walk policy and `-t` tables live in
irregex's `corpus/scope/`.
