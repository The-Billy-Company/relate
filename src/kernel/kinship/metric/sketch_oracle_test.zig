//! irregex sketch — EXTERNAL differential oracles for the LZJD kinship metric.
//!
//! `sketch_test.zig` proves the distance's PROPERTIES (identity, symmetry,
//! range, cluster-by-kind). This file proves the number is the RIGHT number,
//! against three references the sketch never computes for itself:
//!
//!   1. build() == the EXACT bottom-k of the true LZ78 phrase-hash set,
//!      computed offline with a std hash map + sort — a different algorithm
//!      than the online open-addressed dictionary + max-heap under test. The
//!      match is byte-exact (zero tolerance): a streaming-top-k vs
//!      sort-then-truncate differential that catches any heap / probe / reset /
//!      min_phrase / finalize bug in construction.
//!   2. distance() ≈ the true SET Jaccard the KMV estimator only samples. On
//!      inputs whose sketches saturate (len == k) the estimate must land within
//!      the k=128 standard error of the exact Jaccard (measured independently,
//!      not bottom-k).
//!   3. distance() ranks kinship the same way a real compressor's NCD does
//!      (actual deflate bytes via std.compress.flate) — the headline claim from
//!      the source papers ("Same signal as NCD"). LZJD ≠ NCD numerically, so
//!      the external claim is honestly a RANK claim; that is what we assert.
//!
//! Only the CONTRACT is shared with the implementation (FNV-1a + splitmix64
//! finalize + min_phrase = 3 — the definition of a phrase's identity). The
//! sampling machinery under test (PhraseSet, BottomK, kmvDistance) is never
//! reused here; it is re-derived offline or replaced by an external compressor.

const std = @import("std");
const sketch = @import("sketch.zig");
const mix = @import("irregex").inner.math.mix;
const flate = std.compress.flate;
const Writer = std.Io.Writer;

const gpa = std.testing.allocator;

// ── reference 1: the exact LZ78 phrase-hash set (offline, std hash map) ──

const HashSet = std.AutoHashMap(u64, void);

/// The EXACT set the sketch samples: every distinct first-seen LZ78 phrase
/// hash whose phrase is ≥ min_phrase bytes, finalized. Built with a std hash
/// map keyed on the raw FNV accumulator (the LZ78 dictionary) — no bottom-k, no
/// open addressing, no heap. This is the ground truth `build()` approximates.
fn exactSet(a: std.mem.Allocator, bytes: []const u8) !HashSet {
    var dict = HashSet.init(a);
    defer dict.deinit();
    var out = HashSet.init(a);
    errdefer out.deinit();
    var h: u64 = mix.fnv_offset;
    var plen: usize = 0;
    for (bytes) |b| {
        h = (h ^ b) *% mix.fnv_prime;
        plen += 1;
        if ((try dict.getOrPut(h)).found_existing) continue; // extend the phrase
        if (plen >= sketch.min_phrase) try out.put(mix.finalize(h), {});
        h = mix.fnv_offset; // phrase complete — start the next one
        plen = 0;
    }
    return out;
}

/// The exact set's members, ascending — the offline analogue of the sketch's
/// slots before bottom-k truncation. Caller frees.
fn sortedMembers(a: std.mem.Allocator, set: *HashSet) ![]u64 {
    const xs = try a.alloc(u64, set.count());
    var it = set.keyIterator();
    var i: usize = 0;
    while (it.next()) |k| : (i += 1) xs[i] = k.*;
    std.mem.sort(u64, xs, {}, comptime std.sort.asc(u64));
    return xs;
}

/// Exact set Jaccard distance: 1 − |A∩B| / |A∪B| over the FULL phrase-hash
/// sets. Matches sketch.kmvDistance's total behavior on the empty cases.
fn exactJaccardDistance(a: *HashSet, b: *HashSet) f64 {
    if (a.count() == 0 and b.count() == 0) return 0.0;
    if (a.count() == 0 or b.count() == 0) return 1.0;
    var inter: usize = 0;
    var it = a.keyIterator();
    while (it.next()) |k| {
        if (b.contains(k.*)) inter += 1;
    }
    const uni = a.count() + b.count() - inter;
    return 1.0 - @as(f64, @floatFromInt(inter)) / @as(f64, @floatFromInt(uni));
}

// ── reference 3: normalized compression distance from a real deflate stream ──

/// Length in bytes of `input` under raw deflate (no container header, so the
/// measured length is signal, not framing). The one-shot Zig 0.16 compress
/// idiom: a fixed sink Writer + a max_window_len history buffer.
fn deflateLen(a: std.mem.Allocator, input: []const u8) !usize {
    const sink_buf = try a.alloc(u8, input.len + input.len / 2 + 4096);
    defer a.free(sink_buf);
    const window = try a.alloc(u8, flate.max_window_len);
    defer a.free(window);
    var sink: Writer = .fixed(sink_buf);
    var comp = try flate.Compress.init(&sink, window, .raw, flate.Compress.Options.level_6);
    try comp.writer.writeAll(input);
    try comp.finish();
    return sink.buffered().len;
}

/// NCD(x, y) = (C(xy) − min(C(x), C(y))) / max(C(x), C(y)) — Li & Vitányi's
/// normalized compression distance, the external signal LZJD claims to track.
fn ncd(a: std.mem.Allocator, x: []const u8, y: []const u8) !f64 {
    const cx = try deflateLen(a, x);
    const cy = try deflateLen(a, y);
    const xy = try a.alloc(u8, x.len + y.len);
    defer a.free(xy);
    @memcpy(xy[0..x.len], x);
    @memcpy(xy[x.len..], y);
    const cxy = try deflateLen(a, xy);
    const lo: f64 = @floatFromInt(@min(cx, cy));
    const hi: f64 = @floatFromInt(@max(cx, cy));
    const num = @as(f64, @floatFromInt(cxy)) - lo;
    return @max(num, 0.0) / hi; // guard the rare cxy < lo underflow
}

// ── deterministic corpus generators (fixed seeds → deterministic tests) ──

/// ~`target` bytes of space-separated pseudo-words (length 3–9) over the
/// alphabet `base`..`base+span`. Enough distinct LZ78 phrases to saturate the
/// k=128 sketch when `target` is a few KiB.
fn genText(a: std.mem.Allocator, seed: u64, target: usize, base: u8, span: u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    while (out.items.len < target) {
        const wlen = 3 + r.uintLessThan(u8, 7);
        var i: u8 = 0;
        while (i < wlen) : (i += 1) try out.append(a, base + r.uintLessThan(u8, span));
        try out.append(a, ' ');
    }
    return out.toOwnedSlice(a);
}

/// Copy `base`, replacing `pct`% of its whitespace-delimited words with fresh
/// random words of the same length — a tunable, MEASURED corruption.
fn corruptWords(a: std.mem.Allocator, base: []const u8, pct: u8, seed: u64) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    var it = std.mem.tokenizeScalar(u8, base, ' ');
    var first = true;
    while (it.next()) |word| {
        if (!first) try out.append(a, ' ');
        first = false;
        if (r.uintLessThan(u8, 100) < pct) {
            for (word) |_| try out.append(a, 'a' + r.uintLessThan(u8, 26));
        } else try out.appendSlice(a, word);
    }
    return out.toOwnedSlice(a);
}

// A short real-code fixture (fewer than k phrases) exercises the len < k path.
const small_src =
    \\const std = @import("std");
    \\pub fn add(a: i32, b: i32) i32 { return a + b; }
    \\test "add" { try std.testing.expectEqual(3, add(1, 2)); }
;

// ── the oracles ──

test "build() is exactly the bottom-k of the true LZ78 phrase-hash set" {
    // Offline ground truth: parse → full distinct set → sort → keep the k
    // smallest. The online heap + open-addressed dictionary in build() must
    // reproduce it exactly, both under the slot budget (small_src) and well
    // over it (16 KiB generated), where the bottom-k truncation is load-bearing.
    const big = try genText(gpa, 0xA11CE, 16 * 1024, 'a', 26);
    defer gpa.free(big);
    const fixtures = [_][]const u8{ small_src, big };

    for (fixtures) |x| {
        var set = try exactSet(gpa, x);
        defer set.deinit();
        const members = try sortedMembers(gpa, &set);
        defer gpa.free(members);
        const want = members[0..@min(members.len, sketch.k)];

        var s = try sketch.build(gpa, x);
        try std.testing.expectEqualSlices(u64, want, s.slots());
    }
}

test "three independent signals rank kinship identically (LZJD ≈ set-Jaccard ≈ NCD)" {
    // A base corpus and three neighbors at increasing true distance: a light
    // edit, a heavy edit, and an unrelated text over a disjoint alphabet. The
    // sketch estimate, the EXACT set Jaccard, and a real deflate NCD must agree
    // on the ordering — and where both sketches saturate, the estimate must sit
    // within the k=128 standard error of the exact Jaccard it samples.
    const base = try genText(gpa, 0xB0BA, 20 * 1024, 'a', 26);
    defer gpa.free(base);
    const near = try corruptWords(gpa, base, 5, 0x5EED);
    defer gpa.free(near);
    const mid = try corruptWords(gpa, base, 50, 0x11FE);
    defer gpa.free(mid);
    const far = try genText(gpa, 0xFA2, 20 * 1024, 'A', 26); // disjoint alphabet
    defer gpa.free(far);

    var base_set = try exactSet(gpa, base);
    defer base_set.deinit();
    var base_sk = try sketch.build(gpa, base);

    const Row = struct { d_sketch: f64, d_jac: f64, d_ncd: f64, saturated: bool };
    const neighbors = [_][]const u8{ near, mid, far };
    var rows: [neighbors.len]Row = undefined;

    for (neighbors, 0..) |txt, i| {
        var nset = try exactSet(gpa, txt);
        defer nset.deinit();
        var nsk = try sketch.build(gpa, txt);
        rows[i] = .{
            .d_sketch = sketch.distance(&base_sk, &nsk),
            .d_jac = exactJaccardDistance(&base_set, &nset),
            .d_ncd = try ncd(gpa, base, txt),
            .saturated = base_sk.len == sketch.k and nsk.len == sketch.k,
        };
        // Faithfulness: the KMV estimate tracks the exact Jaccard it samples.
        // SE ≈ 1/√k ≈ 0.088; 0.15 is a > 1.7σ band a correct estimator always
        // clears but a broken budget / heap / merge could not.
        if (rows[i].saturated)
            try std.testing.expect(@abs(rows[i].d_sketch - rows[i].d_jac) <= 0.15);
    }

    // Strict rank agreement across all three references: near < mid < far.
    for (rows[0 .. rows.len - 1], rows[1..]) |lo, hi| {
        try std.testing.expect(lo.d_sketch < hi.d_sketch);
        try std.testing.expect(lo.d_jac < hi.d_jac);
        try std.testing.expect(lo.d_ncd < hi.d_ncd);
    }

    // Magnitudes diverge even as ranks agree, exactly as the papers claim.
    // The external compressor's sliding window realigns after each scattered
    // edit and reads the light 5% change as close kinship (NCD < 0.5); LZJD's
    // LZ78 phrase boundaries cascade-desync at every edit, so it reads the same
    // change as further — the RANK is preserved, the numeric value is not. The
    // disjoint-alphabet text is near-maximal in BOTH references.
    try std.testing.expect(rows[0].d_ncd < 0.5);
    try std.testing.expect(rows[2].d_sketch > 0.9 and rows[2].d_ncd > 0.9);
}
