# Relate — the complete evidence story

Every layer is tested where its failure would be invisible elsewhere.
Soundness gates are **fail-closed**: a violation exits non-zero, and the
fix is the engine, never the assertion (sins.mdc Sin #2).

The properties that matter:

1. **Exactness** — `patterns` ≡ N independent single-pattern runs;
   zipper/lexicon answers are deterministic (ties never swap).
2. **Atlas identity** — warm path ≡ `--no-index` live rebuild (byte-
   identical rows), with changed files folded in and deletions gated out.
3. **Honest scope** — embeddings win semantic retrieval when measured;
   compression wins the kinship / dup / pack / quote lane — never paper
   over the boundary.
4. **Shelf honesty** — `quote` reports freshness; it does not pretend a
   stale shelf is corpus-global.

---

## 1. Kernel unit tests (ride `zig build test`)

| module                             | pins                                                                                                        |
| ---------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| `sketch_test.zig`                  | LZJD build/distance, noise floor, Jaccard estimator sanity                                                  |
| `silhouette_test.zig`              | renamed-twin structure distance → ~0; keyword survival; winnow guarantee                                    |
| `lexicon_test.zig`                 | compression-as-search retrieves; LZ78-boundary failure that forced winnowing; IDF pricing (boilerplate → 0) |
| `zipper` (via lexicon tests + knn) | ΔAb vs cold baseline; `min_factor` discrimination                                                           |
| atlas / codex suites               | round-trip, stale/missing fallback, restore/count oracles                                                   |

```bash
cd libs/kernels/irregex && zig build test
```

---

## 2. Multi-pattern exactness — `bench/races/multipattern.sh`

Contract: a `PatternSet` answer equals N independent runs bit-for-bit, with
the prefilter gate forced **both** on and off. Throughput claim (~6× vs
sequential `gist -l` on a relocator-shaped 10-pattern slate) is subordinate
to that equality.

---

## 3. Warm atlas byte-identity

`similar` / `dups` / `clusters` / `echoes`:

- missing / corrupt atlas → live build;
- `--no-index` → live build;
- warm path folds files changed since the anchor, re-sketches from live
  bytes, gates deletions;
- emitted answer must match a cold rebuild (documented in
  [`src/index/atlas/README.md`](../../src/index/atlas/README.md) and the
  relate CLI README). Warm speed depends on atlas size, freshness churn, and
  scope; the atlas is an accelerator, never a latency guarantee or authority.

`search` / `pack` reuse Gist's persisted trigram codebook, fold changed files
through the shared freshness overlay, and retain the live fingerprint lexicon
as the missing-index fallback. Their CLI gate must include a three-byte
positive, a descriptive query, a scoped query, and a multi-file pack.

---

## 4. Compression vs embeddings — `bench/relate/` (`zig build relate-knn`)

Runs the **real** engine as a k-NN classifier over a labeled manifest:

| lane     | machinery                                                       |
| -------- | --------------------------------------------------------------- |
| `zipper` | per-train-doc suffix automaton; test priced by exact Ziv–Merhav |
| `sketch` | LZJD dictionary distance                                        |
| `pivot`  | compression "embeddings" via FastMap/Lipschitz pivot costs      |

Head-to-head vs gzip-kNN and a static embedding model. Documented finding:
embeddings win semantic retrieval; compression keeps model-free cold-start
plus the kinship/dup/pack/quote jobs. Full write-up:
`.local/spikes/compression-vs-embeddings/SPIKE.md` (machine-local spike;
this TESTING file is the durable pointer).

```bash
cd libs/kernels/irregex
zig build -Doptimize=ReleaseFast
zig-out/bin/relate-knn <dataset> --method zipper --k 3
```

---

## 5. Echo / structure graduation eval

The historical labeled lint-registry run found strong top-10 echo precision,
but no checked-in labeled artifact currently ratchets that number; treat it as
an observation, not a product guarantee. Structure has **no** clean absolute
dup threshold across corpora (measured overlap of family-max vs cross-min at
every winnow setting) — that is why `echoes` ranks a _gap_, while `dups`
verifies byte-near candidates.

---

## 6. Codex / quote scale

`zig build codex-scale` and the tables in
[`src/index/codex/README.md`](../../src/index/codex/README.md): known vs
foreign bits/byte separation, O(|text|) cross-parse after the shelf is loaded,
and restore byte-identity. End-to-end `quote` also pays shelf loading and
filesystem freshness work; `codex-scale` records rather than ratchets latency
and separation. `quote` without a shelf fails loud (asks for `relate index
--shelf`).

---

## 7. What a failure means

| failure class                          | correct fix                                              |
| -------------------------------------- | -------------------------------------------------------- |
| `patterns` ≠ N solo runs               | fix batch/loom — never weaken the equality gate          |
| warm ≠ `--no-index`                    | fix atlas fold-in / deletion gating                      |
| zipper ranks noise on short queries    | do not reintroduce LZ78 phrase boundaries in the lexicon |
| "relate beats embeddings at semantics" | false — update prose; keep the knn harness               |
| `quote` hides shelf staleness          | report on stderr like `gist codex`                       |

Authorities: `relate --schema`, this inventory, and the harness artifacts.
Prose follows them.
