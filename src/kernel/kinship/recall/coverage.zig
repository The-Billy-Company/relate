//! relate — greedy weighted max-coverage over corpus-priced fingerprints, the
//! submodular core of `pack`.
//!
//! Pure kernel: given a lexicon and a query's fingerprints, pick the SET of
//! docs that jointly covers the most priced query bits, each pick scored by
//! the bits it adds BEYOND the picks before it. Coverage is submodular, so the
//! classic greedy sweep (Nemhauser–Wolsey–Fisher 1978) is within (1−1/e) of
//! optimal and Minoux's (1978) lazy order skips docs whose stale bound already
//! loses. Exact, model-free, deterministic; the verb driver loads the corpus,
//! builds the lexicon, and renders the picks.

const std = @import("std");
const lexicon = @import("lexicon.zig");

/// One greedy pick, in pick order.
pub const Pick = struct {
    doc: u32,
    marginal_bits: f64,
    covered_bits: f64, // cumulative after this pick
};

/// A compact weighted-set candidate. `cost` prices the reference itself:
/// `1` is ordinary max-coverage; larger values favor equally informative,
/// tighter references without changing marginal-bit accounting.
pub const MaskCandidate = struct {
    doc: u32,
    mask: u64,
    cost: f64 = 1.0,
};

/// Greedy weighted max-coverage over at most 64 query chunks. This is the
/// persisted-codebook sibling of `greedyPack`: same deterministic selection
/// and accounting, with a compact mask replacing fingerprint lookups.
pub fn greedyMasks(
    gpa: std.mem.Allocator,
    candidates: []const MaskCandidate,
    weights: []const f64,
    paths: []const []const u8,
    limit: usize,
) ![]Pick {
    const storage = try gpa.dupe(MaskCandidate, candidates);
    defer gpa.free(storage);
    var remaining = storage;
    var picks: std.ArrayList(Pick) = .empty;
    errdefer picks.deinit(gpa);
    var covered: u64 = 0;
    var covered_bits: f64 = 0.0;

    while (picks.items.len < limit) {
        var best: ?usize = null;
        var best_gain: f64 = 0.0;
        var best_utility: f64 = 0.0;
        for (remaining, 0..) |candidate, i| {
            const novel = candidate.mask & ~covered;
            var gain: f64 = 0.0;
            for (weights, 0..) |weight, bit|
                if (novel & (@as(u64, 1) << @intCast(bit)) != 0) {
                    gain += weight;
                };
            const utility = gain / @max(candidate.cost, 1.0);
            const better = utility > best_utility or
                (utility == best_utility and gain > best_gain) or
                (utility == best_utility and gain == best_gain and gain > 0.0 and best != null and
                    std.mem.order(u8, paths[candidate.doc], paths[remaining[best.?].doc]) == .lt);
            if (better) {
                best = i;
                best_gain = gain;
                best_utility = utility;
            }
        }
        const i = best orelse break;
        const chosen = remaining[i];
        covered |= chosen.mask;
        covered_bits += best_gain;
        try picks.append(gpa, .{
            .doc = chosen.doc,
            .marginal_bits = best_gain,
            .covered_bits = covered_bits,
        });
        remaining[i] = remaining[remaining.len - 1];
        remaining = remaining[0 .. remaining.len - 1];
    }
    return picks.toOwnedSlice(gpa);
}

/// Greedy weighted max-coverage over lexicon fingerprint sets; lazy order
/// inside. Stops at `limit` picks or when nothing adds priced bits.
/// Deterministic: ties break toward the lexicographically-smaller path.
pub fn greedyPack(
    gpa: std.mem.Allocator,
    lex: *const lexicon.Lexicon,
    paths: []const []const u8,
    query_fps: []const u64,
    limit: usize,
) ![]Pick {
    // Shortlist: only docs holding ≥1 priced query fingerprint can ever gain.
    const Cand = struct {
        doc: u32,
        bound: f64, // stale upper bound on the marginal (submodular ⇒ sound)
    };
    var cands: std.ArrayList(Cand) = .empty;
    defer cands.deinit(gpa);
    for (0..lex.docCount()) |d| {
        const bits = lex.bitsSaved(query_fps, @intCast(d));
        if (bits > 0.0) try cands.append(gpa, .{ .doc = @intCast(d), .bound = bits });
    }

    var covered: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer covered.deinit(gpa);

    var picks: std.ArrayList(Pick) = .empty;
    errdefer picks.deinit(gpa);
    var covered_bits: f64 = 0.0;

    while (picks.items.len < limit and cands.items.len > 0) {
        // Lazy greedy (Minoux 1978): stale bounds are sound under submodularity
        // (marginals only shrink), so skip recompute when bound < running best.
        // Ties still recompute — the path tie-break must see them.
        var best: ?usize = null;
        var best_gain: f64 = 0.0;
        for (cands.items, 0..) |*c, ci| {
            if (best != null and c.bound < best_gain) continue;
            var gain: f64 = 0.0;
            for (query_fps) |fp| {
                if (covered.contains(fp)) continue;
                if (lex.docHasFingerprint(c.doc, fp)) gain += lex.fingerprintBits(fp);
            }
            c.bound = gain;
            if (gain <= 0.0) continue;
            const better = best == null or gain > best_gain or
                (gain == best_gain and std.mem.order(u8, paths[c.doc], paths[cands.items[best.?].doc]) == .lt);
            if (better) {
                best_gain = gain;
                best = ci;
            }
        }
        const bi = best orelse break;
        if (best_gain <= 0.0) break;
        const doc = cands.items[bi].doc;
        for (query_fps) |fp| {
            if (covered.contains(fp)) continue;
            if (lex.docHasFingerprint(doc, fp) and lex.fingerprintBits(fp) > 0.0)
                try covered.put(gpa, fp, {});
        }
        covered_bits += best_gain;
        try picks.append(gpa, .{ .doc = doc, .marginal_bits = best_gain, .covered_bits = covered_bits });
        _ = cands.swapRemove(bi);
    }
    return picks.toOwnedSlice(gpa);
}

// ── tests ──────────────────────────────────────────────────────────────────

const t = std.testing;

test "greedyMasks prefers focused references and drops covered duplicates" {
    const candidates = [_]MaskCandidate{
        .{ .doc = 0, .mask = 0b01, .cost = 8 },
        .{ .doc = 1, .mask = 0b01, .cost = 2 },
        .{ .doc = 2, .mask = 0b10, .cost = 2 },
    };
    const paths = [_][]const u8{ "large", "focused", "complement" };
    const picks = try greedyMasks(t.allocator, &candidates, &.{ 4, 3 }, &paths, 8);
    defer t.allocator.free(picks);

    try t.expectEqual(@as(usize, 2), picks.len);
    try t.expectEqual(@as(u32, 1), picks[0].doc);
    try t.expectEqual(@as(u32, 2), picks[1].doc);
    try t.expectEqual(@as(f64, 7), picks[1].covered_bits);
}

test "greedyPack: a duplicate of a pick gains nothing and is never picked" {
    const gpa = t.allocator;
    const q = "the quick brown fox jumps over the lazy dog";
    // a and b are byte-identical twins of the query; c shares no 8-gram with
    // it (and any gram it did share would sit in all three docs — price 0).
    const docs = [_][]const u8{ q, q, "zig build graph plumbing notes 0123456789" };
    const paths = [_][]const u8{ "a.txt", "b.txt", "c.txt" };

    var lex = try lexicon.Lexicon.build(gpa, &docs);
    defer lex.deinit();
    const qfps = try lexicon.fingerprints(gpa, q);
    defer gpa.free(qfps);

    const picks = try greedyPack(gpa, &lex, &paths, qfps, 8);
    defer gpa.free(picks);

    // The twins tie on gain, the lexicographically-smaller path wins, and
    // the surviving twin's marginal collapses to zero — one pick total.
    try t.expectEqual(@as(usize, 1), picks.len);
    try t.expectEqual(@as(u32, 0), picks[0].doc);
    try t.expect(picks[0].marginal_bits > 0.0);
    try t.expectEqual(picks[0].marginal_bits, picks[0].covered_bits);
}

test "greedyPack: marginal accounting over disjoint halves, monotone gains" {
    const gpa = t.allocator;
    // Distinct alphabets keep the halves fingerprint-disjoint (no shared
    // 8-byte run); junction-straddling query grams live in no doc (price 0).
    const x = "alpha beta gamma delta epsilon zeta eta theta";
    const y = "0123456789 ABCDEFGHIJ KLMNOPQRST UVWXYZ-9876";
    const q = x ++ " " ++ y;
    const docs = [_][]const u8{ x, y, x, "unrelated filler ....... filler unrelated" };
    const paths = [_][]const u8{ "x1.txt", "y.txt", "x2.txt", "z.txt" };

    var lex = try lexicon.Lexicon.build(gpa, &docs);
    defer lex.deinit();
    const qfps = try lexicon.fingerprints(gpa, q);
    defer gpa.free(qfps);

    const picks = try greedyPack(gpa, &lex, &paths, qfps, 8);
    defer gpa.free(picks);

    // One pick per half; the x-duplicate (doc 2) never makes the cut.
    try t.expectEqual(@as(usize, 2), picks.len);
    var saw_x = false;
    var saw_y = false;
    var cum: f64 = 0.0;
    for (picks, 0..) |p, k| {
        try t.expect(p.doc != 2 and p.doc != 3);
        if (p.doc == 0) saw_x = true;
        if (p.doc == 1) saw_y = true;
        cum += p.marginal_bits;
        try t.expectApproxEqAbs(cum, p.covered_bits, 1e-9);
        // Greedy order: marginals never grow pick over pick.
        if (k > 0) try t.expect(p.marginal_bits <= picks[k - 1].marginal_bits);
    }
    try t.expect(saw_x and saw_y);

    // The pick budget is a hard cap, not a hint.
    const capped = try greedyPack(gpa, &lex, &paths, qfps, 1);
    defer gpa.free(capped);
    try t.expectEqual(@as(usize, 1), capped.len);
}

test "greedyPack: an all-foreign query packs nothing" {
    const gpa = t.allocator;
    const docs = [_][]const u8{"alpha beta gamma delta epsilon"};
    const paths = [_][]const u8{"a.txt"};

    var lex = try lexicon.Lexicon.build(gpa, &docs);
    defer lex.deinit();
    const qfps = try lexicon.fingerprints(gpa, "0123456789ABCDEFGHIJ0123456789");
    defer gpa.free(qfps);

    const picks = try greedyPack(gpa, &lex, &paths, qfps, 8);
    defer gpa.free(picks);
    try t.expectEqual(@as(usize, 0), picks.len);
}
