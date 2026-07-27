---
doc_radar:
  counts:
    - description: "the codex package — seven Zig source files"
      glob: libs/kernels/irregex/src/corpus/index/codex/*.zig
      unit: files
      equals: 7
  sentinels:
    - file: "libs/kernels/irregex/src/root.zig"
      contains:
        - "index/codex/sais.zig"
        - "index/codex/cento.zig"
        - "index/codex/shelf.zig"
        - "index/codex/codex_test.zig"
    - file: "libs/kernels/irregex/build.zig"
      contains:
        - "codex-scale"
        - "vendor/libsais/src"
    - file: "libs/kernels/irregex/src/surface/face/gist/main.zig"
      contains:
        - '"codex"'
    - file: "libs/kernels/irregex/src/surface/face/relate/repertoire.zig"
      contains:
        - '"quote"'
    - file: "libs/kernels/irregex/src/corpus/index/codex/sais.zig"
      contains:
        - "induced sorting"
        - "extern fn libsais"
    - file: "libs/kernels/irregex/src/corpus/index/codex/rrr.zig"
      contains:
        - "Raman–Raman–Rao"
---

# codex — the compressed self-index

_What if the index over a corpus **was** the compression of that corpus?_

That is not a metaphor; it is a theorem, and this module is its
implementation. A codex holds a text at entropy-bound size while answering
exact substring queries at the information-theoretic time floor — and can
regenerate the text it replaced, byte for byte, from itself alone. The book
is its own index; the index is the book.

The idea arrived as a Shannon claim: text is a number stream; if the set of
information in that stream is already indexed, lookup should run at the
lowest time complexity physically possible — and it should be _provable_
that the index can be a compression. Rung 1 proved it with a naive-wavelet
prototype (`.local/spikes/shannon-self-index/` — prefix-doubling SA, plain
bitvectors, 5.50 bits/char); this module is the graduation: the O(n) suffix
array, entropy-coded bitvectors that cut space 2.8×, locate support, an
adversarial oracle suite, and the at-scale proof below.

## The mathematics

1. **Shannon (1948).** No lossless code beats the source entropy; a symbol's
   optimal cost is −log₂ p bits. That fixes the _space_ floor.
2. **The time floor is Ω(m), not Ω(n).** Any correct count of pattern P must
   read all m = |P| bytes of P — an unread byte can flip the answer — but
   nothing forces dependence on corpus size n. "Lowest time complexity
   physically possible" means linear in the question, constant in the world.
3. **Burrows–Wheeler (1994) + Manzini (JACM 2001).** The BWT is a pure
   permutation — zero information gained or lost — that sorts each symbol by
   its right context. A zeroth-order coder over the BWT is therefore bounded
   by the _k-th order_ entropy nH_k of the original text.
4. **FM-index (Ferragina & Manzini, FOCS 2000).** Backward search answers
   count(P) with 2m rank queries over the BWT. A Huffman-shaped wavelet tree
   (Grossi–Gupta–Vitter, SODA 2003) serves each rank in O(1) per code bit
   while storing exactly Σ freq(c)·len(c) bits; with RRR-compressed
   bitvectors (Raman–Raman–Rao, SODA 2002) every level shrinks to its own
   zeroth-order entropy, and the whole tree lands at nH_k + o(n log σ) with
   no explicit context modeling — implicit compression boosting
   (Mäkinen & Navarro, SPIRE 2007).
5. **Self-index.** LF-mapping walks the BWT backwards through the wavelet
   tree alone: `restore()` re-emits the original text. The structure is a
   decodable code in Shannon's exact sense — the index **is** a compression.

## The layers

| file             | structure                                           | rôle                                                                |
| ---------------- | --------------------------------------------------- | ------------------------------------------------------------------- |
| `sais.zig`       | SA-IS suffix array (Nong–Zhang–Chan 2009)           | O(n) construction — the sentinel seam over vendored libsais; build-time only, freed |
| `rrr.zig`        | Plain + RRR bitvectors behind one `Bits` seam       | O(1) rank at entropy space; `adopt` keeps the smaller per vector    |
| `wavelet.zig`    | canonical-Huffman wavelet tree, σ ≤ 4096            | occ/access in one descent — the rank oracle                         |
| `codex.zig`      | the `Codex`: build → count/find/restore + save/load | the product surface; text/SA/BWT all freed after build              |
| `cento.zig`      | Ziv–Merhav cross-parse + Shannon phrase pricing     | corpus-global relatedness: quote a query out of the corpus, in bits |
| `shelf.zig`      | multi-document corpus behind one codex              | doc catalog + offsets + freshness anchor; count/tally per file      |
| `codex_test.zig` | differential + property suite                       | every layer vs a naive oracle; nothing self-referential             |

Bytes are lifted to u16 symbols c+1 under sentinel 0, so all 256 byte values
— including NUL — are ordinary, searchable content.

```zig
var idx = try codex.Codex.build(gpa, text, .{ .sample_rate = 32 });
defer idx.deinit(gpa);
idx.count("pub fn ");            // occurrences, O(m) — corpus size irrelevant
try idx.find(gpa, "pub fn ");    // ascending match positions, O(m + occ·rate)
try idx.restore(gpa);            // the entire original text, from the index alone
```

`Options.encoding` picks the posture: `.adopt_min` (entropy space — the
nH_k rung) or `.plain_only` (~2× space, ~5× faster ranks). Same answers
either way; `sample_rate = 0` drops locate for a count/restore-only index.

## Persistence & the two tiers riding it

`Codex.save`/`load` is a versioned wire format, sealed with the shared
[`signet`](../../../kernel/primitives/signet.zig), that stores only **primary** data (bitvector payloads, Huffman code lengths, tree
topology, samples); everything derived — rank samples, canonical codes,
superblock cursors — is rebuilt through the layers' validating constructors
at load, so a mangled blob fails closed with `error.Corrupt` instead of
answering wrong. Load is ~0.6% of build (29ms vs 4.5s at 128MB).

`shelf.zig` lifts one codex over a multi-document corpus (newline-sentinel
concatenation, doc catalog, per-doc offsets, its own T3-style freshness
anchor) and is what the product verbs persist (`codex.shelf`):

- **`gist codex build | count <text> | tally <text> | status`** — the exact
  existence/count tier beside the trigram index. The trigram tier nominates
  _candidate_ files (false positives possible; a read verifies); the codex
  _answers_: `count == 0` with a clean freshness walk is a **proof of
  absence** across the corpus, no file opened. On the live repo (20,952
  files, 209MB → one 76MB shelf): ~100ms cold including load, exit code
  0/1 = present/absent, per-file `tally` heaviest-first.
- **`relate quote <text>`** — the corpus-global relate tier (`cento.zig`):
  rewrite a query as maximal verbatim quotations from the _whole corpus_
  (Ziv–Merhav cross-parse via backward search, O(|text|) — corpus size never
  appears), price it in bits, and attribute each phrase to an exemplar file.
  bits/byte is the corpus-conditional compression rate: ~0.9 for prose the
  corpus knows, ~7+ for foreign bytes.

## Proof, not vibes

- **Correctness** — `codex_test.zig` checks SA-IS against a comparison-sort
  oracle (degenerate/Fibonacci/binary/all-256-bytes plus seeded random
  sweeps) and, at a megabyte where the construction changes strategy and a
  naive sort cannot follow, against a linear permutation-and-adjacency oracle;
  RRR rank/get at _every_ position across densities and block
  boundaries, wavelet occ/access against literal scans, and end-to-end
  count/find/restore against `std.mem` scans under a property-fuzz loop with
  mutated patterns.
- **Scale** — `zig build codex-scale` (harness: `bench/codex/scale.zig`,
  driver: `bench/codex/race.sh`) runs the ladder over ~187MB of real repo
  source: space vs measured H₀/H₂ and gzip/bzip2/zstd/xz on identical
  slices, count latency across sizes (flat in n), find cost at the sampling
  stride, a byte-exact whole-slice restore, save→load→re-verify persistence
  at every size, and the cross-parse priced over native vs foreign queries —
  with every timed count re-verified against a naive scan first (the
  reloaded index against the same oracle).

## Measured (2026-07-18, M-series dev box, 187MB real-source corpus)

Space — bits per character, `.adopt_min`, sample_rate 32 (`locate` rows add a
constant ~1.3 bits/char; drop them with `sample_rate = 0`):

| n     | count-index (tree) | + locate | H₀   | H₂   | gzip -9 | bzip2 -9 | xz -9 |
| ----- | ------------------ | -------- | ---- | ---- | ------- | -------- | ----- |
| 1MB   | 2.71               | 4.05     | 4.91 | 2.49 | 1.92    | 1.54     | 1.54  |
| 16MB  | 2.26               | 3.58     | 5.58 | 2.77 | 2.13    | 1.28     | 1.08  |
| 128MB | **1.95**           | 3.27     | 5.28 | 2.90 | 1.63    | 1.20     | 1.03  |

The count-index lands _under the corpus's own measured H₂_ (RRR's implicit
boosting captures deeper context than k=2) — a 4.1× compression of the raw
bytes, within 1.2× of gzip -9 and 1.6× of bzip2, from a structure that
_answers queries_; the compressors answer nothing. The naive-wavelet rung
without RRR measured 5.50 bits/char on the same bytes (2.8× worse): the
spike ladder is `.local/spikes/shannon-self-index/`.

Time — count(P), m=16, 200 patterns, min-of-3, each first verified against
a naive scan:

| n     | count      | naive scan | speedup    |
| ----- | ---------- | ---------- | ---------- |
| 1MB   | 10.1µs     | 0.34ms     | 34×        |
| 16MB  | 12.1µs     | 4.37ms     | 360×       |
| 128MB | **10.8µs** | 40.1ms     | **3,727×** |

128× the corpus: count is _flat_ (cache noise only); the scan pays 118×. The
speedup grows unboundedly with corpus size — that is the Ω(m)-floor signature,
not a constant-factor win. `.plain_only` trades ~2× space for ~6× faster
ranks (~1.7µs at m=16) when the corpus is small enough to spend it.
Whole-corpus `restore()` verifies byte-exact at every size.

### Build cost, and what still floors it (2026-07-26)

Build was SA-IS-bound, and the sort is now vendored libsais rather than a
hand-rolled induced sort. Per-phase wall time, min of 3, on real repo source:

| n     | suffix sort | BWT + histogram | wavelet + RRR | locate | build      |
| ----- | ----------- | --------------- | ------------- | ------ | ---------- |
| 32MB  | 0.44s       | 0.12s           | 0.44s         | 0.04s  | **1.03s**  |
| 128MB | 2.02s       | 0.61s           | 1.78s         | 0.14s  | **4.55s**  |
| 200MB | 3.23s       | 1.13s           | 2.41s         | 0.22s  | **6.98s**  |

The retired implementation sorted the same 200MB in 10.58s, so the swap is
**3.3× on the sort and 2.1× on the whole build** — and it is byte-identical:
the two constructions were run against each other over the full corpus and
agreed on all 209,715,201 rows. The adapter costs nothing measurable, because
the sentinel row is a single stored word and libsais sorts straight into the
tail of the same allocation.

The interesting number is the one that _didn't_ move. The sort fell from 74%
of the build to 46%, which means a **free** suffix sort would still leave 3.8s
at 200MB — and the shelf's persist step adds ~2s of concatenation and
serialization on top. So the sort is no longer what keeps `relate index
--shelf` opt-in; at this corpus size (21k files, 208MiB) the shelf is a ~9s
artifact whose floor is now the wavelet/RRR construction and the 79MiB
serialize, and no further work on suffix sorting can reach a default-on
budget. That is a claim about where to look next, measured rather than
assumed: `.local/spikes/libsais-eval/phases.zig` times each phase and prints
the sort-free ceiling beside the total.

Persistence — save/load of the full index, loaded answers re-verified
against the naive oracle:

| n     | blob   | save   | load       | load / build |
| ----- | ------ | ------ | ---------- | ------------ |
| 1MB   | 0.45MB | 0.2ms  | 0.3ms      | 0.6%         |
| 16MB  | 6.4MB  | 2.7ms  | 3.8ms      | 0.4%         |
| 128MB | 46MB   | 18.5ms | **28.9ms** | **0.3%**     |

Cross-parse (`cento.zig`) — 256-byte queries, 64 rounds per size, native
(verbatim corpus slices) vs foreign (uniform random bytes), price identical
across save/load:

| n     | native bits/byte | foreign bits/byte | separation | parse ns/byte |
| ----- | ---------------- | ----------------- | ---------- | ------------- |
| 1MB   | 0.14             | 12.65             | 88×        | 765           |
| 16MB  | 0.15             | 14.45             | 94×        | 1,140         |
| 128MB | 0.17             | **15.16**         | **91×**    | 1,510         |

The gap _is_ the Ziv–Merhav relative-entropy estimate: text the corpus has
seen costs ~0.15 bits/byte to quote; bytes it has never seen cost ~100× more.
Parse time is O(|query|) — the mild ns/byte growth is cache pressure from the
larger tree, not an n-dependence.

## The tiers that landed (the irregex arc)

The trigram index (`corpus/index/trigrams/`) is a lossy _filter_: it may name
false candidate files and needs the corpus resident to verify. The codex is
the opposite pole: zero false positives, corpus deletable, count without I/O.
Both graduation rungs shipped (see “Persistence & the two tiers” above):
`gist codex` is the existence/count tier over the persisted shelf, and
`relate quote` is the corpus-global matching-statistics tier — zipper's
Ziv–Merhav cross-parse priced against the _whole corpus at once_
(Ohlebusch–Gog–Kügel, SPIRE 2010) instead of per-doc automata. One
entropy-compressed structure under both engines.

## References

Shannon 1948 · Burrows & Wheeler SRC-124 1994 · Ferragina & Manzini FOCS
2000 · Manzini JACM 2001 · Raman, Raman & Rao SODA 2002 · Grossi, Gupta &
Vitter SODA 2003 · Nong, Zhang & Chan DCC 2009 · Mäkinen & Navarro SPIRE 2007
· Navarro & Mäkinen, _Compressed Full-Text Indexes_, ACM Surveys 2007 ·
Ohlebusch, Gog & Kügel SPIRE 2010 · Grebnov, _libsais_ 2.10.2 (the shipped
induced sort — pinned under [`vendor/libsais/`](../../../../vendor/libsais/)).
