# Relate — prior art (what we actually used)

**Claim under review.** Compression-as-search over a live code tree: measure
how cheaply one byte body describes another (or a query), then surface
kinship, retrieval, anti-redundant context packs, and corpus quotations —
without parsers, language lists, or embedding models.

**Verdict:** COMPOSITION. Every mathematical ingredient is cited prior art;
the product seam (lexicon nominates → zipper decides; dual-channel echoes;
submodular pack receipts; warm atlas with byte-identical live fallback) is
hand-rolled. This file is the paper trail of **citations that appear in the
shipped code and READMEs**, plus neighboring families we measured and left.

The precise claim and non-claims live in `CLAIM.md`.

---

## 0. Where to start (the spark)

### Language Trees and Zipping (the paper)

[Benedetto, Caglioti & Loreto (2002)](#r-bcl2002) — _Language Trees and
Zipping_ (Phys. Rev. Lett. **88**, 048702). They recover language phylogeny
— and author identity — from compressor-defined relative entropy alone:
append a snippet of B to A, compress, compare to compressing A alone. Texts
whose "languages" match cross-compress; unrelated ones do not. No
linguistics table. That is the idea relate exists to productize for coding
agents.

Cited at the point of use in:

- `src/kernel/kinship/metric/sketch.zig` (LZJD as the fast successor to
  gzip-per-pair NCD)
- `src/kernel/kinship/recall/lexicon.zig` / `zipper.zig` (asymmetric "which docs
  describe this query cheaply?")
- `src/surface/face/relate/README.md` § Prior art

---

## 1. Kinship sketches (symmetric distance)

| citation                                  | role in relate                                                                        | code                                                               |
| ----------------------------------------- | ------------------------------------------------------------------------------------- | ------------------------------------------------------------------ |
| [Benedetto et al. 2002](#r-bcl2002)       | relative-entropy distance signal                                                      | conceptual root                                                    |
| [Raff & Nicholas 2017](#r-lzjd) (LZJD)    | LZ78 phrase-dictionary Jaccard — NCD-class accuracy without a compressor run per pair | `sketch.zig`                                                       |
| [Beyer et al. 2007](#r-kmv) (KMV)         | unbiased Jaccard from the k smallest of the union; mergeable flat `[k]u64`            | `sketch.zig`, `silhouette.zig`                                     |
| [Schleimer et al. 2003](#r-winnow) (MOSS) | local fingerprinting with shared-substring guarantee                                  | `silhouette.zig` (token shingles); also `lexicon.zig` (byte grams) |
| [Roy & Cordy 2007](#r-roy-cordy)          | Type-2 = renamed twins — names the failure mode byte-LZJD misses                      | `silhouette.zig` header                                            |

**Difference from running gzip.** Benedetto et al. literally compress; LZJD
compares phrase _dictionaries_ as sets and min-hashes them. Relate's
`distance = 1 − Jaccard` over k=128 phrase hashes is that estimator
(~1 KiB/file in the kinship atlas).

**Structure channel.** Normalize identifiers→I, numbers→N, strings→S, drop
comments/whitespace, keep a pan-language keyword union, then winnow token
shingles into a k=256 KMV silhouette. Same estimator, different set — so a
renamed twin reads ~0 on structure while bytes read far. Measured: normalize-
then-LZ78 _hurt_ twin@1; positional shingles helped (`silhouette.zig` header).

---

## 2. Compression retrieval (asymmetric search / pack)

| citation                            | role in relate                                                                      | code                        |
| ----------------------------------- | ----------------------------------------------------------------------------------- | --------------------------- |
| [Benedetto et al. 2002](#r-bcl2002) | "which docs would describe this query cheaply?"                                     | `lexicon.zig`, `zipper.zig` |
| [Schleimer et al. 2003](#r-winnow)  | boundary-free fingerprints (LZ78 phrase boundaries lost short queries — measured)   | `lexicon.zig`               |
| [Shannon 1948](#r-shannon)          | −log₂(df/N) prices fingerprints at corpus information content; boilerplate → 0 bits | `lexicon.zig`               |
| [Blumer et al. 1985](#r-blumer)     | minimal DFA of all substrings; ideal LZ77 match-finder                              | `zipper.zig`                |
| [Ziv & Merhav 1993](#r-zm1993)      | greedy longest factors of q against a reference; factor count ≈ cross-entropy       | `zipper.zig`, `cento.zig`   |

**Pipeline.** Lexicon nominates (cheap, no doc bytes); zipper decides with
real code lengths (flag + position + length for copies; 9 bits/byte for
unseen literals) — Benedetto's ΔAb **exactly**, with no gzip subprocess.
`min_factor = 4` matches the discrimination collapse every real coder hits
on 1–3 byte matches.

**Pack.** Coverage over priced fingerprints is submodular → greedy
([Nemhauser–Wolsey–Fisher 1978](#r-nwf1978)) is (1−1/e)-optimal; lazy
order per [Minoux 1978](#r-minoux). Each pick carries exact _marginal_
bits — the receipt independent top-K retrievers (embeddings included)
cannot give.

---

## 3. Corpus quotation (codex shelf)

| citation                                                       | role in relate                                           | code                         |
| -------------------------------------------------------------- | -------------------------------------------------------- | ---------------------------- |
| [Shannon 1948](#r-shannon)                                     | space floor −log₂ p                                      | `codex/` README              |
| [Burrows–Wheeler 1994](#r-bwt); [Manzini 2001](#r-manzini)     | BWT as context-sorted permutation                        | `codex.zig`                  |
| [Ferragina & Manzini 2000](#r-fm) (FM-index)                   | O(m) count/find independent of corpus size               | `codex.zig`                  |
| [Nong–Zhang–Chan 2009](#r-sais) (SA-IS)                        | O(n) suffix array                                        | `sais.zig`                   |
| [Grossi et al. 2003](#r-wavelet); [Raman et al. 2002](#r-rrr)  | entropy-coded rank                                       | `wavelet.zig`, `rrr.zig`     |
| [Ohlebusch et al. 2010](#r-ms); [Ziv & Merhav 1993](#r-zm1993) | phrase the query against the whole corpus, price in bits | `cento.zig` → `relate quote` |

`quote` needs the persisted shelf (`relate index --shelf`); query cost is
O(|text|), corpus size never appears. Measured separation: known text
~0.15 bits/byte vs foreign ~15 (~90×) — tables in
[`src/kernel/codex/README.md`](../../src/kernel/codex/README.md).

---

## 4. Multi-pattern exactness

Relate's `patterns` verb deliberately **does not** follow Hyperscan-style
fused multi-pattern DFAs. Those win throughput by collapsing attribution.
The agent loop needs _which_ of N intents hit. Contract: one walk, N
patterns, answer ≡ N independent single-pattern runs (prefilter forced on
and off). Engine: `src/kernel/slate/`. Race harness:
`bench/races/multipattern.sh` (~6× vs sequential `gist -l` on a 10-pattern
slate, with attribution preserved).

---

## 5. Neighboring families (measured or surveyed, not adopted as the product)

### Embeddings / semantic retrieval

Honest race: `zig build relate-knn` (`bench/knn/knn.zig`) runs the real
zipper / sketch / pivot lanes as a k-NN classifier against gzip-kNN and a
static embedding model. **Verdict (KILL for semantic retrieval):**
embeddings win accuracy and amortized query speed; compression's edge is
model-free cold-start, kinship, duplication, attribution, and anti-redundant
packing. Spike trail: `.local/spikes/compression-vs-embeddings/SPIKE.md`.

Relate does not claim to replace vector search. It claims the lane
embeddings are a poor fit for.

### Normalized Compression Distance (NCD) and gzip-kNN

[Li et al. 2004](#r-ncd) NCD and the ACL-era gzip-kNN classifiers are the
direct Benedetto lineage. Relate uses LZJD sketches + exact cross-parses
instead of shelling gzip per pair — same signal class, agent-loop latency
budget.

### qgrep / fuzzy indexed search

[qgrep](#r-qgrep) searches a compressed indexed _copy_ of source. Relate
keeps source authoritative for kinship walks; the codex shelf is an exact
self-index for literal quotation/count, not fuzzy path search.

### Structural / AST clone tools

[Semgrep](#r-semgrep), [ast-grep](#r-astgrep), and language-specific Type-2
clone detectors parse. Relate's silhouette is intentionally not a parse —
so it works across Billy's polyglot tree without a language registry, at
the cost of never being a syntax-aware rewriter.

### "Language modeling is compression"

[Delétang et al. 2023](#r-lm-compress) argue LMs are strong general
compressors. Motivational neighbor, not a dependency — shipping an LM
inside `relate` would abandon the model-free, deterministic, offline-first
contract.

---

## 6. Precise novelty statement

Relate's contribution is integrating, for one agent workload:

1. dual-channel kinship (bytes + structure + echo gap) with a warm atlas;
2. two-stage compression retrieval (corpus-priced winnow lexicon → exact
   Ziv–Merhav zipper) that never shells a compressor;
3. submodular context packing with marginal-bits receipts;
4. FM-index corpus quotation shared with `gist codex`;
5. exact multi-pattern attribution;

…and measuring the embedding boundary instead of pretending to cross it.

**Standing obligation.** If a prior instance of this same measured contract
surfaces, cite it and re-scope. Where prose lags the binary,
`relate --schema` and the harnesses are authoritative.

---

## References

Annotated bibliography for every external source above. Anchor ids match the
in-body citation links.

<span id="r-bcl2002"></span>

1. **Benedetto, Caglioti & Loreto (2002).**
   [_Language Trees and Zipping_](https://doi.org/10.1103/PhysRevLett.88.048702)
   · [arXiv:cond-mat/0108530](https://arxiv.org/abs/cond-mat/0108530).
   _Annotation:_ Compressor-defined relative entropy recovers language
   phylogeny and authorship with no linguistics table — the spark for
   relate's kinship / retrieval question.

<span id="r-lzjd"></span> 2. **Raff & Nicholas (2017).**
[_Lempel-Ziv Jaccard Distance_](https://doi.org/10.1145/3097983.3098155)
(KDD 2017).
_Annotation:_ LZ78 phrase-dictionary Jaccard — NCD-class signal without
a gzip run per pair; backs `sketch.zig` (k=128 KMV).

<span id="r-kmv"></span> 3. **Beyer, Haas, Reinwald, Sismanis & Gemulla (2007).**
[_On synopses for distinct-value estimation under multiset operations_](https://doi.org/10.1145/1247480.1247504)
(SIGMOD 2007).
_Annotation:_ KMV / bottom-k MinHash — unbiased Jaccard from the k
smallest hashes of the union; mergeable flat sketches for atlas warm
tier.

<span id="r-winnow"></span> 4. **Schleimer, Wilkerson & Aiken (2003).**
[_Winnowing: Local Algorithms for Document Fingerprinting_](https://doi.org/10.1145/872757.872770)
(SIGMOD 2003) — the MOSS sampler.
_Annotation:_ Shared-substring fingerprint guarantee without parse-order
boundaries; used for structure silhouettes and the retrieval lexicon
(after LZ78 phrases failed short queries).

<span id="r-roy-cordy"></span> 5. **Roy & Cordy (2007).**
[_A Survey on Software Clone Detection Research_](https://research.cs.queensu.ca/TechReports/Reports/2007-541.pdf)
(Queen's Tech Report 2007-541).
_Annotation:_ Type-2 clone = renamed twin — names the failure mode
byte-LZJD misses and motivates the structure / `echoes` channel.

<span id="r-shannon"></span> 6. **Shannon (1948).**
[_A Mathematical Theory of Communication_](https://doi.org/10.1002/j.1538-7305.1948.tb01338.x).
_Annotation:_ −log₂ p information content — space floor for the codex
and IDF-shaped fingerprint pricing in the lexicon.

<span id="r-blumer"></span> 7. **Blumer, Blumer, Haussler, Ehrenfeucht, Chen & Seiferas (1985).**
[_The smallest automaton recognizing the subwords of a text_](<https://doi.org/10.1016/0304-3975(85)90157-4>).
_Annotation:_ Suffix automaton — minimal DFA of all substrings; the
match-finder behind `zipper.zig`'s exact cross-parse.

<span id="r-zm1993"></span> 8. **Ziv & Merhav (1993).**
[_A measure of relative entropy between individual sequences with application to universal classification_](https://doi.org/10.1109/18.243444).
_Annotation:_ Cross-parsing factors estimate cross-entropy; relate
prices real code lengths instead of shelling a compressor (`zipper`,
`cento`).

<span id="r-nwf1978"></span> 9. **Nemhauser, Wolsey & Fisher (1978).**
[_An analysis of approximations for maximizing submodular set functions—I_](https://doi.org/10.1007/BF01588971).
_Annotation:_ Greedy (1−1/e)-optimal for monotone submodular max —
optimality certificate for `relate pack`.

<span id="r-minoux"></span> 10. **Minoux (1978).**
[_Accelerated greedy algorithms for maximizing submodular set functions_](https://doi.org/10.1007/BFb0006528).
_Annotation:_ Lazy greedy evaluation order — how pack avoids
recomputing every marginal each round.

<span id="r-bwt"></span> 11. **Burrows & Wheeler (1994).**
[_A block-sorting lossless data compression algorithm_](https://mirrors.meulie.net/bitsavers.org/pdf/dec/tech_reports/SRC-RR-124.pdf)
(SRC Research Report 124).
_Annotation:_ BWT permutation — context-sorted transform the FM-index
/ codex sits on.

<span id="r-manzini"></span> 12. **Manzini (2001).**
[_An analysis of the Burrows–Wheeler transform_](https://doi.org/10.1145/382780.382782)
(JACM).
_Annotation:_ Zeroth-order coding over the BWT bounded by _k_-th order
entropy of the original text.

<span id="r-fm"></span> 13. **Ferragina & Manzini (2000).**
[_Opportunistic data structures with applications_](https://doi.org/10.1109/SFCS.2000.892127)
(FOCS) — the FM-index.
_Annotation:_ O(m) count/find independent of corpus size; product
surface of `gist codex` / `relate quote`.

<span id="r-sais"></span> 14. **Nong, Zhang & Chan (2009).**
[_Linear Suffix Array Construction by Almost Pure Induced-Sorting_](https://doi.org/10.1109/DCC.2009.42)
(DCC) — SA-IS.
_Annotation:_ O(n) suffix-array construction used at codex build time
(`sais.zig`).

<span id="r-wavelet"></span> 15. **Grossi, Gupta & Vitter (2003).**
[_High-order entropy-compressed text indexes_](https://doi.org/10.1137/1.9781611972931.6)
(SODA) — Huffman-shaped wavelet trees.
_Annotation:_ Rank oracle for the FM-index at entropy-bound space
(`wavelet.zig`).

<span id="r-rrr"></span> 16. **Raman, Raman & Rao (2002).**
[_Succinct indexable dictionaries with applications to encoding k-ary trees, prefix sums and multisets_](https://doi.org/10.1145/1290672.1290680)
(SODA) — RRR bitvectors.
_Annotation:_ O(1) rank at zeroth-order entropy per wavelet level
(`rrr.zig`).

<span id="r-ms"></span> 17. **Ohlebusch, Gog & Kügel (2010).**
[_Computing Matching Statistics and Maximal Exact Matches on Compressed Full-Text Indexes_](https://doi.org/10.1007/978-3-642-16321-0_36)
(SPIRE).
_Annotation:_ Matching statistics over an FM-index — the phrase layer
behind corpus-global `relate quote` (`cento.zig`).

<span id="r-ncd"></span> 18. **Li, Chen, Li, Ma & Vitányi (2004).**
[_The similarity metric_](https://doi.org/10.1109/TIT.2004.838101)
(IEEE Trans. Inf. Theory) — Normalized Compression Distance.
_Annotation:_ Classical NCD / gzip-distance lineage; relate substitutes
LZJD + exact cross-parse for agent-loop latency.

<span id="r-lm-compress"></span> 19. **Delétang et al. (2023).**
[_Language Modeling Is Compression_](https://arxiv.org/abs/2309.10668).
_Annotation:_ LMs as general compressors — neighboring research, not a
relate dependency (model-free contract).

<span id="r-qgrep"></span> 20. **zeux/qgrep.**
[github.com/zeux/qgrep](https://github.com/zeux/qgrep).
_Annotation:_ Compressed indexed _copy_ of source for fuzzy/content
search — different object from relate's authoritative-tree kinship +
exact codex shelf.

<span id="r-semgrep"></span> 21. **Semgrep.**
[semgrep.dev — philosophy](https://semgrep.dev/docs/contributing/semgrep-philosophy).
_Annotation:_ Syntax-aware pattern matching; relate deliberately stays
byte/token-squint, not AST.

<span id="r-astgrep"></span> 22. **ast-grep.**
[ast-grep.github.io](https://ast-grep.github.io/).
_Annotation:_ tree-sitter structural search/rewrite — neighbor left for
transformational questions.

<span id="r-3b1b"></span> 23. **Sanderson, G. (3Blue1Brown) (2026).**
[_But what is cross-entropy? | Compression is Intelligence Part 2_](https://www.youtube.com/watch?v=GlYgs6v2YfU&t=672s).
_Annotation:_ Public lecture on cross-entropy and compression;
reference material alongside the literature above.
