//! codex adversarial suite — every layer differential against a naive oracle.
//!
//! Nothing here asserts a value the implementation produced for itself
//! (sins.mdc / ADR-327 oracle discipline): suffix arrays are checked against a
//! comparison-sort oracle, ranks against prefix popcounts, occ/access against
//! literal scans, and the index's count/find/restore against std.mem searches
//! of the original text — across random, degenerate, binary, and highly
//! repetitive corpora, plus a seeded property-fuzz loop.

const std = @import("std");
const fault = @import("../../../fault.zig");
const sais = @import("sais.zig");
const rrr = @import("rrr.zig");
const wavelet = @import("wavelet.zig");
const codex = @import("codex.zig");
const cento = @import("cento.zig");
const shelf_mod = @import("shelf.zig");

const testing = std.testing;

// ── oracles ──

/// O(n² log n) suffix array by direct suffix comparison (with sentinel).
fn oracleSuffixArray(gpa: std.mem.Allocator, text: []const u8) ![]u32 {
    const n = text.len + 1;
    const sa = try gpa.alloc(u32, n);
    for (sa, 0..) |*v, i| v.* = @intCast(i);
    const Ctx = struct {
        text: []const u8,
        fn lt(self: @This(), a: u32, b: u32) bool {
            // sentinel: the shorter suffix wins when one is a prefix of the other
            const sa_ = self.text[a..];
            const sb_ = self.text[b..];
            return switch (std.mem.order(u8, sa_, sb_)) {
                .lt => true,
                .gt => false,
                .eq => sa_.len < sb_.len,
            };
        }
    };
    std.mem.sort(u32, sa, Ctx{ .text = text }, Ctx.lt);
    return sa;
}

fn oracleCount(text: []const u8, pattern: []const u8) usize {
    if (pattern.len == 0) return 0;
    var c: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, pattern)) |p| {
        c += 1;
        i = p + 1;
    }
    return c;
}

fn oracleFind(gpa: std.mem.Allocator, text: []const u8, pattern: []const u8) ![]u32 {
    var out: std.ArrayList(u32) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    if (pattern.len > 0) while (std.mem.indexOfPos(u8, text, i, pattern)) |p| {
        try out.append(gpa, @intCast(p));
        i = p + 1;
    };
    return out.toOwnedSlice(gpa);
}

fn expectSaisMatchesOracle(text: []const u8) !void {
    const gpa = testing.allocator;
    const got = try sais.build(gpa, text);
    defer gpa.free(got);
    const want = try oracleSuffixArray(gpa, text);
    defer gpa.free(want);
    try testing.expectEqualSlices(u32, want, got);
}

// ── sais ──

test "sais: degenerate and adversarial texts match the sort oracle" {
    try expectSaisMatchesOracle("");
    try expectSaisMatchesOracle("a");
    try expectSaisMatchesOracle("aaaaaaaaaaaaaaaa"); // single-class runs
    try expectSaisMatchesOracle("abababababababab"); // period 2 — LMS naming collisions
    try expectSaisMatchesOracle("banana");
    try expectSaisMatchesOracle("mississippi");
    try expectSaisMatchesOracle("abaababaabaababaababa"); // Fibonacci word — worst-case LMS recursion
    try expectSaisMatchesOracle("zyxwvutsrqponmlkjihgfedcba"); // strictly descending: all L
    try expectSaisMatchesOracle("abcdefghijklmnopqrstuvwxyz"); // strictly ascending: all S
    try expectSaisMatchesOracle("\x00\x00\x01\x00\x00"); // NUL is ordinary content
    try expectSaisMatchesOracle("\xff\xfe\xff\xfe\x00\xff");
}

test "sais: all 256 byte values, forwards and backwards" {
    var buf: [512]u8 = undefined;
    for (0..256) |i| {
        buf[i] = @intCast(i);
        buf[511 - i] = @intCast(i);
    }
    try expectSaisMatchesOracle(buf[0..256]);
    try expectSaisMatchesOracle(&buf);
}

test "sais: property — random texts across alphabet sizes match the oracle" {
    var prng = std.Random.DefaultPrng.init(0x5a15);
    const rand = prng.random();
    const gpa = testing.allocator;
    for (0..60) |round| {
        const sigma: u8 = ([_]u8{ 1, 2, 3, 8, 255 })[round % 5];
        const len = rand.intRangeAtMost(usize, 0, 400);
        const text = try gpa.alloc(u8, len);
        defer gpa.free(text);
        for (text) |*c| c.* = rand.intRangeAtMost(u8, 0, sigma);
        try expectSaisMatchesOracle(text);
    }
}

// ── rrr ──

fn expectBitsMatchOracle(bits: anytype, want: []const u1) !void {
    var ones: usize = 0;
    for (want, 0..) |b, i| {
        try testing.expectEqual(ones, bits.rank1(i));
        try testing.expectEqual(b, bits.get(i));
        ones += b;
    }
    try testing.expectEqual(ones, bits.rank1(want.len));
}

test "rrr: rank/get at every position, all densities, boundary lengths" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xb17);
    const rand = prng.random();
    // lengths straddle block (63) and superblock (1008) boundaries
    for ([_]usize{ 1, 62, 63, 64, 126, 127, 512, 1007, 1008, 1009, 5000 }) |len| {
        for ([_]f64{ 0.0, 0.01, 0.5, 0.99, 1.0 }) |density| {
            const want = try gpa.alloc(u1, len);
            defer gpa.free(want);
            var plain = try rrr.Plain.initEmpty(gpa, len);
            defer plain.deinit(gpa);
            for (want, 0..) |*b, i| {
                b.* = @intFromBool(rand.float(f64) < density);
                if (b.* == 1) plain.set(i);
            }
            try plain.finalize(gpa);
            // check the plain encoding, then force-transcode and check RRR too:
            // both encodings must agree with the oracle bit-for-bit
            try expectBitsMatchOracle(&plain, want);
            var enc = try rrr.Rrr.fromPlain(gpa, &plain);
            defer enc.deinit(gpa);
            try expectBitsMatchOracle(&enc, want);
        }
    }
}

test "rrr: adopt never loses space and compresses runs hard" {
    const gpa = testing.allocator;
    // run-heavy vector (BWT-shaped): RRR must win and stay correct
    const len = 100_000;
    var plain = try rrr.Plain.initEmpty(gpa, len);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if ((i / 3000) % 2 == 1) plain.set(i);
    }
    try plain.finalize(gpa);
    const plain_bytes = plain.sizeBytes();
    var bits = try rrr.Bits.adopt(gpa, plain);
    defer bits.deinit(gpa);
    try testing.expect(bits.sizeBytes() <= plain_bytes);
    try testing.expect(bits == .rrr or bits.sizeBytes() == plain_bytes);
    try testing.expect(bits.sizeBytes() < plain_bytes / 4); // runs price near zero
    // spot-verify semantics survived the transcode
    try testing.expectEqual(@as(usize, 0), bits.rank1(3000));
    try testing.expectEqual(@as(usize, 3000), bits.rank1(6000));
    try testing.expectEqual(@as(u1, 1), bits.get(3000));
    try testing.expectEqual(@as(u1, 0), bits.get(2999));
}

// ── wavelet ──

test "wavelet: occ and access match literal scans across alphabet shapes and encodings" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x3a7e);
    const rand = prng.random();
    for ([_]u16{ 1, 2, 5, 257 }) |sigma| {
        const seq = try gpa.alloc(u16, 3000);
        defer gpa.free(seq);
        var freq = try gpa.alloc(u64, sigma);
        defer gpa.free(freq);
        @memset(freq, 0);
        for (seq) |*c| {
            c.* = rand.intRangeLessThan(u16, 0, sigma);
            freq[c.*] += 1;
        }
        const encoding: wavelet.Encoding = if (sigma % 2 == 0) .plain_only else .adopt_min;
        var tree = try wavelet.Tree.build(gpa, seq, freq, encoding);
        defer tree.deinit(gpa);
        // access at every position; occ for every present symbol at sampled cuts
        var counts = try gpa.alloc(usize, sigma);
        defer gpa.free(counts);
        @memset(counts, 0);
        for (seq, 0..) |c, pos| {
            const a = tree.access(pos);
            try testing.expectEqual(c, a.sym);
            try testing.expectEqual(counts[c], a.occ);
            counts[c] += 1;
        }
        for (0..sigma) |sym| {
            if (freq[sym] == 0) continue;
            var running: usize = 0;
            for (seq, 0..) |c, pos| {
                if (pos % 251 == 0) try testing.expectEqual(running, tree.occ(@intCast(sym), pos));
                if (c == sym) running += 1;
            }
            try testing.expectEqual(running, tree.occ(@intCast(sym), seq.len));
        }
    }
}

// ── codex end-to-end ──

fn expectCodexFaithful(text: []const u8, opts: codex.Options, patterns: []const []const u8) !void {
    const gpa = testing.allocator;
    var idx = try codex.Codex.build(gpa, text, opts);
    defer idx.deinit(gpa);

    const rebuilt = try idx.restore(gpa);
    defer gpa.free(rebuilt);
    try testing.expectEqualSlices(u8, text, rebuilt);

    for (patterns) |p| {
        try testing.expectEqual(oracleCount(text, p), idx.count(p));
        if (opts.sample_rate > 0) {
            const got = (try idx.find(gpa, p)).got;
            defer gpa.free(got);
            const want = try oracleFind(gpa, text, p);
            defer gpa.free(want);
            try testing.expectEqualSlices(u32, want, got);
        }
    }
}

test "codex: exact count/find/restore on adversarial corpora" {
    const overlapping = "aaaaaaaaaaaaaaaaaaaa";
    try expectCodexFaithful(overlapping, .{}, &.{ "a", "aa", "aaa", overlapping, "b", "" });
    try expectCodexFaithful("mississippi", .{ .sample_rate = 1 }, &.{ "i", "issi", "ssi", "mississippi", "mississippix", "p", "x" });
    try expectCodexFaithful("", .{}, &.{ "", "a" });
    try expectCodexFaithful("x", .{}, &.{ "x", "y", "xx" });
    // binary corpus: NULs and high bytes are ordinary content
    try expectCodexFaithful("\x00\x01\xff\x00\x01\xff\x00", .{ .sample_rate = 2 }, &.{ "\x00", "\x00\x01\xff", "\xff\x00", "\x02" });
    // both bitvector postures answer identically
    try expectCodexFaithful("the quick brown fox jumps over the lazy dog", .{ .encoding = .plain_only }, &.{ "the", "o", "quick brown", "cat" });
}

test "codex: pattern longer than text and whole-text pattern" {
    const gpa = testing.allocator;
    var idx = try codex.Codex.build(gpa, "short", .{});
    defer idx.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), idx.count("much longer than the text"));
    try testing.expectEqual(@as(usize, 1), idx.count("short"));
}

test "codex: sample_rate 0 disables locate but keeps count/restore" {
    const gpa = testing.allocator;
    var idx = try codex.Codex.build(gpa, "count only", .{ .sample_rate = 0 });
    defer idx.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), idx.count("o"));
    // Locate DECLINES rather than faulting: a mark-less codex is a smaller
    // index, not a broken one, and it still counts exactly (ADR-373 law 1).
    try testing.expectEqual(fault.Decline.capability_missing, (try idx.find(gpa, "o")).declined);
    try testing.expectEqual(fault.Decline.capability_missing, idx.posOf(0).declined);
    const rebuilt = try idx.restore(gpa);
    defer gpa.free(rebuilt);
    try testing.expectEqualSlices(u8, "count only", rebuilt);
}

test "codex: property fuzz — random corpora, sampled + mutated patterns" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xc0dec5);
    const rand = prng.random();
    for (0..25) |round| {
        const sigma: u8 = ([_]u8{ 2, 4, 26, 255 })[round % 4];
        const len = rand.intRangeAtMost(usize, 1, 2048);
        const text = try gpa.alloc(u8, len);
        defer gpa.free(text);
        for (text) |*c| c.* = rand.intRangeAtMost(u8, 0, sigma);
        const rate: u32 = ([_]u32{ 1, 7, 32 })[round % 3];
        var idx = try codex.Codex.build(gpa, text, .{ .sample_rate = rate });
        defer idx.deinit(gpa);

        const rebuilt = try idx.restore(gpa);
        defer gpa.free(rebuilt);
        try testing.expectEqualSlices(u8, text, rebuilt);

        var pat_buf: [64]u8 = undefined;
        for (0..20) |_| {
            const m = rand.intRangeAtMost(usize, 1, @min(text.len, pat_buf.len));
            const start = rand.intRangeAtMost(usize, 0, text.len - m);
            @memcpy(pat_buf[0..m], text[start .. start + m]);
            // half the probes are mutated — usually absent, sometimes still present
            if (rand.boolean()) pat_buf[rand.intRangeLessThan(usize, 0, m)] +%= 1;
            const p = pat_buf[0..m];
            try testing.expectEqual(oracleCount(text, p), idx.count(p));
            const got = (try idx.find(gpa, p)).got;
            defer gpa.free(got);
            const want = try oracleFind(gpa, text, p);
            defer gpa.free(want);
            try testing.expectEqualSlices(u32, want, got);
        }
    }
}

// ── persistence ──

test "codex: save/load round-trip is behaviorally identical, both postures" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5afe);
    const rand = prng.random();
    const corpora = [_][]const u8{
        "mississippi",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "\x00\x01\xff\x00\x01\xff\x00",
        "the quick brown fox jumps over the lazy dog",
    };
    for (corpora) |text| {
        for ([_]wavelet.Encoding{ .adopt_min, .plain_only }) |enc| {
            for ([_]u32{ 0, 4 }) |rate| {
                var built = try codex.Codex.build(gpa, text, .{ .sample_rate = rate, .encoding = enc });
                defer built.deinit(gpa);
                const blob = try built.save(gpa);
                defer gpa.free(blob);
                var loaded = try codex.Codex.load(gpa, blob);
                defer loaded.deinit(gpa);

                try testing.expectEqual(built.len(), loaded.len());
                try testing.expectEqual(built.stats.index_bytes, loaded.stats.index_bytes);
                const rebuilt = try loaded.restore(gpa);
                defer gpa.free(rebuilt);
                try testing.expectEqualSlices(u8, text, rebuilt);

                // probe with present substrings and mutated (usually absent) ones
                var pat_buf: [16]u8 = undefined;
                for (0..24) |_| {
                    const m = rand.intRangeAtMost(usize, 1, @min(text.len, pat_buf.len));
                    const start = rand.intRangeAtMost(usize, 0, text.len - m);
                    @memcpy(pat_buf[0..m], text[start .. start + m]);
                    if (rand.boolean()) pat_buf[rand.intRangeLessThan(usize, 0, m)] +%= 1;
                    const p = pat_buf[0..m];
                    try testing.expectEqual(oracleCount(text, p), loaded.count(p));
                    if (rate > 0) {
                        const got = (try loaded.find(gpa, p)).got;
                        defer gpa.free(got);
                        const want = try oracleFind(gpa, text, p);
                        defer gpa.free(want);
                        try testing.expectEqualSlices(u32, want, got);
                    }
                }
            }
        }
    }
}

test "codex: load fails closed on truncation, bit rot, and wrong magic" {
    const gpa = testing.allocator;
    var built = try codex.Codex.build(gpa, "integrity is not optional", .{});
    defer built.deinit(gpa);
    const blob = try built.save(gpa);
    defer gpa.free(blob);

    // sanity: the pristine blob loads
    var ok = try codex.Codex.load(gpa, blob);
    ok.deinit(gpa);

    // every truncation must be rejected, never crash or half-load
    var trunc = try gpa.dupe(u8, blob);
    defer gpa.free(trunc);
    var cut: usize = 0;
    while (cut < blob.len) : (cut += @max(blob.len / 37, 1)) {
        try testing.expectError(error.Corrupt, codex.Codex.load(gpa, trunc[0..cut]));
    }

    // single flipped bit anywhere: the checksum fails closed
    var prng = std.Random.DefaultPrng.init(0xb17f11f);
    const rand = prng.random();
    for (0..50) |_| {
        const at = rand.intRangeLessThan(usize, 0, blob.len);
        trunc[at] ^= @as(u8, 1) << rand.int(u3);
        try testing.expectError(error.Corrupt, codex.Codex.load(gpa, trunc));
        trunc[at] = blob[at]; // restore for the next probe
    }

    var bad_magic = try gpa.dupe(u8, blob);
    defer gpa.free(bad_magic);
    bad_magic[0] = 'X';
    try testing.expectError(error.Corrupt, codex.Codex.load(gpa, bad_magic));
}

// ── shelf (multi-document tier) ──

test "shelf: count and tally match per-document oracles, through save/load" {
    const gpa = testing.allocator;
    const docs = [_][]const u8{
        "the quick brown fox",
        "fox fox fox",
        "no relation at all",
        "quick quick",
        "", // empty document is legal
    };
    const paths = [_][]const u8{ "a/one.txt", "b/two.txt", "c/three.txt", "d/four.txt", "e/empty.txt" };
    var built = try shelf_mod.Shelf.build(gpa, &docs, &paths, 42, .{ .sample_rate = 4 });
    defer built.deinit(gpa);
    const blob = try built.save(gpa);
    defer gpa.free(blob);
    var shelf = try shelf_mod.Shelf.load(gpa, blob);
    defer shelf.deinit(gpa);

    try testing.expectEqual(@as(i64, 42), shelf.built_ns);
    try testing.expectEqual(paths.len, shelf.paths.len);
    for (paths, shelf.paths) |want, got| try testing.expectEqualStrings(want, got);

    for ([_][]const u8{ "fox", "quick", "o", "zebra", " " }) |pat| {
        // corpus-wide count == Σ per-doc oracle counts (patterns carry no '\n',
        // so the sentinel guarantees no cross-document match)
        var want_total: usize = 0;
        for (&docs) |d| want_total += oracleCount(d, pat);
        try testing.expectEqual(want_total, shelf.count(pat));

        const t = (try shelf.tally(gpa, pat)).got;
        defer gpa.free(t);
        var tallied: usize = 0;
        for (t, 0..) |dc, i| {
            try testing.expectEqual(oracleCount(docs[dc.doc], pat), dc.count);
            try testing.expect(dc.count > 0); // only matching docs appear
            if (i > 0) try testing.expect(t[i - 1].count >= dc.count); // heaviest first
            tallied += dc.count;
        }
        try testing.expectEqual(want_total, tallied);
    }
}

test "shelf: docOf maps every corpus position to its document" {
    const gpa = testing.allocator;
    const docs = [_][]const u8{ "aa", "b", "cccc" };
    const paths = [_][]const u8{ "one", "two", "three" };
    var shelf = try shelf_mod.Shelf.build(gpa, &docs, &paths, 0, .{ .sample_rate = 1 });
    defer shelf.deinit(gpa);
    // layout: aa\n b\n cccc\n → doc starts 0, 3, 5
    var pos: u64 = 0;
    for (&docs, 0..) |d, i| {
        for (0..d.len + 1) |_| { // body + its sentinel both belong to doc i
            try testing.expectEqual(@as(u32, @intCast(i)), shelf.docOf(pos));
            pos += 1;
        }
    }
}

test "shelf: load fails closed on framing corruption" {
    const gpa = testing.allocator;
    const docs = [_][]const u8{ "alpha", "beta" };
    const paths = [_][]const u8{ "a", "b" };
    var built = try shelf_mod.Shelf.build(gpa, &docs, &paths, 7, .{});
    defer built.deinit(gpa);
    const blob = try built.save(gpa);
    defer gpa.free(blob);

    var bad = try gpa.dupe(u8, blob);
    defer gpa.free(bad);
    bad[0] = 'X'; // magic
    try testing.expectError(error.Corrupt, shelf_mod.Shelf.load(gpa, bad));
    var cut: usize = 0;
    while (cut < blob.len) : (cut += @max(blob.len / 23, 1)) {
        try testing.expectError(error.Corrupt, shelf_mod.Shelf.load(gpa, blob[0..cut]));
    }
    // bit rot inside the embedded codex blob trips its checksum
    bad[0] = blob[0];
    bad[bad.len - 20] ^= 0x40;
    try testing.expectError(error.Corrupt, shelf_mod.Shelf.load(gpa, bad));
}

// ── cento (cross-parse) ──

/// Longest suffix of `q[0..end)` occurring in `text`, by brute force.
fn oracleLongestSuffix(text: []const u8, q: []const u8, end: usize) usize {
    var l: usize = @min(end, text.len);
    while (l > 0) : (l -= 1) {
        if (std.mem.indexOf(u8, text, q[end - l .. end]) != null) return l;
    }
    return 0;
}

/// The greedy right-to-left maximal parse, straight off the definition.
fn expectCentoMatchesOracle(gpa: std.mem.Allocator, cx: *const codex.Codex, text: []const u8, q: []const u8) !void {
    var got = try cento.parse(cx, gpa, q);
    defer got.deinit(gpa);
    try testing.expectEqual(got.bits, cento.price(cx, q)); // both paths, one answer

    var covered: usize = 0;
    for (got.phrases) |ph| { // contiguous exact cover of the query
        try testing.expectEqual(covered, ph.pos);
        covered += ph.len;
    }
    try testing.expectEqual(q.len, covered);

    var end: usize = q.len;
    var i: usize = got.phrases.len;
    while (end > 0) { // phrase-by-phrase against the brute-force greedy rule
        i -= 1;
        const ph = got.phrases[i];
        const want_len = @max(oracleLongestSuffix(text, q, end), 1);
        try testing.expectEqual(want_len, ph.len);
        const want_width = oracleCount(text, q[end - want_len .. end]);
        try testing.expectEqual(want_width, ph.width);
        end -= want_len;
    }
    try testing.expectEqual(@as(usize, 0), i);
}

test "cento: parse matches the greedy oracle on adversarial pairs" {
    const gpa = testing.allocator;
    const cases = [_]struct { text: []const u8, queries: []const []const u8 }{
        .{ .text = "mississippi", .queries = &.{ "mississippi", "sip", "pip", "xyz", "ippix", "", "m", "imississippim" } },
        .{ .text = "aaaa", .queries = &.{ "aaaaaaaaaaaa", "ab", "ba", "b" } },
        .{ .text = "\x00\x01\xff", .queries = &.{ "\xff\x00\x01", "\x00\x01\xff\x00\x01\xff", "\x02" } },
        .{ .text = "the quick brown fox", .queries = &.{ "the quick red fox", "quick brown", "THE QUICK" } },
    };
    for (cases) |case| {
        var cx = try codex.Codex.build(gpa, case.text, .{ .sample_rate = 0 });
        defer cx.deinit(gpa);
        for (case.queries) |q| try expectCentoMatchesOracle(gpa, &cx, case.text, q);
    }
}

test "cento: property fuzz — random corpus, spliced and mutated queries" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xce470);
    const rand = prng.random();
    for (0..20) |round| {
        const sigma: u8 = ([_]u8{ 2, 4, 26 })[round % 3];
        const text = try gpa.alloc(u8, rand.intRangeAtMost(usize, 1, 800));
        defer gpa.free(text);
        for (text) |*c| c.* = rand.intRangeAtMost(u8, 'a', 'a' + sigma - 1);
        var cx = try codex.Codex.build(gpa, text, .{ .sample_rate = 0 });
        defer cx.deinit(gpa);
        for (0..8) |_| {
            // queries spliced from corpus chunks with random mutations —
            // exercises long quotations, phrase breaks, and literal escapes
            var q: std.ArrayList(u8) = .empty;
            defer q.deinit(gpa);
            while (q.items.len < 120) {
                const m = rand.intRangeAtMost(usize, 1, @min(text.len, 40));
                const start = rand.intRangeAtMost(usize, 0, text.len - m);
                try q.appendSlice(gpa, text[start .. start + m]);
                if (rand.boolean()) try q.append(gpa, rand.int(u8));
            }
            try expectCentoMatchesOracle(gpa, &cx, text, q.items);
        }
    }
}

test "cento: price ranks the corpus's own prose below foreign bytes" {
    const gpa = testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    var prng = std.Random.DefaultPrng.init(11);
    const rand = prng.random();
    const words = [_][]const u8{ "const ", "return ", "self.", "alloc", "defer ", "try ", "pub fn ", "usize" };
    while (text.items.len < 60_000) {
        try text.appendSlice(gpa, words[rand.intRangeLessThan(usize, 0, words.len)]);
    }
    var cx = try codex.Codex.build(gpa, text.items, .{ .sample_rate = 0 });
    defer cx.deinit(gpa);

    const native = text.items[10_000..14_000]; // literally in the corpus
    const kindred = try gpa.dupe(u8, text.items[30_000..34_000]);
    defer gpa.free(kindred);
    for (kindred, 0..) |*c, i| {
        if (i % 97 == 0) c.* +%= 3; // same source, lightly mutated
    }
    const foreign = try gpa.alloc(u8, 4000);
    defer gpa.free(foreign);
    for (foreign) |*c| c.* = rand.int(u8);

    const native_bits = cento.price(&cx, native);
    const kindred_bits = cento.price(&cx, kindred);
    const foreign_bits = cento.price(&cx, foreign);
    // the relatedness order must be strict, with real separation
    try testing.expect(native_bits < kindred_bits);
    try testing.expect(kindred_bits * 2 < foreign_bits);
    // native text quotes in giant phrases: far below its literal 8 bits/byte
    try testing.expect(native_bits / 4000.0 < 1.0);
    // foreign random bytes cannot beat the literal-escape floor by much
    try testing.expect(foreign_bits / 4000.0 > 6.0);
}

test "codex: index measures smaller than raw text on compressible input" {
    const gpa = testing.allocator;
    // realistic compressible text: repeated vocabulary, code-like shape
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    var prng = std.Random.DefaultPrng.init(7);
    const rand = prng.random();
    const words = [_][]const u8{ "const ", "return ", "self.", "alloc", "defer ", "try ", "pub fn ", "usize", "( ", ") {\n", "}\n" };
    while (text.items.len < 200_000) {
        try text.appendSlice(gpa, words[rand.intRangeLessThan(usize, 0, words.len)]);
    }
    var idx = try codex.Codex.build(gpa, text.items, .{ .sample_rate = 0 });
    defer idx.deinit(gpa);
    // count-only index must land well under the raw bytes (entropy-bound space)
    try testing.expect(idx.stats.index_bytes < text.items.len / 2);
    try testing.expectEqual(oracleCount(text.items, "pub fn "), idx.count("pub fn "));
}
