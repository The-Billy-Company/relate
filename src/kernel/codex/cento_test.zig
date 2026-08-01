//! cento adversarial suite — Ziv–Merhav cross-parse vs a greedy oracle.
//!
//! Extracted from the FM-index suite when the index moved into `irregex`:
//! cento stays here (relate's quotation math) and builds a live Codex from
//! `@import("irregex")` for each case.

const std = @import("std");
const Codex = @import("irregex").codex.index.Codex;
const cento = @import("cento.zig");

const testing = std.testing;

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

/// Longest suffix of `q[0..end)` occurring in `text`, by brute force.
fn oracleLongestSuffix(text: []const u8, q: []const u8, end: usize) usize {
    var l: usize = @min(end, text.len);
    while (l > 0) : (l -= 1) {
        if (std.mem.indexOf(u8, text, q[end - l .. end]) != null) return l;
    }
    return 0;
}

/// The greedy right-to-left maximal parse, straight off the definition.
fn expectCentoMatchesOracle(gpa: std.mem.Allocator, cx: *const Codex, text: []const u8, q: []const u8) !void {
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
        var cx = try Codex.build(gpa, case.text, .{ .sample_rate = 0 });
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
        var cx = try Codex.build(gpa, text, .{ .sample_rate = 0 });
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
    var cx = try Codex.build(gpa, text.items, .{ .sample_rate = 0 });
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
