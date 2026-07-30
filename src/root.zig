//! relate — compression-as-search over the irregex corpus.
//!
//! The similarity engine of the irregex ecosystem: where `irregex` (the
//! library this package stands on) answers *"where is this exact pattern?"*,
//! relate answers the two questions regex can't — *"what is near THIS one?"*
//! and *"what repeats among ALL of them?"* — with compression kinship (LZJD
//! sketches, structure silhouettes, corpus-priced fingerprints, a
//! suffix-automaton Ziv–Merhav cross-parse) instead of parsing.
//!
//! Package shape, three tiers over the library:
//!
//!   kinship/   — the metrics (sketch · silhouette · channel · fingerprint),
//!                the cluster machinery (pairs · families · echoes), and the
//!                recall tier (lexicon · zipper · coverage)
//!   codex/     — the compressed self-index (FM-index over SA-IS + wavelet +
//!                RRR, the math floors re-exported by irregex), its cento
//!                quoter, and the persisted shelf / atlas / frag artifacts
//!   compose/   — the exact ∩ compression kernels (ADR-367): a compiled
//!                PatternSet narrows, kinship reasons inside the subset
//!
//! The `relate` BINARY ships from the `gist` package (the product chassis);
//! this package is the engine it and `blast` import.

const std = @import("std");

// ── kinship: the metrics, the cluster machinery, the recall tier ──
pub const kinship = struct {
    pub const sketch = @import("kernel/kinship/metric/sketch.zig");
    pub const silhouette = @import("kernel/kinship/metric/silhouette.zig");
    pub const channel = @import("kernel/kinship/metric/channel.zig");
    pub const fingerprint = @import("kernel/kinship/metric/fingerprint.zig");
    pub const pairs = @import("kernel/kinship/cluster/pairs.zig");
    pub const families = @import("kernel/kinship/cluster/families.zig");
    pub const echoes = @import("kernel/kinship/cluster/echoes.zig");
    pub const lexicon = @import("kernel/kinship/recall/lexicon.zig");
    pub const zipper = @import("kernel/kinship/recall/zipper.zig");
    pub const coverage = @import("kernel/kinship/recall/coverage.zig");
};

// ── anatomy: how a file decomposes into comparison units ──
// The function/region lexers the fragment tier and compose ride. The shared
// comment/code/string span lexer (lexspan) stayed in the irregex library —
// its exact engine reads it too.
pub const anatomy = struct {
    pub const spans = @import("kernel/anatomy/spans.zig");
    pub const leans = @import("kernel/anatomy/leans.zig");
    pub const token = @import("kernel/anatomy/token.zig");
};

// ── codex: the compressed self-index (the book that IS its own index) ──
// FM-index over SA-IS + Huffman-shaped wavelet tree + RRR bitvectors: holds a
// corpus at entropy-bound size while answering count(P) in O(|P|), plus
// locate (sampled) and byte-exact restore. The succinct math floors live in
// the irregex library (`@import("irregex").codex`); the index built on them
// lives here with the engine that consumes it.
pub const codex = struct {
    pub const index = @import("kernel/codex/codex.zig");
    pub const cento = @import("kernel/codex/cento.zig");
    pub const shelf = @import("corpus/index/shelf/shelf.zig");
};

// ── the persisted warm tier: kinship atlas + fragment atlas ──
pub const atlas = @import("corpus/index/atlas/atlas.zig");
pub const frag = @import("corpus/index/frag/frag.zig");

// ── retrieval: trigram-nominated, zipper-decided search sessions ──
pub const retrieval = @import("exec/retrieval/retrieval.zig");
/// The resident retrieval session (warm index + cached anchor overlay),
/// riding the irregex library's watch/reconcile machinery.
pub const resident = @import("exec/session/warm/retrieval.zig");

// ── compose: the exact-before-statistical kernels (ADR-367) ──
// A compiled PatternSet (the library's match half) narrows the corpus to a
// typed CandidateSet, and kinship runs ONLY inside that exact subset. Pure
// kernels — no I/O, no argv; the faces (in `gist` and `blast`) load the
// corpus and render.
pub const compose = struct {
    pub const candidates = @import("kernel/compose/candidates.zig");
    pub const context = @import("kernel/compose/context.zig");
    pub const family = @import("kernel/compose/family.zig");
    pub const provenance = @import("kernel/compose/provenance.zig");
    pub const regions = @import("kernel/compose/regions.zig");
    pub const blast = @import("kernel/compose/blast.zig");
};

test {
    // `refAllDecls` pulls each tier re-export above into `zig build test`;
    // each tier's dedicated `*_test.zig` sibling is wired in explicitly.
    std.testing.refAllDecls(@This());
    _ = @import("kernel/kinship/metric/sketch_test.zig"); // kinship metric semantics + clustering gate
    _ = @import("kernel/kinship/metric/sketch_oracle_test.zig"); // external oracles — exact bottom-k, set-Jaccard, deflate NCD rank
    _ = @import("kernel/kinship/metric/silhouette_test.zig"); // structure channel: normalization invariance + winnow guarantee
    _ = @import("kernel/kinship/recall/lexicon_test.zig"); // retrieval proof (short-query recall, ΔAb sidedness, zero-bit boilerplate)
    _ = @import("kernel/compose/candidates_test.zig"); // CandidateSet ≡ substring set-algebra (any/all masks, 64-cap, error paths)
    _ = @import("kernel/codex/codex_test.zig"); // SA-IS/RRR/wavelet/index differential vs naive oracles
    _ = @import("corpus/index/shelf/shelf_test.zig"); // count/tally vs per-doc oracles through save/load, fail-closed framing
    _ = @import("corpus/index/atlas/atlas_test.zig"); // atlas round-trip, fail-closed parse, freshness-fold semantics
    _ = @import("corpus/index/frag/frag_test.zig"); // frag round-trip, fail-closed parse, freshness-fold + deletion gate
}
