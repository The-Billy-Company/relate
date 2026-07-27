//! kinship — the parallel pass that turns bytes into records.
//!
//! Every rung that produces fingerprints does the same thing: take N documents,
//! build one record per document, and degrade a failure to the maximally-far
//! `empty` value rather than losing the row. It is embarrassingly parallel and
//! byte-imbalanced (one 2 MiB generated file beside a thousand 200-byte
//! modules), so it shards on BYTES through the shared floor rather than on
//! document count.
//!
//! It lives here, beside the records it builds, because two rungs need it and
//! they sit on opposite sides of the tree: the LIVE rung
//! (`surface/face/relate/kinship.zig`) fingerprints a whole scoped corpus, and
//! the atlas FRESHNESS FOLD (`corpus/index/atlas/atlas.zig`) re-fingerprints
//! whatever changed since the anchor. The fold used to do it one file at a time
//! in a serial loop — on a tree ~10 coworker agents are editing, that is
//! thousands of files re-sketched serially on *every* kinship query, and it
//! dominated the cost of every `relate` verb.

const std = @import("std");
const parallel = @import("../../primitives/parallel.zig");

/// Fingerprint every doc in `docs` into the doc-parallel `out`, returning how
/// many degraded to `empty`. `T` needs an `empty` decl (the maximally-far
/// degrade value — it can hide a result, never invent one) and a
/// `buildFn(gpa, bytes) !T`.
///
/// `out.len` must equal `docs.len`. Workers allocate their own scratch from the
/// page allocator, so `gpa` is touched only for the shard bookkeeping and no
/// two threads contend on the caller's allocator.
pub fn fill(
    comptime T: type,
    comptime buildFn: anytype,
    gpa: std.mem.Allocator,
    docs: []const []const u8,
    out: []T,
) error{OutOfMemory}!usize {
    std.debug.assert(out.len == docs.len);
    if (docs.len == 0) return 0;

    var total: usize = 0;
    for (docs) |d| total += d.len;

    // One thread per ~4 MiB of corpus, capped at the core count: thread spawn
    // only amortizes once the fingerprinting dominates.
    const ncpu = std.Thread.getCpuCount() catch 1;
    const nthr = @min(@max(@as(usize, 1), total / (4 << 20)), ncpu);

    const Shard = struct {
        docs: []const []const u8,
        out: []T,
        failed: usize = 0,

        fn run(sh: *@This()) void {
            for (sh.docs, sh.out) |d, *s| s.* = buildFn(std.heap.page_allocator, d) catch blk: {
                sh.failed += 1;
                break :blk .empty;
            };
        }
    };

    const bounds = try gpa.alloc(usize, nthr + 1);
    defer gpa.free(bounds);
    parallel.greedyBounds([]const u8, docs, {}, parallel.sliceLen, total, bounds);

    const shards = try gpa.alloc(Shard, nthr);
    defer gpa.free(shards);
    const threads = try gpa.alloc(std.Thread, nthr);
    defer gpa.free(threads);
    for (0..nthr) |s|
        shards[s] = .{ .docs = docs[bounds[s]..bounds[s + 1]], .out = out[bounds[s]..bounds[s + 1]] };
    // A shard whose thread never spawned still runs inline, so every slot fills.
    parallel.fanOut(Shard, shards, threads, Shard.run);

    var failed: usize = 0;
    for (shards) |sh| failed += sh.failed;
    return failed;
}

// ── tests ────────────────────────────────────────────────────────────────

const t = std.testing;

/// The fake builder's refusal. File-private and deliberately NOT a taxonomy
/// member (ADR-373 law 2): `fill` must propagate whatever a record builder
/// hands back and count it, so what the harness proves is that SOME error
/// degrades to `empty` and is tallied — naming a real fault here would imply
/// the fan-out cares which one, and mint a product spelling from a test.
const Refusal = error{Refused};

/// A trivial record whose value is derivable from the input, so a test can
/// prove every slot got ITS OWN doc's answer rather than merely being written.
const Count = struct {
    n: usize,

    const empty: Count = .{ .n = 0 };

    fn build(_: std.mem.Allocator, bytes: []const u8) !Count {
        return .{ .n = bytes.len };
    }

    fn refuse(_: std.mem.Allocator, bytes: []const u8) Refusal!Count {
        if (bytes.len == 3) return Refusal.Refused;
        return .{ .n = bytes.len };
    }
};

test "every slot receives its own doc's record, across shard boundaries" {
    const gpa = t.allocator;
    // Enough bytes to cross the 4 MiB-per-thread heuristic into a real
    // multi-shard fan-out, with a deliberately lopsided head so the byte-greedy
    // split puts the boundary somewhere other than the midpoint.
    const heavy = try gpa.alloc(u8, 9 << 20);
    defer gpa.free(heavy);
    @memset(heavy, 'x');

    var docs: [64][]const u8 = undefined;
    docs[0] = heavy;
    for (docs[1..], 1..) |*d, i| d.* = heavy[0..i];

    var out: [64]Count = undefined;
    const failed = try fill(Count, Count.build, gpa, &docs, &out);
    try t.expectEqual(@as(usize, 0), failed);
    // Doc-parallel: slot i holds the length of doc i, not of whatever doc its
    // thread happened to visit last.
    try t.expectEqual(heavy.len, out[0].n);
    for (out[1..], 1..) |c, i| try t.expectEqual(i, c.n);
}

test "a refused doc degrades to empty and is counted, never dropped" {
    const gpa = t.allocator;
    const docs = [_][]const u8{ "a", "bcd", "ef" };
    var out: [3]Count = undefined;
    const failed = try fill(Count, Count.refuse, gpa, &docs, &out);
    try t.expectEqual(@as(usize, 1), failed);
    try t.expectEqual(@as(usize, 1), out[0].n);
    try t.expectEqual(@as(usize, 0), out[1].n); // the refusal, degraded
    try t.expectEqual(@as(usize, 2), out[2].n); // its neighbors are unaffected
}

test "an empty corpus needs no shards" {
    var out: [0]Count = undefined;
    try t.expectEqual(@as(usize, 0), try fill(Count, Count.build, t.allocator, &.{}, &out));
}
