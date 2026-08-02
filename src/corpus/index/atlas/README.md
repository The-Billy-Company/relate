# atlas — the persisted kinship index

The trigram index makes `gist` warm; the **atlas** makes `relate` warm. It
persists two channels per corpus file: one LZJD sketch
(`kernel/kinship/metric/sketch.zig` — bottom-k of the LZ78 phrase-hash
dictionary, ~1 KiB) and one structure silhouette
(`kernel/kinship/metric/silhouette.zig` — winnowed normalized-token shingles,
~2 KiB), so the kinship verbs (`similar` / `echoes`) answer from tens of MiB
of index instead of re-reading and re-parsing a couple hundred MiB of corpus
per invocation. Built by `relate index`, reported by `relate status`. Both
channels refresh together in the fold — a row whose sketch and silhouette
answered from different bytes would corrupt the echo signal.

Same covenant as every irregex index — **an accelerator, never an
authority**:

- the anchor is captured **before** the build's corpus read (the T3
  convention), and `fold` re-derives freshness through the same conservative
  stat walk the trigram overlay uses (`fresh.changedSince`), re-sketching
  every changed/new file from live bytes — so a folded view is
  byte-equivalent to a live rebuild for every file that still exists;
- deletions are invisible to a changed-walk (it only visits live files), so
  consumers gate **emitted** rows through `onDisk` — O(results) stats, never
  O(corpus);
- `--no-index`, a missing atlas, or a corrupt atlas all fall back to the
  full live build with identical answers; the parse fails closed on any
  framing, bounds, or checksum violation.

Deliberately **not** duplicated here: a private retrieval fingerprint lexicon.
Relate reuses Gist's compact mmap-backed trigram codebook to nominate for its
retrieval questions (a `relate similar <text>` probe and `pack`), then applies
its own corpus-information pricing, bounded cross-parse, or marginal-coverage
decision. The atlas remains the economic persisted shape for broad kinship
queries; narrow explicit scopes skip its whole-artifact load and sketch live.
