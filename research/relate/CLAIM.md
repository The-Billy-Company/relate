---
doc_radar:
  sentinels:
    - file: src/kernel/kinship/recall/lexicon.zig
      contains: ["pub fn fingerprintBits", "pub fn retrieve"]
    - file: src/kernel/kinship/recall/zipper.zig
      contains: ["pub fn coldBits", "pub const Automaton"]
    - file: src/kernel/kinship/recall/coverage.zig
      contains: ["pub fn greedy", "marginal_bits"]
    - file: src/kernel/kinship/metric/channel.zig
      contains: [".twins => bytes - structure", ".any => @min(bytes, structure)"]
      description: each channel composes the two measured distances in exactly one place
    - file: src/kernel/kinship/cluster/echoes.zig
      contains: ["pub fn survey", "pub fn massFloor"]
      description: one repetition survey over unit × channel × shape, with the channel's own mass floor
    - file: contract/kinship.toml
      contains:
        - "similar = { argv ="
        - "pack = { argv ="
        - "quote = { argv ="
        - "echoes = { argv ="
---

# Relate — search by shared information

**Status:** shipped product + measured evidence. CLI face:
`src/surface/face/relate/`. Engines: `src/kernel/kinship/` + `src/kernel/slate/` +
`src/corpus/index/{atlas,codex}/`. Public contract: `relate --schema` /
[`contract/kinship.toml`](../../contract/kinship.toml). Prior art:
`PRIOR_ART.md`; evidence: `TESTING.md`.

**Relate finds relationships exact search cannot name.** It discovers files
that share vocabulary or structure, assembles a small set whose information
does not repeat, and traces familiar text back to the corpus—all locally,
deterministically, and without an embedding model.

---

## 0. The product thesis

Exact search begins with a word you already know. Repository work often starts
one step earlier:

- What resembles this file even after every identifier changed?
- Which files jointly explain this subsystem without repeating one another?
- Did these implementations fork from the same ancestor?
- Which parts of this proposed text already exist, and where?

Relate answers by treating every file as a possible dictionary. If a query can
be written as long copies from a file, that file explains it cheaply. If two
files yield similar compression phrases, they are kin. If a second file adds
no new priced information, it does not belong in the context pack.

That is compression as search: stop before producing the archive and return
the sources that made the description short.

### What Relate gives an agent

#### Find the neighborhood

`similar` finds the nearest files. `dups` finds copy-paste drift. `clusters`
returns entire fork families rather than a pair list the caller must join.
`echoes` finds the stranger case: files far apart in words but close in
shape—the repeated abstraction hiding beneath renamed identifiers.

#### Retrieve a useful set

`search` asks which individual files describe a query cheaply. `pack` asks the
more important context-window question: which **set** adds the most distinct
information? Every pick carries a marginal-bit receipt, so the caller can see
what it contributed and when coverage stopped growing.

#### Ask what the corpus already knows

`quote` factors text into maximal corpus quotations, attributes each phrase to
an exemplar file, and prices known versus foreign material. It turns
provenance, reuse, and contamination from a yes/no substring query into an
accounted explanation.

#### Sweep many exact intents once

`patterns` performs one corpus walk for N Gist patterns while preserving the
identity of every hit. It belongs to Relate because the answer is set-shaped,
although its machinery is exact matching rather than compression.

---

## 1. The product map

| verb               | question                                     | engine                      |
| ------------------ | -------------------------------------------- | --------------------------- |
| `search`           | which files describe this text cheapest?     | lexicon → zipper            |
| `pack`             | which _set_ covers it without redundancy?    | priced coverage + greedy    |
| `quote`            | rewrite as priced corpus quotations          | codex shelf + cento         |
| `similar`          | what else is like this file?                 | sketch / silhouette / fused |
| `dups`             | near-duplicate pairs                         | sketch distance ≤ T         |
| `clusters`         | fork families (transitive dups)              | connected components        |
| `echoes`           | same skeleton, different vocabulary          | bytes − structure           |
| `patterns`         | N patterns, one walk, Gist-exact attribution | batch / loom                |
| `index` / `status` | atlas (+ optional shelf) lifecycle           | atlas + codex               |

The verbs are deliberately different answer shapes over one corpus:

- a **ranked file** for retrieval;
- a **complementary set** for context;
- a **verified pair or family** for restructuring;
- an **attributed phrase sequence** for provenance;
- an **attributed pattern set** for batch exact search.

Relate owns those objects inside the engine so every caller does not rebuild
them with ad hoc scripts.

---

## 2. How the compression engine works

### Two views of kinship

The byte channel measures **compression kinship** with an LZJD phrase sketch:
files sharing compression vocabulary have low distance. It is fast,
symmetric, and honest about renamed code looking different.

The structure channel deliberately squints. It removes comments and
whitespace, replaces identifiers and literals with classes, preserves one
pan-language keyword shelf, then winnows token shingles. Renamed twins become
close without requiring a parser or language registry.

`echoes` compares the channels:

```text
echo = byte distance − structure distance
```

A high score means the files share far more skeleton than vocabulary—the
signal a DRY or abstraction pass actually wants.

### Recall cheaply, decide exactly

Running a compressor against every file would be too expensive. `search`
therefore has two stages:

```text
query
  → mmap-backed trigram codebook
      corpus self-information nominates a bounded candidate pool
  → query-bearing evidence windows
      suffix-automaton conditional code length decides order
```

The codebook reuses Gist's compact persisted postings instead of rebuilding a
dense private lexicon before every query. Three-byte terms therefore remain
visible, descriptive queries combine independently useful chunks, and the
zipper prices only bounded windows around that evidence. Familiar text becomes
long cheap factors; foreign text remains expensive literals.

### Select by marginal information

`pack` prices the same query chunks by `−log₂(df/N)`. Boilerplate seen in every
file is worth zero; rare information is expensive. Greedy submodular coverage
repeatedly chooses the file that pays for the most still-uncovered bits.
Near-duplicates collapse after the first pick because their marginal
contribution becomes zero.

### Quote against the whole corpus

The codex shelf is an FM-index over the corpus. `quote` cross-parses text
against that shelf in time proportional to the text, emits maximal known
phrases with source attribution, and marks what remains foreign. The shelf is
a lifecycle artifact because corpus-global quotation requires a
corpus-global index.

---

## 3. Why it fits an agent

**It works before vocabulary is known.** Embeddings are strongest when the
question is semantic. Relate is strongest when the evidence is repeated bytes,
renamed structure, fork history, or corpus provenance.

**It returns sets, not merely scores.** Agents read under a context budget.
Packing complementary evidence and returning whole clone families removes
work every independent top-K list pushes downstream.

**It explains itself.** Distances, coding gain, marginal bits, coverage,
foreign chunks, phrase costs, and source paths are inspectable. There
is no opaque vector whose relevance must be taken on faith.

**It starts cold and stays local.** No model download, provider, API key, or
training pass is required. The same corpus and query produce the same order.

**Its warm tier cannot fossilize the tree.** The kinship atlas folds in files
changed since its anchor, gates deletions, and falls back to a live rebuild
with byte-identical answers. `search` and `pack` reuse Gist's persisted
trigram codebook for nomination and fold changed files live; their exact
deciders still read current candidate bytes.

---

## 4. What is original

Relate's **systems/workload composition** is original:

1. one compression lens spanning kinship, retrieval, context assembly, and
   corpus quotation;
2. a boundary-free lexicon that nominates before an exact Ziv–Merhav zipper
   decides;
3. corpus-priced packing with explicit marginal-bit receipts;
4. the byte-versus-structure echo gap as a refactor-ranking heuristic;
5. agent-shaped result objects—families, packs, and attributed quotations;
6. a persisted dual-channel atlas whose warm answer is identical to a live
   rebuild.

This is a product and systems claim, not ownership of the mathematics.
Benedetto–Caglioti–Loreto, NCD/LZJD, KMV, MOSS winnowing, Ziv–Merhav
cross-parsing, FM-indexes, normalized clone detection, and submodular
selection are prior art. Relate makes them one coherent local instrument and
measures where that instrument earns its place.

---

## 5. Contract and boundaries

Relate is intentionally model-free. The measured semantic-retrieval race
belongs to embeddings; Relate owns the byte-evidence, kinship, duplication,
packing, and provenance lane. Its structure channel is a token squint, not
an AST, type system, or rewrite engine.

`patterns` likewise does not invent multi-pattern attribution—Hyperscan
already reports expression IDs. Its contract is narrower and useful:
bit-for-bit equality with N independent Gist searches under Gist's own match
and prefilter semantics.

The atlas is an accelerator, never authority. The codex shelf reports
staleness because `quote` cannot honestly infer corpus-global provenance from
an unknown snapshot. Relate analytics use the wider index corpus; Gist keeps
the ripgrep-compatible search walk.

`relate --schema` defines the shipped verbs. `TESTING.md` defines measured
behavior. `PRIOR_ART.md` defines the ancestry.

The enduring claim is not that compression understands code. It is that
repetition is evidence—and agents deserve a first-class instrument for
turning that evidence into files, sets, families, and provenance.
