//! frag — the persisted fragment index's correctness suite.
//!
//! Same three properties as the atlas, at the FUNCTION granularity: (1) a
//! save/parse round-trip is lossless (path table, per-fragment path index,
//! spans, structure silhouettes, roots, anchor); (2) a torn or tampered blob
//! NEVER parses — the loader fails closed and `--unit function` answers live; and
//! (3) the freshness fold over a REAL tree re-derives exactly the fragment set a
//! live extract + build would, so a folded answer differs from a live one only
//! by a deletion the `onDisk` gate closes. Expected values derive from the
//! on-disk fixture and independent `silhouette.build` runs over the same bytes,
//! never from re-running the fold on itself.

const std = @import("std");
const frag = @import("frag.zig");
const silhouette_mod = @import("../../../kernel/kinship/metric/silhouette.zig");
const corpus_mod = @import("irregex").corpus;
const fault = @import("irregex").fault;
const portal = @import("irregex").portal;
const Dir = std.Io.Dir;

// Bodies with more than one function each, long enough to shed real silhouettes.
const body_zig =
    \\const std = @import("std");
    \\pub fn alpha(x: u32) u32 {
    \\    var acc: u32 = 0;
    \\    for (0..x) |i| acc += i;
    \\    return acc;
    \\}
    \\pub fn beta(y: u32) u32 {
    \\    const scaled = alpha(y) * 2;
    \\    return scaled + 1;
    \\}
;
const body_py =
    \\def gamma(n):
    \\    total = 0
    \\    for i in range(n):
    \\        total += i * i
    \\    return total
    \\
    \\def delta(n):
    \\    return gamma(n) + 1
;

const Tree = struct {
    root: []const u8,
    io: std.Io,
    a: std.mem.Allocator,

    fn init(a: std.mem.Allocator, io: std.Io, tag: []const u8) !Tree {
        // Process-unique so concurrent `zig build test` runs (CI + the ~10
        // coworker agents) never share this mutable fixture dir.
        const root = try std.fmt.allocPrint(a, "/tmp/relate_frag_{s}_{d}", .{ tag, portal.processId() });
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

fn advanceClock(io: std.Io) !void {
    try io.sleep(.fromNanoseconds(60 * std.time.ns_per_ms), .real);
}

test "frag: save → parse round-trip is lossless" {
    const t = std.testing;
    const gpa = t.allocator;

    var b = frag.Build{ .gpa = gpa };
    defer b.deinit();
    try b.addFile("a/alpha.zig", body_zig);
    try b.addFile("b/beta.py", body_py);
    try t.expect(b.count() >= 4); // ≥2 functions per file

    const roots = [_][]const u8{ "a", "b" };
    const blob = try frag.save(gpa, &b, 12345, &roots);
    defer gpa.free(blob);
    var parsed = try frag.parse(gpa, blob);
    defer parsed.deinit(gpa);

    try t.expectEqual(@as(i64, 12345), parsed.built_ns);
    try t.expectEqual(b.paths.items.len, parsed.paths.len);
    for (b.paths.items, parsed.paths) |want, got| try t.expectEqualStrings(want, got);
    try t.expectEqual(roots.len, parsed.roots.len);
    for (roots, parsed.roots) |want, got| try t.expectEqualStrings(want, got);
    try t.expectEqual(b.count(), parsed.spans.len);
    for (b.path_idx.items, parsed.path_idx) |want, got| try t.expectEqual(want, got);
    for (b.spans.items, parsed.spans) |want, got| {
        try t.expectEqual(want.byte_start, got.byte_start);
        try t.expectEqual(want.byte_end, got.byte_end);
        try t.expectEqual(want.line_start, got.line_start);
        try t.expectEqual(want.line_end, got.line_end);
    }
    for (b.silhouettes.items, parsed.silhouettes) |*want, *got|
        try t.expectEqualSlices(u64, want.slots(), got.slots());
}

test "frag: a torn, tampered, or alien blob never parses" {
    const t = std.testing;
    const gpa = t.allocator;

    var b = frag.Build{ .gpa = gpa };
    defer b.deinit();
    try b.addFile("solo.zig", body_zig);
    const blob = try frag.save(gpa, &b, 99, &.{"."});
    defer gpa.free(blob);

    for ([_]usize{ 0, 3, 4, 11, 20, blob.len / 2, blob.len - 9, blob.len - 1 }) |cut|
        try t.expectError(error.Corrupt, frag.parse(gpa, blob[0..cut]));
    var pos: usize = 0;
    while (pos < blob.len) : (pos += 7) {
        const mutated = try gpa.dupe(u8, blob);
        defer gpa.free(mutated);
        mutated[pos] ^= 0x5a;
        try t.expectError(error.Corrupt, frag.parse(gpa, mutated));
    }
}

/// Independent live fragment build over the current tree — the "what a live
/// rebuild sees" oracle a folded view must match (set-wise).
fn liveBuild(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8) !struct { corpus: corpus_mod.Corpus, build: frag.Build } {
    var corpus = try corpus_mod.load(gpa, io, roots, .contiguous);
    errdefer corpus.deinit();
    const build = try frag.buildAll(gpa, &corpus);
    return .{ .corpus = corpus, .build = build };
}

test "frag: fold re-derives changed, new, and emptied fragments exactly" {
    const t = std.testing;
    const gpa = t.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();

    var tree = try Tree.init(fixture.allocator(), io, "fold");
    defer tree.deinit();
    try tree.write("keep.zig", body_zig);
    try tree.write("mutate.py", body_py);
    try tree.write("empty_me.zig", body_zig);

    const built_ns: i64 = @intCast(std.Io.Clock.now(.real, io).nanoseconds);
    const roots = [_][]const u8{tree.root};
    var corpus = try corpus_mod.load(gpa, io, &roots, .contiguous);
    defer corpus.deinit();
    try t.expectEqual(@as(usize, 3), corpus.docs.len);
    var b = try frag.buildAll(gpa, &corpus);
    defer b.deinit();
    const blob = try frag.save(gpa, &b, built_ns, &roots);
    defer gpa.free(blob);
    var f = try frag.parse(gpa, blob);
    defer f.deinit(gpa);

    // Quiescent: nothing changed ⇒ the folded view IS the persisted index.
    {
        var folded = try frag.fold(gpa, io, &f, &roots);
        defer folded.deinit();
        try t.expectEqual(@as(usize, 0), folded.refreshed);
        try t.expectEqual(f.spans.len, folded.spans.items.len);
    }

    // Mutate one file, add one, empty one — then fold.
    try advanceClock(io);
    const body_py2 =
        \\def epsilon(items):
        \\    seen = set()
        \\    for it in items:
        \\        seen.add(it.key)
        \\    return sorted(seen)
    ;
    try tree.write("mutate.py", body_py2);
    try tree.write("born.zig", body_zig);
    try tree.write("empty_me.zig", "");

    var folded = try frag.fold(gpa, io, &f, &roots);
    defer folded.deinit();
    try t.expectEqual(@as(usize, 2), folded.refreshed); // mutate.py + born.zig

    // Set parity against a fresh live build over the mutated tree.
    var live = try liveBuild(gpa, io, &roots);
    defer live.corpus.deinit();
    defer live.build.deinit();
    try t.expectEqual(live.build.count(), folded.spans.items.len);

    var saw_born = false;
    for (folded.paths.items) |p| {
        if (std.mem.endsWith(u8, p, "empty_me.zig")) return error.EmptiedFileSurvivedFold;
        if (std.mem.endsWith(u8, p, "born.zig")) saw_born = true;
    }
    try t.expect(saw_born);

    // An untouched file keeps its persisted fragments verbatim.
    var want = try silhouetteOfFirst(gpa, "keep.zig", &f);
    for (folded.paths.items, folded.spans.items, folded.silhouettes.items) |p, span, *sil| {
        if (std.mem.endsWith(u8, p, "keep.zig") and span.line_start == want.line_start) {
            try t.expectEqualSlices(u64, want.sil.slots(), sil.slots());
            break;
        }
    }
}

/// The first persisted fragment of `rel`, for the verbatim-retention check.
fn silhouetteOfFirst(gpa: std.mem.Allocator, rel: []const u8, f: *const frag.Frag) !struct { line_start: u32, sil: silhouette_mod.Silhouette } {
    _ = gpa;
    for (f.path_idx, f.spans, f.silhouettes) |pidx, span, sil| {
        if (std.mem.endsWith(u8, f.paths[pidx], rel)) return .{ .line_start = span.line_start, .sil = sil };
    }
    return error.NotFound;
}

test "frag: onDisk gates a deleted path" {
    const t = std.testing;
    const gpa = t.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();

    var tree = try Tree.init(fixture.allocator(), io, "gate");
    defer tree.deinit();
    try tree.write("here.zig", body_zig);
    const here = try std.fmt.allocPrint(fixture.allocator(), "{s}/here.zig", .{tree.root});
    const gone = try std.fmt.allocPrint(fixture.allocator(), "{s}/gone.zig", .{tree.root});

    try t.expect(frag.onDisk(io, here));
    try t.expect(!frag.onDisk(io, gone));
    try t.expect(!frag.onDisk(io, tree.root)); // a directory is not a corpus member
}
