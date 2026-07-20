//! irregex compose — `context`: coverage packing inside the exact filter.
//!
//! The composed answer to "give me the minimal non-redundant reading set among
//! files that actually match these intents." `relate pack` over the whole
//! corpus surfaces near-duplicate high-coverage files regardless of the query's
//! exact intent; running the exact `PatternSet` first (`candidates.select`) and
//! building the fingerprint lexicon over ONLY the candidate docs prices novelty
//! inside the matching set, so the greedy submodular sweep (`coverage.zig`)
//! never spends a pick on a file the caller's patterns didn't hit.
//!
//! Two scores stay honest and separate (ADR-367): each pick carries the exact
//! `mask` of patterns that admitted its file AND the compression `marginal_bits`
//! it adds beyond earlier picks — no fused relevance number. Pure kernel: the
//! driver loads the corpus and renders; this builds the sub-lexicon and packs.

const std = @import("std");
const lexicon = @import("../kinship/recall/lexicon.zig");
const coverage = @import("../kinship/recall/coverage.zig");
const candidates = @import("candidates.zig");

/// One packed pick: a corpus doc id, the exact patterns that admitted it, and
/// the compression accounting (bits it adds, cumulative coverage fraction).
pub const Pick = struct {
    doc: u32,
    mask: u64,
    marginal_bits: f64,
    coverage: f64,
};

pub const Packed = struct {
    gpa: std.mem.Allocator,
    picks: []Pick,
    total_bits: f64,
    foreign: usize,
    candidates: usize,

    pub fn deinit(self: *Packed) void {
        self.gpa.free(self.picks);
    }
};

/// Coverage-pack `query` within `cset`. Prices the query's fingerprints against
/// a lexicon built from the candidate docs alone, greedily picks the set that
/// jointly covers the most priced bits, and maps picks back to corpus ids +
/// their exact masks. Caller owns the result.
pub fn pack(
    gpa: std.mem.Allocator,
    docs: []const []const u8,
    paths: []const []const u8,
    cset: *const candidates.CandidateSet,
    query: []const u8,
    top: usize,
) !Packed {
    const m = cset.count();
    const cand_docs = try gpa.alloc([]const u8, m);
    defer gpa.free(cand_docs);
    const cand_paths = try gpa.alloc([]const u8, m);
    defer gpa.free(cand_paths);
    for (cset.ids, 0..) |id, k| {
        cand_docs[k] = docs[id];
        cand_paths[k] = paths[id];
    }

    var lex = try lexicon.Lexicon.build(gpa, cand_docs);
    defer lex.deinit();

    const qfps = try lexicon.fingerprints(gpa, query);
    defer gpa.free(qfps);

    // The coverable total: priced query bits (df > 0). Foreign fingerprints
    // (unseen in the candidate set) cannot be covered and are reported, not hidden.
    var total_bits: f64 = 0.0;
    var foreign: usize = 0;
    for (qfps) |fp| {
        const b = lex.fingerprintBits(fp);
        if (b > 0.0) total_bits += b else if (lex.fingerprintFrequency(fp) == 0) foreign += 1;
    }

    const raw = try coverage.greedyPack(gpa, &lex, cand_paths, qfps, top);
    defer gpa.free(raw);

    const picks = try gpa.alloc(Pick, raw.len);
    errdefer gpa.free(picks);
    for (raw, picks) |p, *out| {
        out.* = .{
            .doc = cset.ids[p.doc],
            .mask = cset.masks[p.doc],
            .marginal_bits = p.marginal_bits,
            .coverage = if (total_bits > 0.0) p.covered_bits / total_bits else 0.0,
        };
    }
    return .{ .gpa = gpa, .picks = picks, .total_bits = total_bits, .foreign = foreign, .candidates = m };
}

// ── tests ──────────────────────────────────────────────────────────────────

const t = std.testing;
const patterns_mod = @import("../batch/patterns.zig");

fn compileSet(gpa: std.mem.Allocator, pats: []const []const u8) !patterns_mod.PatternSet {
    const specs = try gpa.alloc(patterns_mod.Spec, pats.len);
    defer gpa.free(specs);
    for (pats, specs) |p, *s| s.* = .{ .pattern = p, .fixed = true, .ignore_case = false };
    return patterns_mod.PatternSet.compile(gpa, specs);
}

test "context: packs only inside the exact filter, never a non-matching file" {
    const gpa = t.allocator;
    // The query describes wallet-grant code. Doc 3 is a byte-twin of doc 0's
    // text but does NOT contain the pattern literal, so the exact filter must
    // exclude it — a whole-corpus pack would rank it high on coverage.
    const q = "the wallet grant applies a credit to the user ledger balance";
    const docs = [_][]const u8{
        "fn grant() { the wallet grant applies a credit to the user ledger balance }",
        "grant helper: adds a credit to the user ledger balance too",
        "unrelated telemetry sampling notes for the fleet dashboards here",
        "the wallet grant applies a credit to the user ledger balance", // twin of 0, no `grant(` ... has `grant`
    };
    const paths = [_][]const u8{ "a.zig", "b.zig", "c.zig", "d.txt" };
    var set = try compileSet(gpa, &.{"grant"});
    defer set.deinit(gpa);
    var cs = try select(gpa, &docs, &set, .any);
    defer cs.deinit();

    var packed_result = try pack(gpa, &docs, &paths, &cs, q, 8);
    defer packed_result.deinit();

    // c.zig (no `grant`) is never a candidate, so it can never be picked.
    for (packed_result.picks) |p| try t.expect(p.doc != 2);
    // Every pick's mask is non-zero — it earned its place on the exact filter.
    for (packed_result.picks) |p| try t.expect(p.mask != 0);
    try t.expect(packed_result.picks.len >= 1);
}

const select = candidates.select;
