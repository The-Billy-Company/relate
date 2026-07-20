# Relate — the composition claim (scope, verbs, non-claims)

**Status:** shipped product + measured evidence. CLI face:
`src/cli/relate/`. Engines: `src/search/similarity/` + `src/search/batch/` +
`src/index/{atlas,codex}/`. Public contract: `relate --schema` /
[`contract/search_api.toml`](../../contract/search_api.toml). Prior art:
`PRIOR_ART.md`; evidence: `TESTING.md`.

**One sentence.** Stop before emitting one compressed blob; return the files
(or quotations) that would make that compression cheap — priced in bits,
deterministic, with no language list and no embedding model.

---

## 0. What is claimed (and what is not)

### The claim

Relate's contribution is a **systems/workload composition** for coding agents
that need set-shaped answers beside exact grep:

1. **compression kinship** — LZJD byte sketches + MOSS-style structure
   silhouettes, optionally fused; warm atlas with fail-open live rebuild;
2. **compression retrieval** — winnowed fingerprint lexicon nominates by
   corpus-priced bits; suffix-automaton Ziv–Merhav cross-parse decides
   (score = coding gain ∈ [0,1]);
3. **anti-redundant packing** — greedy submodular max-coverage over those
   priced fingerprints, with exact marginal-bits receipts;
4. **corpus quotation** — FM-index shelf + matching-statistics / Ziv–Merhav
   cross-parse so foreign vs known bytes separate by ~90× in bits/byte;
5. **exact multi-pattern attribution** — one walk, N patterns, per-pattern
   confirmation (never fused-DFA guesswork);
6. **echo ranking** — `bytes − structure` surfaces Type-2 clones that
   vocabulary distance alone misses.

None of those ingredients alone is novel. The value is integrating them into
one CLI with a single covenant (tree / shelf tell the truth; accelerators
decline rather than invent) and measuring where compression wins vs where
embeddings win (`bench/relate/`).

### Explicit non-claims

Relate is:

- **not a new compression theorem**; Shannon, BWT/FM-index, Ziv–Merhav, and
  NCD/LZJD predate it;
- **not a semantic / embedding retriever**; the knn harness's honest verdict
  is that embeddings win semantic retrieval on accuracy and amortized query
  speed — relate stays in the model-free, exact-byte lane;
- **not a language model**; "language modeling is compression" is
  neighboring research context, not a claim that relate trains or runs an LM;
- **not a parser or clone detector with a language list**; the silhouette
  scanner is a deliberate squint (normalize tokens, keep pan-language
  keywords), not tree-sitter / LSP;
- **not Hyperscan**; `patterns` refuses fused multi-pattern DFAs that lose
  which pattern hit — exact attribution is the contract;
- **not qgrep / semantic code search / RAG**; different objects (see
  `PRIOR_ART.md`).

Where prose lags the binary, `relate --schema` and the harnesses win.

---

## 1. Verb map (what each question owns)

| verb | question | engine |
|---|---|---|
| `search` | which files describe this text cheapest? | lexicon → zipper |
| `pack` | which *set* covers it without redundancy? | lexicon + greedy submodular |
| `quote` | rewrite as priced corpus quotations | codex shelf + cento |
| `similar` | what else is like this file? | sketch / silhouette / fused |
| `dups` | near-duplicate pairs | sketch distance ≤ T |
| `clusters` | fork families (transitive dups) | connected components |
| `echoes` | same skeleton, different vocabulary | echo = bytes − structure |
| `patterns` | N patterns, one walk, exact attribution | batch / loom |
| `index` / `status` | atlas (+ optional shelf) lifecycle | atlas + codex |

---

## 2. Design invariants (load-bearing)

1. **No language list.** Compressors and token squints discover structure;
   misclassification perturbs shingles, never crashes a parse.
2. **Exactness over fusion.** `patterns` answers must equal N independent
   single-pattern runs bit-for-bit (prefilter on and off).
3. **Atlas is an accelerator.** Warm `similar`/`dups`/`clusters`/`echoes`
   fold in files changed since the anchor; `--no-index` or a bad atlas →
   live rebuild with **byte-identical** answers. `search`/`pack` stay
   live-built (lexicon density economics).
4. **Shelf is a lifecycle event.** `quote` reads the persisted codex shelf
   (`relate index --shelf` / `gist codex build`); staleness is reported, not
   hidden.
5. **Corpus policy differs from gist search.** Relate analytics use the
   index corpus (wider than rg-gitignore); `gist <pattern>` keeps rg parity.
   Intentional — documented at the `verbs.zig` seam.

---

## 3. Relationship to Gist and Crest

- **Gist** owns exact/regex location (trigram + crest read-elision).
- **Relate** owns compression kinship / retrieval / packing / quotation.
- **Crest** is novel math *inside* gist for literal-free class repetitions;
  relate does not claim new theorems.

One kernel (`irregex`), two product faces, shared floor
(`corpus` / `index` / `search` / `runtime`).

---

## 4. Standing obligation

If a prior system already ships this same measured verb set with the same
fail-open covenant for agent workloads, cite it and re-scope. Numbers in
product READMEs cite harness artifacts, not universal constants.
