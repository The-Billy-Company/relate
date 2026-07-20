//! relate — the near-duplicate pair machinery `dups`, `clusters`, and `echoes`
//! share: bottom-16 seed-hash candidate buckets nominate, exact pairwise
//! verification decides, and the total (distance, path, path) order sorts.
//!
//! Pure kernel: given records that expose `slots()`/`len` (a `Sketch` or a
//! `Silhouette`), it enumerates every unique candidate pair and — for the LZJD
//! byte channel — the verified near-duplicate list. No corpus, argv, or stdout
//! knowledge; the relate verb drivers resolve the view and render the rows.

const std = @import("std");
const sketch = @import("../metric/sketch.zig");

pub const Sketch = sketch.Sketch;

/// A verified near-duplicate pair (i < j), in the total (distance, path,
/// path) order.
pub const Pair = struct {
    dist: f64,
    i: u32,
    j: u32,

    pub fn less(paths: []const []const u8, x: Pair, y: Pair) bool {
        if (x.dist != y.dist) return x.dist < y.dist;
        const c = std.mem.order(u8, paths[x.i], paths[y.i]);
        if (c != .eq) return c == .lt;
        return std.mem.order(u8, paths[x.j], paths[y.j]) == .lt;
    }
};

/// How many of each sketch's smallest hashes seed the candidate index. Two
/// files at Jaccard ≥ 0.75 share ≥1 of their bottom-16 with probability
/// ~1−0.25¹⁶ ≈ 1; the pairwise verify then rejects false candidates exactly.
pub const seed_hashes = 16;
/// A hash bucket bigger than this is a degenerate attractor (e.g. thousands
/// of same-boilerplate files); pairing inside it would go quadratic. Its
/// members almost surely share OTHER seed hashes pairwise, so capping costs
/// recall only in adversarial corpora — and never precision.
pub const bucket_cap = 64;

/// Enumerate every unique candidate pair (two records sharing a bottom-16
/// seed hash) over ANY bottom-k record type (`Sketch` or `Silhouette` — both
/// expose `slots()`/`len`), invoking `visit(ctx, i, j)` exactly once per pair
/// with i < j. The caller verifies each candidate exactly — this stage may
/// only nominate, never decide.
pub fn forEachCandidatePair(
    comptime T: type,
    gpa: std.mem.Allocator,
    records: []const T,
    ctx: anytype,
    comptime visit: fn (@TypeOf(ctx), u32, u32) error{OutOfMemory}!void,
) !void {
    // Candidate generation: (seed hash, doc) tuples, sorted; docs sharing a
    // seed hash form a bucket; every in-bucket pair gets visited.
    const Tuple = struct {
        h: u64,
        doc: u32,
        fn less(_: void, x: @This(), y: @This()) bool {
            if (x.h != y.h) return x.h < y.h;
            return x.doc < y.doc;
        }
    };
    var tuples: std.ArrayList(Tuple) = .empty;
    defer tuples.deinit(gpa);
    for (records, 0..) |*s, d| {
        const seeds = s.slots()[0..@min(seed_hashes, s.len)];
        for (seeds) |h| try tuples.append(gpa, .{ .h = h, .doc = @intCast(d) });
    }
    std.mem.sort(Tuple, tuples.items, {}, Tuple.less);

    // Dedupe via a seen-set keyed on (i,j).
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer seen.deinit(gpa);

    var lo: usize = 0;
    while (lo < tuples.items.len) {
        var hi = lo + 1;
        while (hi < tuples.items.len and tuples.items[hi].h == tuples.items[lo].h) hi += 1;
        const bucket = tuples.items[lo..hi];
        const limit = @min(bucket.len, bucket_cap);
        for (bucket[0..limit], 0..) |x, bi| {
            for (bucket[bi + 1 .. limit]) |y| {
                const a = @min(x.doc, y.doc);
                const z = @max(x.doc, y.doc);
                const key = (@as(u64, a) << 32) | z;
                const entry = try seen.getOrPut(gpa, key);
                if (entry.found_existing) continue;
                try visit(ctx, a, z);
            }
        }
        lo = hi;
    }
}

/// All verified pairs at distance ≤ `max_dist`, sorted by the total order.
/// Candidates come from shared bottom-16 seed hashes; every emitted pair is
/// exactly verified against both full sketches. Caller frees.
pub fn verifiedPairs(
    gpa: std.mem.Allocator,
    paths: []const []const u8,
    sketches: []const Sketch,
    max_dist: f64,
) ![]Pair {
    const Ctx = struct {
        gpa: std.mem.Allocator,
        sketches: []const Sketch,
        max_dist: f64,
        pairs: std.ArrayList(Pair) = .empty,

        fn visit(self: *@This(), a: u32, z: u32) error{OutOfMemory}!void {
            const d = sketch.distance(&self.sketches[a], &self.sketches[z]);
            if (d <= self.max_dist) try self.pairs.append(self.gpa, .{ .dist = d, .i = a, .j = z });
        }
    };
    var ctx = Ctx{ .gpa = gpa, .sketches = sketches, .max_dist = max_dist };
    errdefer ctx.pairs.deinit(gpa);
    try forEachCandidatePair(Sketch, gpa, sketches, &ctx, Ctx.visit);
    std.mem.sort(Pair, ctx.pairs.items, paths, Pair.less);
    return ctx.pairs.toOwnedSlice(gpa);
}
