//! silhouette — adversarial tests for the structure channel.
//!
//! The contract under test is what normalization PROMISES, not how the
//! scanner walks: a silhouette must be blind to vocabulary (identifier
//! renames, literal changes, comments, whitespace) and sighted to structure
//! (keywords, punctuation, token order). Expected values derive from those
//! promises — a renamed twin's normalized token stream is IDENTICAL by
//! construction, so its distance must be exactly 0 — never from re-running
//! the code under test on itself. Fixtures are embedded (deterministic under
//! ~10 agents editing the checkout concurrently).

const std = @import("std");
const silhouette = @import("silhouette.zig");
const sketch = @import("sketch.zig");

const gpa = std.testing.allocator;
const t = std.testing;

// ── fixtures: one skeleton, three vocabularies ──
// base and renamed share the exact token-class structure (every identifier
// maps I, every number maps N, every string maps S, keywords + punctuation
// identical); reshaped keeps the vocabulary but changes the SHAPE (loop →
// recursion, different keywords/punctuation).

const base =
    \\pub fn tally(items: []const u32, floor: u32) u32 {
    \\    var total: u32 = 0;
    \\    for (items) |item| {
    \\        if (item > floor) {
    \\            total += item * 2;
    \\        } else {
    \\            total += 1;
    \\        }
    \\    }
    \\    // running tally over the filtered stream
    \\    return total;
    \\}
;

// Same skeleton: identifiers renamed, literals changed, comment reworded.
const renamed =
    \\pub fn reckon(entries: []const u32, cutoff: u32) u32 {
    \\    var acc: u32 = 0;
    \\    for (entries) |entry| {
    \\        if (entry > cutoff) {
    \\            acc += entry * 731;
    \\        } else {
    \\            acc += 99;
    \\        }
    \\    }
    \\    // fold the survivors into the accumulator
    \\    return acc;
    \\}
;

// Same vocabulary as base, different structure (while + early continue).
const reshaped =
    \\pub fn tally(items: []const u32, floor: u32) u32 {
    \\    var total: u32 = 0;
    \\    var i: u32 = 0;
    \\    while (i < items.len) {
    \\        defer i += 1;
    \\        if (items[i] <= floor) {
    \\            total += 1;
    \\            continue;
    \\        }
    \\        total += items[i] * 2;
    \\    }
    \\    return total;
    \\}
;

test "silhouette: deterministic, identity distance 0, symmetric" {
    var a1 = try silhouette.build(gpa, base);
    var a2 = try silhouette.build(gpa, base);
    try t.expectEqualSlices(u64, a1.slots(), a2.slots());
    try t.expectEqual(@as(f64, 0.0), silhouette.distance(&a1, &a2));

    var b = try silhouette.build(gpa, renamed);
    try t.expectEqual(silhouette.distance(&a1, &b), silhouette.distance(&b, &a1));
}

test "silhouette: a renamed twin is EXACTLY distance 0 (the Type-2 promise)" {
    // base and renamed differ in every identifier, literal, and comment —
    // but normalize to the same token stream, so the silhouettes must be
    // identical. This is the property the raw-byte sketch cannot have.
    var a = try silhouette.build(gpa, base);
    var b = try silhouette.build(gpa, renamed);
    try t.expectEqualSlices(u64, a.slots(), b.slots());
    try t.expectEqual(@as(f64, 0.0), silhouette.distance(&a, &b));

    // …and the byte channel indeed sees them as different files (if this
    // ever reads 0, the fixture stopped exercising the vocabulary axis).
    var ra = try sketch.build(gpa, base);
    var rb = try sketch.build(gpa, renamed);
    try t.expect(sketch.distance(&ra, &rb) > 0.05);
}

test "silhouette: comments and whitespace are invisible" {
    const noisy = "// header comment\n\n" ++ base ++ "\n\n/* trailing\n   block */\n";
    var a = try silhouette.build(gpa, base);
    var b = try silhouette.build(gpa, noisy);
    try t.expectEqualSlices(u64, a.slots(), b.slots());
}

test "silhouette: structure change moves the distance, vocabulary does not" {
    var a = try silhouette.build(gpa, base);
    var b = try silhouette.build(gpa, renamed);
    var c = try silhouette.build(gpa, reshaped);
    // Same shape, new words: 0. Same words, new shape: strictly farther.
    const twin = silhouette.distance(&a, &b);
    const shape_shift = silhouette.distance(&a, &c);
    try t.expectEqual(@as(f64, 0.0), twin);
    try t.expect(shape_shift > 0.1);
}

test "silhouette: shared token runs guarantee shared fingerprints (winnow floor)" {
    // Two otherwise-unrelated files embedding the same skeleton must share
    // fingerprints: winnowing guarantees any common run of gram+window−1
    // tokens surfaces in both sets, so the distance cannot be 1.
    const host_a = "const alpha = 1;\n" ++ base ++ "\nconst omega = 2;\n";
    const host_b = "fn unrelated(x: f64) f64 { return x / 3.0; }\n" ++ base;
    var a = try silhouette.build(gpa, host_a);
    var b = try silhouette.build(gpa, host_b);
    try t.expect(silhouette.distance(&a, &b) < 1.0);
}

test "silhouette: empty and too-short inputs degrade cleanly" {
    var none = try silhouette.build(gpa, "");
    const tiny = try silhouette.build(gpa, "x");
    var full = try silhouette.build(gpa, base);
    try t.expectEqual(@as(u16, 0), none.len);
    try t.expectEqual(@as(f64, 0.0), silhouette.distance(&none, &none));
    try t.expectEqual(@as(f64, 1.0), silhouette.distance(&none, &full));
    // One token < gram tokens: no shingle, empty silhouette, maximally far.
    try t.expectEqual(@as(u16, 0), tiny.len);
}

test "silhouette: slots are sorted ascending and within k" {
    const s = try silhouette.build(gpa, base ++ reshaped ++ renamed);
    try t.expect(s.len <= silhouette.k);
    for (1..s.len) |i| try t.expect(s.h[i - 1] < s.h[i]);
}
