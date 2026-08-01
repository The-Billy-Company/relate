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
//!   codex/     — the Ziv–Merhav cento quoter over the library's FM-index
//!                (the index itself and its shelf live in `irregex`); plus
//!                the persisted atlas / frag kinship artifacts
//!   compose/   — the exact ∩ compression kernels (exact narrows, then kinship): a compiled
//!                PatternSet narrows, kinship reasons inside the subset
//!
//! The `relate` binary ships from this package too — its face and CLI
//! vocabulary live under `surface/`. The face imports `@import("gist")` for
//! the resident daemon and the answer keep; the engine below does not.

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

// ── codex: the corpus-quotation parse over the library's FM-index ──
// The FM-index itself and its persisted shelf live in the irregex library
// now (`@import("irregex").codex`) — an index tier among the others. What
// stays here is the Ziv–Merhav cross-parse that turns that index into a
// quotation.
pub const codex = struct {
    pub const cento = @import("kernel/codex/cento.zig");
};

// ── the persisted warm tier: kinship atlas + fragment atlas ──
pub const atlas = @import("corpus/index/atlas/atlas.zig");
pub const frag = @import("corpus/index/frag/frag.zig");

// ── retrieval: trigram-nominated, zipper-decided search sessions ──
pub const retrieval = @import("exec/retrieval/retrieval.zig");
/// The resident retrieval session (warm index + cached anchor overlay),
/// riding the irregex library's watch/reconcile machinery.
pub const resident = @import("exec/session/warm/retrieval.zig");

// ── compose: the exact-before-statistical kernels ──
// A compiled PatternSet (the library's match half) narrows the corpus to a
// typed CandidateSet, and kinship runs ONLY inside that exact subset. Pure
// kernels — no I/O, no argv; the faces (here and in `blast`) load the
// corpus and render.
pub const compose = struct {
    pub const candidates = @import("kernel/compose/candidates.zig");
    pub const context = @import("kernel/compose/context.zig");
    pub const family = @import("kernel/compose/family.zig");
    pub const provenance = @import("kernel/compose/provenance.zig");
    pub const regions = @import("kernel/compose/regions.zig");
    pub const blast = @import("kernel/compose/blast.zig");
};

// ── the CLI vocabulary the face (and `blast`) speak ──
// Flag parsing, verb-table rendering, kinship grades, and the answer-keep
// passenger. The keep dials gist's resident daemon; everything else is local.
pub const cli = struct {
    pub const flags = @import("surface/cli/flags.zig");
    pub const manifest = @import("surface/cli/manifest.zig");
    pub const grade = @import("surface/cli/grade.zig");
    pub const reprise = @import("surface/cli/reprise.zig");
};

// ── the face drivers, reached through the module ──
pub const faces = struct {
    /// relate's verb table — the single source its help/schema/dispatch read.
    pub const repertoire = @import("surface/face/repertoire.zig");
};

// ── in-process C-ABI producer ──
// Kinship / retrieval / sweep, exposed to non-Zig hosts as `relate_run`. The
// `export fn` lives in `surface/ffi/exports.zig` (the artifact root), not here —
// so a dependent that imports this module does not re-emit the symbol.
pub const ffi = struct {
    pub const analytic = @import("surface/ffi/analytic.zig");
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
    _ = @import("kernel/codex/cento_test.zig"); // Ziv–Merhav cross-parse vs greedy oracle over a live Codex
    _ = @import("corpus/index/atlas/atlas_test.zig"); // atlas round-trip, fail-closed parse, freshness-fold semantics
    _ = @import("corpus/index/frag/frag_test.zig"); // frag round-trip, fail-closed parse, freshness-fold + deletion gate
    _ = @import("surface/face/repertoire.zig"); // relate's verb table (schema validity + both registers)
    _ = @import("surface/face/kinship.zig"); // relate shared plumbing: view resolver + verified-pair machinery
    _ = @import("surface/face/units.zig"); // the unit view: file|function|match × warm/live × exact narrowing
    _ = @import("surface/face/options.zig"); // the one query option surface (flag loop + unit-scaled floors)
    _ = @import("surface/face/similar.zig"); // the neighbor verb: probe classification, self-exclusion, both polarities
    _ = @import("surface/face/echoes.zig"); // the repetition verb: unit × channel × shape rendering
    _ = @import("surface/face/patterns.zig"); // `relate patterns` driver body (one walk, N patterns)
    _ = @import("surface/face/pack.zig"); // `relate pack` driver body (greedy coverage semantics tested here)
    _ = @import("surface/face/lifecycle.zig"); // `relate index`/`status` driver bodies
    _ = @import("surface/ffi/analytic.zig"); // relate_run dispatch: ownership + sweep fail closed
}
