# Relate — the complete evidence story

Every layer is tested where its failure would be invisible elsewhere.
Soundness gates are **fail-closed**: a violation exits non-zero, and the
fix is the engine, never the assertion (never weaken an assertion to go green).

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
zig build test
```

---

## 2. Multi-pattern exactness — `bench/races/multipattern.sh`

Contract: a `PatternSet` answer equals N independent runs bit-for-bit, with
the prefilter gate forced **both** on and off. Throughput claim (~6× vs
sequential `gist -l` on a 10-pattern slate) is subordinate
to that equality.

---

## 3. Warm atlas byte-identity

`similar` / `echoes` (incl. `--as copies` / `--shape families`):

- missing / corrupt atlas → live build;
- `--no-index` → live build;
- warm path folds files changed since the anchor, re-sketches from live
  bytes, gates deletions;
- emitted answer must match a cold rebuild (documented in
  [`src/corpus/index/atlas/README.md`](../../src/corpus/index/atlas/README.md) and the
  relate CLI README). Warm speed depends on atlas size, freshness churn, and
  scope; the atlas is an accelerator, never a latency guarantee or authority.

Text-probe `similar` / `pack` reuse Gist's persisted trigram codebook, fold changed files
through the shared freshness overlay, and retain the live fingerprint lexicon
as the missing-index fallback. Their CLI gate must include a three-byte
positive, a descriptive query, a scoped query, and a multi-file pack.

---

## 4. Compression vs embeddings — `bench/conformance/relate/` (`zig build relate-knn`)

Runs the **real** engine as a k-NN classifier over a labeled manifest:

| lane     | machinery                                                       |
| -------- | --------------------------------------------------------------- |
| `zipper` | per-train-doc suffix automaton; test priced by exact Ziv–Merhav |
| `sketch` | LZJD dictionary distance                                        |
| `pivot`  | compression "embeddings" via FastMap/Lipschitz pivot costs      |

Head-to-head vs gzip-kNN and a static embedding model. Documented finding:
embeddings win semantic retrieval; compression keeps model-free cold-start
plus the kinship/dup/pack/quote jobs. That verdict came out of an early
prototype race whose write-up never shipped with this repo; the summary above
is what survived it, and the harness below is how you measure it again.

```bash
zig build lab -Doptimize=ReleaseFast          # the measurement lanes are off the default install
zig-out/bin/relate-knn <dataset> --method zipper --k 3
```

`<dataset>` is a directory holding a `manifest.tsv` of `<split>\t<label_id>\t<relpath>`
rows, with every doc pre-truncated to one byte cap so all lanes price identical
bytes. The harness ships; the driver that built that manifest did not, so
re-running the race means writing the driver and picking a labeled corpus first.

---

## 5. Echo / structure graduation eval

The historical labeled lint-registry run found strong top-10 echo precision,
but no checked-in labeled artifact currently ratchets that number; treat it as
an observation, not a product guarantee. Structure has **no** clean absolute
dup threshold across corpora (measured overlap of family-max vs cross-min at
every winnow setting) — that is why `echoes` ranks a _gap_, while `echoes --as copies`
verifies byte-near candidates.

---

## 6. Codex / quote scale

`zig build codex-scale` and the tables in
[`src/kernel/codex/README.md`](../../src/kernel/codex/README.md): known vs
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
