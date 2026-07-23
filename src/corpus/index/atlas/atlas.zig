//! atlas — the persisted kinship index (relate's warm tier).
//!
//! The trigram index makes `gist` warm; the atlas makes `relate` warm. It
//! persists one LZJD `Sketch` (kernel/kinship/metric/sketch.zig — bottom-k of the
//! LZ78 phrase-hash dictionary, k=128, ~1 KiB) and one `Silhouette`
//! (kernel/kinship/metric/silhouette.zig — winnowed normalized-token shingles,
//! k=256, ~2 KiB — the structure channel) per corpus file, so the kinship
//! verbs (`similar` / `dups` / `clusters` / `echoes`) answer from ~3 KiB/file
//! of index instead of re-reading and re-parsing every corpus byte per
//! invocation — tens of MiB loaded in milliseconds versus ~200 MiB read +
//! parsed per query.
//!
//! Same contract as every irregex index: **an accelerator, never an
//! authority.** The atlas carries the T3 wall-clock anchor captured BEFORE
//! the build's corpus read; `fold` re-derives freshness through the same
//! conservative stat walk the trigram overlay uses (`fresh.changedSince`) and
//! re-sketches every changed/new file from live bytes, so a folded view is
//! byte-equivalent to a live rebuild for every file that still exists.
//! Deletions cannot be observed by a changed-walk (the walk only visits live
//! files), so consumers gate *emitted* rows through `onDisk` — O(results)
//! stats, never O(corpus). `--no-index` (or a missing/corrupt atlas) falls
//! back to the full live build with identical answers.
//!
//! Deliberately NOT duplicated here: a private `relate search` fingerprint
//! lexicon. Search/pack reuse Gist's compact mmap-backed trigram codebook for
//! nomination, then apply their own information-pricing and exact/coverage
//! decisions. The atlas remains the economic persisted shape for broad
//! kinship queries; narrow explicit scopes sketch live when that costs less
//! than loading this whole artifact.
//!
//! Format (`kinship.atlas`, little-endian):
//!   "ATLS" · u32 version · i64 built_ns · u32 ndocs
//!   u64 path_blob_len · path blob (NUL-terminated, doc order)
//!   u64 roots_blob_len · roots blob (NUL-terminated build roots — v2+; a v1
//!     atlas predates roots persistence and reads back as the monorepo defaults)
//!   ndocs × (u16 sketch_len · sketch.k×u64 slots, zero-padded past len)
//!   ndocs × (u16 silhouette_len · silhouette.k×u64 slots, zero-padded — v3+;
//!     the structure channel, same doc order)
//!   u64 FNV-1a checksum of every preceding byte
//! Loads fail closed on any framing, bounds, or checksum violation.

const std = @import("std");
const sketch = @import("../../../kernel/kinship/metric/sketch.zig");
const silhouette_mod = @import("../../../kernel/kinship/metric/silhouette.zig");
const corpus_mod = @import("../../tree/corpus.zig");
const fresh = @import("../trigrams/fresh.zig");

const Sketch = sketch.Sketch;
const Silhouette = silhouette_mod.Silhouette;
const Dir = std.Io.Dir;

const atlas_path = corpus_mod.ArtifactPath("kinship.atlas");
pub fn atlasFile() []const u8 {
    return atlas_path.get();
}

const MAGIC = "ATLS";
// v2 added the build-roots blob; v3 added the silhouette (structure-channel)
// rows. An older atlas is treated as corrupt — every verb degrades to a live
// build and suggests `relate index`; guessing sections an old blob never
// recorded could unsoundly answer a query warm.
const VERSION: u32 = 3;

// Little-endian serializer + fail-closed cursor + NUL catalog codec shared by
// every persisted irregex artifact.
const frame = @import("../frame/frame.zig");
const putInt = frame.putInt;
const fnv64 = frame.fnv64;
const Cursor = frame.Cursor;

/// Serialize `paths` + their `sketches` and `silhouettes` (same order) under
/// the `built_ns` anchor, plus the `roots` the corpus was built over (so a
/// later fold walks exactly that corpus). Caller frees the blob and persists
/// it (persist.writeAtomic).
pub fn save(gpa: std.mem.Allocator, paths: []const []const u8, sketches: []const Sketch, silhouettes: []const Silhouette, built_ns: i64, roots: []const []const u8) ![]u8 {
    std.debug.assert(paths.len == sketches.len and paths.len == silhouettes.len);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try out.appendSlice(gpa, MAGIC);
    try putInt(gpa, &out, u32, VERSION);
    try putInt(gpa, &out, i64, built_ns);
    try putInt(gpa, &out, u32, @intCast(paths.len));

    const blob_len = frame.nulLen(paths);
    const roots_len = frame.nulLen(roots);
    try putInt(gpa, &out, u64, blob_len);
    // Header already written; reserve path + roots blobs, fixed-width sketch
    // + silhouette rows, and the trailer hash. Each row is u16 len + k×u64
    // slots (zero-padded past len) — see format header.
    const row_bytes: usize = 2 * @sizeOf(u16) + (sketch.k + silhouette_mod.k) * @sizeOf(u64);
    try out.ensureTotalCapacityPrecise(gpa, out.items.len + blob_len + 8 + roots_len + paths.len * row_bytes + 8);
    try frame.joinNul(gpa, &out, paths);

    try putInt(gpa, &out, u64, roots_len);
    try frame.joinNul(gpa, &out, roots);

    for (sketches) |*s| {
        try putInt(gpa, &out, u16, s.len);
        for (s.h) |v| try putInt(gpa, &out, u64, v);
    }
    for (silhouettes) |*s| {
        try putInt(gpa, &out, u16, s.len);
        for (s.h) |v| try putInt(gpa, &out, u64, v);
    }

    try putInt(gpa, &out, u64, fnv64(out.items));
    return out.toOwnedSlice(gpa);
}

/// The loaded kinship index: one sketch + one silhouette per corpus file as
/// of `built_ns`, plus the roots the corpus was built over (what a fold walks).
pub const Atlas = struct {
    built_ns: i64,
    path_blob: []const u8,
    paths: []const []const u8, // borrow path_blob, doc order
    roots_blob: []const u8,
    roots: []const []const u8, // borrow roots_blob — the build roots
    sketches: []Sketch,
    silhouettes: []Silhouette, // the structure channel, same doc order

    pub fn deinit(self: *Atlas, gpa: std.mem.Allocator) void {
        gpa.free(self.silhouettes);
        gpa.free(self.sketches);
        gpa.free(self.roots);
        gpa.free(self.roots_blob);
        gpa.free(self.paths);
        gpa.free(self.path_blob);
    }
};

/// Parse a `save` blob; fails closed on any framing/bounds/checksum violation.
pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) !Atlas {
    if (bytes.len < MAGIC.len + 8 or !std.mem.eql(u8, bytes[0..MAGIC.len], MAGIC)) return error.Corrupt;
    const body = bytes[0 .. bytes.len - 8];
    const declared = std.mem.readInt(u64, bytes[bytes.len - 8 ..][0..8], .little);
    if (fnv64(body) != declared) return error.Corrupt;

    var c = Cursor{ .buf = body, .pos = MAGIC.len };
    const version = try c.int(u32);
    if (version != VERSION) return error.Corrupt;
    const built_ns = try c.int(i64);
    const ndocs = try c.int(u32);

    const blob_len = try c.int(u64);
    const path_blob = try gpa.dupe(u8, try c.bytes(@intCast(blob_len)));
    errdefer gpa.free(path_blob);
    const paths = try frame.splitNulExact(gpa, path_blob, ndocs, true);
    errdefer gpa.free(paths);

    // The build roots the fold walks — always present in the one live format.
    const roots = blk: {
        const roots_len = try c.int(u64);
        var list = try frame.parsePathTable(gpa, try c.bytes(@intCast(roots_len)));
        defer list.deinit(gpa);
        if (list.items.len == 0) return error.Corrupt;
        break :blk try frame.ownedNulTable(gpa, list.items);
    };
    errdefer {
        gpa.free(roots.slices);
        gpa.free(roots.blob);
    }

    const sketches = try gpa.alloc(Sketch, ndocs);
    errdefer gpa.free(sketches);
    for (sketches) |*s| try readRow(Sketch, sketch.k, &c, s);
    const silhouettes = try gpa.alloc(Silhouette, ndocs);
    errdefer gpa.free(silhouettes);
    for (silhouettes) |*s| try readRow(Silhouette, silhouette_mod.k, &c, s);
    if (c.pos != body.len) return error.Corrupt;
    return .{ .built_ns = built_ns, .path_blob = path_blob, .paths = paths, .roots_blob = roots.blob, .roots = roots.slices, .sketches = sketches, .silhouettes = silhouettes };
}

/// One fixed-width bottom-k row (u16 len + k×u64 slots): shared by the sketch
/// and silhouette sections, which differ only in `k`.
fn readRow(comptime T: type, comptime k: u16, c: *Cursor, s: *T) !void {
    const len = try c.int(u16);
    if (len > k) return error.Corrupt;
    s.len = len;
    for (&s.h) |*v| v.* = try c.int(u64);
    // slots are sorted ascending within len (an empty row — a file too short
    // to shed one phrase/shingle — has no order to check, and 1..0 is an
    // invalid range); disorder means torn bytes
    if (len != 0) for (1..len) |i| if (s.h[i - 1] > s.h[i]) return error.Corrupt;
}

/// Load the persisted atlas, silent on a miss (the verbs fall back to the live
/// build the same way `gist` live-walks without a trigram index); corruption
/// also returns null. The shared fail-open loader, bound to this artifact.
pub fn loadQuiet(gpa: std.mem.Allocator, io: std.Io) ?Atlas {
    return frame.loadQuiet(Atlas, gpa, io, atlas_path.get(), "atlas", parse);
}

/// The effective kinship view after folding live changes over a persisted
/// atlas: paths + sketches for every corpus doc as of NOW (modulo deletions,
/// which the consumer gates at emit — see the module header).
pub const Folded = struct {
    arena: std.heap.ArenaAllocator, // owns refreshed path strings
    paths: std.ArrayList([]const u8), // borrow atlas or arena
    sketches: std.ArrayList(Sketch),
    silhouettes: std.ArrayList(Silhouette), // same doc order as sketches
    refreshed: usize, // changed/new files re-sketched from live bytes
    gpa: std.mem.Allocator,

    pub fn deinit(self: *Folded) void {
        self.paths.deinit(self.gpa);
        self.sketches.deinit(self.gpa);
        self.silhouettes.deinit(self.gpa);
        self.arena.deinit();
    }
};

/// Fold everything changed since the atlas anchor back in: re-read + re-sketch
/// changed files, append new ones, tombstone files that no longer read as
/// corpus members (unreadable, now-binary, now-empty). O(changed), never
/// O(corpus). `roots` is the corpus the atlas was built over (production:
/// the atlas's own persisted `roots`); callers scope the returned view
/// themselves.
pub fn fold(gpa: std.mem.Allocator, io: std.Io, atl: *const Atlas, roots: []const []const u8) !Folded {
    var out = Folded{
        .arena = std.heap.ArenaAllocator.init(gpa),
        .paths = .empty,
        .sketches = .empty,
        .silhouettes = .empty,
        .refreshed = 0,
        .gpa = gpa,
    };
    errdefer out.deinit();
    const a = out.arena.allocator();

    try out.paths.appendSlice(gpa, atl.paths);
    try out.sketches.appendSlice(gpa, atl.sketches);
    try out.silhouettes.appendSlice(gpa, atl.silhouettes);

    var changed: std.ArrayList([]const u8) = .empty;
    try fresh.changedSince(gpa, io, roots, atl.built_ns, a, &changed);
    if (changed.items.len == 0) return out;

    var by_path: std.StringHashMapUnmanaged(u32) = .empty;
    defer by_path.deinit(gpa);
    try by_path.ensureTotalCapacity(gpa, @intCast(atl.paths.len));
    for (atl.paths, 0..) |p, i| by_path.putAssumeCapacity(p, @intCast(i));

    var dead: std.ArrayList(u32) = .empty; // tombstoned indices, compacted below
    defer dead.deinit(gpa);
    // The changed walk promises no duplicates on its happy path, but its
    // degraded (partial-expand) path may repeat one — folding a path twice
    // would double-append a new file, so guard exactly.
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(gpa);

    for (changed.items) |path| {
        if ((try seen.getOrPut(gpa, path)).found_existing) continue;
        const existing = by_path.get(path);
        // corpus.load skips non-members, so parity means dropping the entry.
        const body = corpus_mod.readMember(io, Dir.cwd(), path, a) orelse {
            if (existing) |id| try dead.append(gpa, id);
            continue;
        };
        // Both channels refresh together. A failure invalidates the warm view
        // so the caller can rebuild live; retaining stale bytes would violate
        // indexed/live identity, while refreshing one channel would corrupt
        // the echo signal.
        const s = try sketch.build(gpa, body);
        const sil = try silhouette_mod.build(gpa, body);
        out.refreshed += 1;
        if (existing) |id| {
            out.sketches.items[id] = s;
            out.silhouettes.items[id] = sil;
        } else {
            try out.paths.append(gpa, path); // arena-owned
            try out.sketches.append(gpa, s);
            try out.silhouettes.append(gpa, sil);
        }
    }

    if (dead.items.len > 0) {
        std.mem.sort(u32, dead.items, {}, comptime std.sort.desc(u32));
        var prev: ?u32 = null;
        for (dead.items) |id| {
            if (prev == id) continue; // changed-list dupes tombstone once
            prev = id;
            _ = out.paths.orderedRemove(id);
            _ = out.sketches.orderedRemove(id);
            _ = out.silhouettes.orderedRemove(id);
        }
    }
    return out;
}

/// Does `path` still exist as a file? The emit-time deletion gate for
/// answers served from atlas sketches (O(results), not O(corpus)) — the shared frame gate.
pub const onDisk = frame.onDisk;
