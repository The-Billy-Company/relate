# relate

The similarity engine — compression-as-search. Two questions: `similar`
(what is near THIS one?) and `echoes` (what repeats among ALL of them?),
plus `pack` / `quote` / `patterns`. LZJD kinship sketches, corpus-priced
fingerprints, Ziv–Merhav cross-parse, and the atlas / frag / shelf
artifacts they persist to.

Extracted from `billy/libs/kernels/irregex` (cut from billy@ce430bbaab,
PLAN v5 split). Depends on [`irregex`](../irregex) — the library — as a
sibling checkout during development. The `relate` binary ships from
[`gist`](../gist), the CLI chassis.

Status: extraction snapshot — build wiring (module-qualified imports,
build.zig) is in progress.

## Layout

- `src/kernel/kinship/` — metric · cluster · recall
- `src/kernel/anatomy/` — structure silhouettes
- `src/kernel/codex/` — the compression codebook (+ vendored libsais)
- `src/corpus/index/{atlas,frag,shelf}/` — persisted artifacts
- `src/exec/retrieval/` — text-probe retrieval
- `src/surface/face/relate/` — the verb surface
