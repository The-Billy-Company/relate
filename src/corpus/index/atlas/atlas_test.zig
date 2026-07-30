//! atlas — the persisted kinship index's correctness suite.
//!
//! Three properties carry the warm tier: (1) a save/parse round-trip is
//! lossless (paths, sketches, anchor), (2) a torn or tampered blob NEVER
//! parses — the loader fails closed and the verbs fall back live, and
//! (3) the freshness fold over a REAL directory tree re-derives exactly what
//! a live rebuild would see for changed/new/emptied files, so an atlas
//! answer can differ from a live answer only by a deletion — which the
//! emit-time `onDisk` gate closes. Expected values derive from the on-disk
//! fixture and independent `sketch.build` runs over the same bytes, never
//! from re-running the code under test on itself.

const std = @import("std");
const atlas = @import("atlas.zig");
const sketch = @import("../../../kernel/kinship/metric/sketch.zig");
const silhouette_mod = @import("../../../kernel/kinship/metric/silhouette.zig");
const corpus_mod = @import("irregex").corpus;
const fault = @import("irregex").fault;
const portal = @import("irregex").portal;
const Dir = std.Io.Dir;

/// A throwaway on-disk tree (absolute root — no cwd dependence).
const Tree = struct {
    root: []const u8,
    io: std.Io,
    a: std.mem.Allocator,

    fn init(a: std.mem.Allocator, io: std.Io, tag: []const u8) !Tree {
        // One tree per test tag, process-unique so concurrent `zig build test`
        // runs (CI + the ~10 coworker agents) never share this mutable fixture
        // dir; init clears any stale run's leftovers.
        const root = try std.fmt.allocPrint(a, "/tmp/relate_atlas_{s}_{d}", .{ tag, portal.processId() });
        fault.spare("clear leftover fixture", Dir.cwd().deleteTree(io, root));
        try Dir.cwd().createDirPath(io, root);
        return .{ .root = root, .io = io, .a = a };
    }

    fn deinit(self: *Tree) void {
        fault.spare("remove fixture", Dir.cwd().deleteTree(self.io, self.root));
    }

    fn write(self: *Tree, rel: []const u8, data: []const u8) !void {
        const p = try std.fmt.allocPrint(self.a, "{s}/{s}", .{ self.root, rel });
        if (std.fs.path.dirnamePosix(p)) |dir| try Dir.cwd().createDirPath(self.io, dir);
        try Dir.cwd().writeFile(self.io, .{ .sub_path = p, .data = data });
    }
};

/// Coarse filesystem clocks can collapse a write onto the anchor tick; the
/// same 60ms idiom the resident freshness tests use.
fn advanceClock(io: std.Io) !void {
    try io.sleep(.fromNanoseconds(60 * std.time.ns_per_ms), .real);
}

fn expectSketchEq(t: anytype, want: *const sketch.Sketch, got: *const sketch.Sketch) !void {
    try t.expectEqualSlices(u64, want.slots(), got.slots());
}

fn expectSilhouetteEq(t: anytype, want: *const silhouette_mod.Silhouette, got: *const silhouette_mod.Silhouette) !void {
    try t.expectEqualSlices(u64, want.slots(), got.slots());
}

/// Independent per-body silhouettes for a fixture list (same discipline as
/// the sketch fixtures: expected values from separate builds over the bytes).
fn buildSilhouettes(gpa: std.mem.Allocator, bodies: []const []const u8, out: []silhouette_mod.Silhouette) !void {
    for (bodies, out) |body, *s| s.* = try silhouette_mod.build(gpa, body);
}

// Distinct bodies long enough to shed several LZ78 phrases each.
const body_a = "const std = @import(\"std\");\npub fn alpha() u32 { return 1; }\n" ** 4;
const body_b = "def beta():\n    return sum(x * x for x in range(64))\n" ** 4;
const body_c = "SELECT id, name FROM users WHERE tenant_id = $1 ORDER BY name;\n" ** 4;

test "atlas: save → parse round-trip is lossless" {
    const t = std.testing;
    const gpa = t.allocator;

    const paths = [_][]const u8{ "a/alpha.zig", "b/beta.py", "c/gamma.sql" };
    var sketches: [3]sketch.Sketch = undefined;
    for ([_][]const u8{ body_a, body_b, body_c }, &sketches) |body, *s| s.* = try sketch.build(gpa, body);
    var silhouettes: [3]silhouette_mod.Silhouette = undefined;
    try buildSilhouettes(gpa, &.{ body_a, body_b, body_c }, &silhouettes);

    const roots = [_][]const u8{ "a", "b" };
    const blob = try atlas.save(gpa, &paths, &sketches, &silhouettes, 12345, &roots);
    defer gpa.free(blob);
    var parsed = try atlas.parse(gpa, blob);
    defer parsed.deinit(gpa);

    try t.expectEqual(@as(i64, 12345), parsed.built_ns);
    try t.expectEqual(paths.len, parsed.paths.len);
    for (paths, parsed.paths) |want, got| try t.expectEqualStrings(want, got);
    try t.expectEqual(roots.len, parsed.roots.len);
    for (roots, parsed.roots) |want, got| try t.expectEqualStrings(want, got);
    for (&sketches, parsed.sketches) |*want, *got| try expectSketchEq(t, want, got);
    for (&silhouettes, parsed.silhouettes) |*want, *got| try expectSilhouetteEq(t, want, got);
}

test "atlas: a torn, tampered, or alien blob never parses" {
    const t = std.testing;
    const gpa = t.allocator;

    const paths = [_][]const u8{"solo.txt"};
    var sketches = [_]sketch.Sketch{try sketch.build(gpa, body_a)};
    var silhouettes = [_]silhouette_mod.Silhouette{try silhouette_mod.build(gpa, body_a)};
    const blob = try atlas.save(gpa, &paths, &sketches, &silhouettes, 99, &.{"."});
    defer gpa.free(blob);

    // Truncations at every framing seam (header, paths, rows, checksum).
    for ([_]usize{ 0, 3, 4, 11, 20, blob.len / 2, blob.len - 9, blob.len - 1 }) |cut| {
        try t.expectError(error.Corrupt, atlas.parse(gpa, blob[0..cut]));
    }
    // A single flipped byte anywhere trips the checksum (or a bounds check —
    // either way the parse must refuse; sample positions across the blob).
    var pos: usize = 0;
    while (pos < blob.len) : (pos += 7) {
        const mutated = try gpa.dupe(u8, blob);
        defer gpa.free(mutated);
        mutated[pos] ^= 0x5a;
        try t.expectError(error.Corrupt, atlas.parse(gpa, mutated));
    }
}

test "atlas: fold re-derives changed, new, and emptied files exactly" {
    const t = std.testing;
    const gpa = t.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();
    const fa = fixture.allocator();

    var tree = try Tree.init(fa, io, "fold");
    defer tree.deinit();
    try tree.write("keep.zig", body_a);
    try tree.write("mutate.py", body_b);
    try tree.write("empty_me.sql", body_c);

    // Build the atlas the way `relate index` does: anchor BEFORE the read.
    const built_ns: i64 = @intCast(std.Io.Clock.now(.real, io).nanoseconds);
    const roots = [_][]const u8{tree.root};
    var corpus = try corpus_mod.load(gpa, io, &roots, .contiguous);
    defer corpus.deinit();
    try t.expectEqual(@as(usize, 3), corpus.docs.len);
    const built = try gpa.alloc(sketch.Sketch, corpus.docs.len);
    defer gpa.free(built);
    for (corpus.docs, built) |d, *s| s.* = try sketch.build(gpa, d);
    const built_sil = try gpa.alloc(silhouette_mod.Silhouette, corpus.docs.len);
    defer gpa.free(built_sil);
    try buildSilhouettes(gpa, corpus.docs, built_sil);
    const blob = try atlas.save(gpa, corpus.paths, built, built_sil, built_ns, &roots);
    defer gpa.free(blob);
    var atl = try atlas.parse(gpa, blob);
    defer atl.deinit(gpa);

    // Quiescent fold: nothing changed ⇒ the view IS the atlas.
    {
        var folded = try atlas.fold(gpa, io, &atl, &roots);
        defer folded.deinit();
        if (folded.paths.items.len != atl.paths.len) {
            std.debug.print("quiescent fold drifted (refreshed={d}):\n", .{folded.refreshed});
            for (folded.paths.items) |p| std.debug.print("  - {s}\n", .{p});
        }
        try t.expectEqual(@as(usize, 0), folded.refreshed);
        try t.expectEqual(atl.paths.len, folded.paths.items.len);
    }

    // Mutate one file, add one, empty one — then fold.
    try advanceClock(io);
    const body_b2 = "def beta_v2(n):\n    return [beta() for _ in range(n)]\n" ** 5;
    try tree.write("mutate.py", body_b2);
    try tree.write("born.ts", "export const born = () => 'fresh file';\n" ** 4);
    try tree.write("empty_me.sql", "");

    var folded = try atlas.fold(gpa, io, &atl, &roots);
    defer folded.deinit();

    // emptied file dropped, new file added: 3 − 1 + 1 = 3 entries
    if (folded.paths.items.len != 3) {
        std.debug.print("post-change fold drifted (refreshed={d}):\n", .{folded.refreshed});
        for (folded.paths.items) |p| std.debug.print("  - {s}\n", .{p});
    }
    try t.expectEqual(@as(usize, 3), folded.paths.items.len);
    try t.expectEqual(@as(usize, 2), folded.refreshed); // mutate.py + born.ts

    try t.expectEqual(folded.paths.items.len, folded.silhouettes.items.len); // channels stay doc-parallel
    var want_mutated = try sketch.build(gpa, body_b2);
    var want_mutated_sil = try silhouette_mod.build(gpa, body_b2);
    var saw = [_]bool{ false, false, false };
    for (folded.paths.items, folded.sketches.items, folded.silhouettes.items) |p, *s, *sil| {
        if (std.mem.endsWith(u8, p, "mutate.py")) {
            saw[0] = true;
            try expectSketchEq(t, &want_mutated, s); // folded ≡ live rebuild
            try expectSilhouetteEq(t, &want_mutated_sil, sil); // both channels refresh together
        } else if (std.mem.endsWith(u8, p, "born.ts")) {
            saw[1] = true;
        } else if (std.mem.endsWith(u8, p, "keep.zig")) {
            saw[2] = true;
            const ci = blk: {
                for (corpus.paths, 0..) |cp, i| {
                    if (std.mem.endsWith(u8, cp, "keep.zig")) break :blk i;
                }
                unreachable;
            };
            try expectSketchEq(t, &built[ci], s); // untouched file keeps its persisted rows verbatim
            try expectSilhouetteEq(t, &built_sil[ci], sil);
        } else if (std.mem.endsWith(u8, p, "empty_me.sql")) {
            return error.TestEmptiedFileSurvivedFold;
        }
    }
    for (saw) |ok| try t.expect(ok);
}

test "atlas: onDisk gates a deleted path" {
    const t = std.testing;
    const gpa = t.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();

    var tree = try Tree.init(fixture.allocator(), io, "gate");
    defer tree.deinit();
    try tree.write("here.txt", body_a);
    const here = try std.fmt.allocPrint(fixture.allocator(), "{s}/here.txt", .{tree.root});
    const gone = try std.fmt.allocPrint(fixture.allocator(), "{s}/gone.txt", .{tree.root});

    try t.expect(atlas.onDisk(io, here));
    try t.expect(!atlas.onDisk(io, gone));
    try t.expect(!atlas.onDisk(io, tree.root)); // a directory is not a corpus member
}
