# relate

The similarity engine - compression-as-search. Regex answers "where is
this exact pattern?"; relate answers the two questions regex structurally
cannot: `similar` (what is near THIS one?) and `echoes` (what repeats
among ALL of them?), plus `pack` (the cheapest set of files that jointly
explains a text), `quote` (rewrite a snippet as priced corpus
quotations), and `patterns` (N patterns, one walk, exact attribution).

The machinery is information-theoretic, not embedding-based: LZJD
kinship sketches, corpus-priced fingerprints, a Ziv-Merhav cross-parse,
and an FM-index codex (suffix sort via vendored libsais 2.10.2). Every
answer carries a calibrated grade, so background reading never
masquerades as a hit.

This is the engine, not the binary. The `relate` CLI ships from
[`gist`](../gist), the product chassis; this package owns the math, the
persisted artifacts, and the verb implementations behind it.

## Layout

- `src/kernel/kinship/` - metric · cluster · recall
- `src/kernel/anatomy/` - structure silhouettes (the "shapes" channel)
- `src/kernel/codex/` - the compression codebook + FM-index (vendored libsais)
- `src/kernel/compose/` - the composed queries: blast radius,
  provenance, `--matching` candidates, family, regions (the engines the
  [`blast`](../blast) face drives)
- `src/corpus/index/{atlas,frag,shelf}/` - the persisted artifacts:
  file kinship atlas, function fragment atlas, the codex shelf
- `src/exec/retrieval/` - text-probe retrieval by coding gain
- `src/exec/session/warm/` - the warm tier: fold changed files into a
  persisted atlas, byte-identical to a cold rebuild
- `src/surface/face/relate/` - the verb surface the CLI drives

## Build and test

Zig 0.16, no network; libsais builds from `vendor/libsais/` (the zon
entry is a `.lazy` url + hash pin for provenance only).

```bash
zig build check       # compile everything, run nothing
zig build test        # the unit suite
zig build coverage    # per-function coverage
```

## Using it

```zig
// build.zig.zon
.relate = .{ .path = "../relate" },  // dev: sibling checkout
// releases pin url + hash
```

Depends on [`irregex`](../irregex) - the library - for the corpus walk,
the pattern engines behind `--matching`, and the shared primitives.
Architecture is machine-checked by `contract/relate.ward`.

## Provenance

Extracted from `billy/libs/kernels/irregex` (cut at billy@ce430bbaab,
PLAN v5 split). The engine was born as the kernel's kinship/codex tiers
and split out along the tuning boundary: everything priced against the
same corpus statistics stays here, together.
