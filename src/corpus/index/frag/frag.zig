//! frag — the persisted FUNCTION-fragment index (the concept tier's warm state).
//!
//! The atlas makes whole-FILE kinship warm; frag makes function-level CONCEPT
//! discovery warm. It persists one structure `Silhouette`
//! (search/similarity/silhouette.zig — winnowed normalized-token shingles) per
//! extracted function fragment, plus each fragment's file + byte/line span, so
//! `relate concepts` can group theoretically-similar functions across the whole
//! corpus from a few hundred KiB of index instead of re-reading and
//! re-extracting every source byte per query.
//!
//! ONE channel on disk, by design: the byte (LZJD) sketch is NOT persisted
//! per-fragment. Structure is what "same concept, maybe renamed" means, and it
//! is the only channel used to nominate and group; the byte channel — needed
//! only for the opt-in `--lens bytes|echo` — is re-derived on demand by slicing
//! the few nominated fragments' live bytes. That keeps the artifact lean (a
//! variable-length silhouette per fragment, not a fixed dual-channel row).
//!
//! Same contract as every irregex index: an accelerator, never an authority.
//! The T3 wall-clock anchor is captured BEFORE the build read; `fold` re-derives
//! freshness through the same `fresh.changedSince` stat walk the atlas/trigram
//! overlays use and re-extracts every changed/new file's fragments from live
//! bytes, so a folded view is byte-equivalent to a live rebuild for every file
//! that still exists. Deletions are gated at emit through `onDisk`. A
//! missing/corrupt artifact (or `--no-index`) degrades to a full live build with
//! identical answers.
//!
//! Format (`concepts.frag`, little-endian):
//!   "FRAG" · u32 version · i64 built_ns
//!   u32 npaths · u64 path_blob_len · path blob (NUL-terminated, table order)
//!   u64 roots_blob_len · roots blob (NUL-terminated build roots)
//!   u32 nfrags
//!   nfrags × (u32 path_idx · u32 byte_start · u32 byte_end · u32 line_start ·
//!            u32 line_end · u16 sil_len · sil_len×u64 silhouette slots)
//!   u64 FNV-1a checksum of every preceding byte
//! Loads fail closed on any framing, bounds, or checksum violation.

const std = @import("std");
const silhouette_mod = @import("../../../kernel/kinship/metric/silhouette.zig");
const regions = @import("../../../kernel/compose/regions.zig");
const corpus_mod = @import("../../tree/corpus.zig");
const fresh = @import("../trigrams/fresh.zig");
const frame = @import("../frame/frame.zig");

const Silhouette = silhouette_mod.Silhouette;
const Dir = std.Io.Dir;
const putInt = frame.putInt;
const Cursor = frame.Cursor;

const frag_path = corpus_mod.ArtifactPath("concepts.frag");
pub fn fragFile() []const u8 {
    return frag_path.get();
}

const MAGIC = "FRAG";
const VERSION: u32 = 1;
const fnv64 = frame.fnv64;

/// A fragment's location: byte range in its file (for on-demand byte slicing)
/// and 1-based line range (for display). Byte range fits u32 — files are capped
/// at `corpus.per_file_cap` (4 MiB).
pub const Span = struct {
    byte_start: u32,
    byte_end: u32,
    line_start: u32,
    line_end: u32,

    pub fn lines(self: Span) usize {
        return @as(usize, self.line_end - self.line_start) + 1;
    }
};

fn spanOf(r: regions.Region) Span {
    return .{
        .byte_start = @intCast(r.start),
        .byte_end = @intCast(r.end),
        .line_start = r.line_start,
        .line_end = r.line_end,
    };
}

// ── the fragment builder (shared by index build, the live rung, and the fold) ──

/// Accumulates every corpus file's function fragments: a distinct-path table,
/// a per-fragment path index into it, spans, and structure silhouettes. The one
/// place source is lifted into the concept unit, so build / live / fold cannot
/// drift on what a "fragment" is. Borrows path strings; the caller keeps the
/// source (corpus arena) alive for the builder's lifetime.
pub const Build = struct {
    gpa: std.mem.Allocator,
    paths: std.ArrayList([]const u8) = .empty,
    path_idx: std.ArrayList(u32) = .empty,
    spans: std.ArrayList(Span) = .empty,
    silhouettes: std.ArrayList(Silhouette) = .empty,

    pub fn deinit(self: *Build) void {
        self.paths.deinit(self.gpa);
        self.path_idx.deinit(self.gpa);
        self.spans.deinit(self.gpa);
        self.silhouettes.deinit(self.gpa);
    }

    /// Extract `doc`'s functions (language-selected by `path`) and append each
    /// with its structure silhouette. A file with no recognized fragment adds
    /// nothing (its path never enters the table). A silhouette build failure
    /// degrades to `.empty` — maximally far, hides a relation, never invents one.
    pub fn addFile(self: *Build, path: []const u8, doc: []const u8) !void {
        var regs: std.ArrayList(regions.Region) = .empty;
        defer regs.deinit(self.gpa);
        try regions.extractAll(self.gpa, path, doc, 0, &regs);
        if (regs.items.len == 0) return;
        const pidx: u32 = @intCast(self.paths.items.len);
        try self.paths.append(self.gpa, path);
        for (regs.items) |r| {
            const sil = silhouette_mod.build(self.gpa, doc[r.start..r.end]) catch Silhouette.empty;
            try self.spans.append(self.gpa, spanOf(r));
            try self.silhouettes.append(self.gpa, sil);
            try self.path_idx.append(self.gpa, pidx);
        }
    }

    pub fn count(self: *const Build) usize {
        return self.spans.items.len;
    }

    /// The path string for fragment `i`.
    pub fn pathOf(self: *const Build, i: usize) []const u8 {
        return self.paths.items[self.path_idx.items[i]];
    }
};

/// Extract every corpus file into one `Build` (the shared index-build + live
/// rung). Caller keeps `corpus` alive (silhouette rows are values, but path
/// strings borrow it) and calls `deinit`.
pub fn buildAll(gpa: std.mem.Allocator, corpus: *const corpus_mod.Corpus) !Build {
    var b = Build{ .gpa = gpa };
    errdefer b.deinit();
    for (corpus.docs, corpus.paths) |doc, path| try b.addFile(path, doc);
    return b;
}

// ── persistence ──

/// Serialize a built fragment index under the `built_ns` anchor and the `roots`
/// the corpus was built over (so a later fold walks exactly that corpus).
/// Caller frees the blob and persists it (`persist.writeAtomic`).
pub fn save(gpa: std.mem.Allocator, b: *const Build, built_ns: i64, roots: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try out.appendSlice(gpa, MAGIC);
    try putInt(gpa, &out, u32, VERSION);
    try putInt(gpa, &out, i64, built_ns);

    try putInt(gpa, &out, u32, @intCast(b.paths.items.len));
    try putInt(gpa, &out, u64, frame.nulLen(b.paths.items));
    try frame.joinNul(gpa, &out, b.paths.items);

    try putInt(gpa, &out, u64, frame.nulLen(roots));
    try frame.joinNul(gpa, &out, roots);

    try putInt(gpa, &out, u32, @intCast(b.spans.items.len));
    for (b.spans.items, b.path_idx.items, b.silhouettes.items) |span, pidx, *sil| {
        try putInt(gpa, &out, u32, pidx);
        try putInt(gpa, &out, u32, span.byte_start);
        try putInt(gpa, &out, u32, span.byte_end);
        try putInt(gpa, &out, u32, span.line_start);
        try putInt(gpa, &out, u32, span.line_end);
        try putInt(gpa, &out, u16, sil.len);
        for (sil.slots()) |v| try putInt(gpa, &out, u64, v);
    }

    try putInt(gpa, &out, u64, fnv64(out.items));
    return out.toOwnedSlice(gpa);
}

/// The loaded fragment index: a path table, a per-fragment path index + span +
/// structure silhouette, and the build roots the fold walks.
pub const Frag = struct {
    built_ns: i64,
    path_blob: []const u8,
    paths: []const []const u8,
    roots_blob: []const u8,
    roots: []const []const u8,
    path_idx: []u32,
    spans: []Span,
    silhouettes: []Silhouette,

    pub fn deinit(self: *Frag, gpa: std.mem.Allocator) void {
        gpa.free(self.silhouettes);
        gpa.free(self.spans);
        gpa.free(self.path_idx);
        gpa.free(self.roots);
        gpa.free(self.roots_blob);
        gpa.free(self.paths);
        gpa.free(self.path_blob);
    }

    /// The path string for fragment `i`.
    pub fn pathOf(self: *const Frag, i: usize) []const u8 {
        return self.paths[self.path_idx[i]];
    }
};

/// Parse a `save` blob; fails closed on any framing/bounds/checksum violation.
pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) !Frag {
    if (bytes.len < MAGIC.len + 8 or !std.mem.eql(u8, bytes[0..MAGIC.len], MAGIC)) return error.Corrupt;
    const body = bytes[0 .. bytes.len - 8];
    const declared = std.mem.readInt(u64, bytes[bytes.len - 8 ..][0..8], .little);
    if (fnv64(body) != declared) return error.Corrupt;

    var c = Cursor{ .buf = body, .pos = MAGIC.len };
    if (try c.int(u32) != VERSION) return error.Corrupt;
    const built_ns = try c.int(i64);

    const npaths = try c.int(u32);
    const path_blob_len = try c.int(u64);
    const path_blob = try gpa.dupe(u8, try c.bytes(@intCast(path_blob_len)));
    errdefer gpa.free(path_blob);
    const paths = try frame.splitNulExact(gpa, path_blob, npaths, true);
    errdefer gpa.free(paths);

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

    const nfrags = try c.int(u32);
    const path_idx = try gpa.alloc(u32, nfrags);
    errdefer gpa.free(path_idx);
    const spans = try gpa.alloc(Span, nfrags);
    errdefer gpa.free(spans);
    const silhouettes = try gpa.alloc(Silhouette, nfrags);
    errdefer gpa.free(silhouettes);
    for (path_idx, spans, silhouettes) |*pi, *span, *sil| {
        pi.* = try c.int(u32);
        if (pi.* >= npaths) return error.Corrupt; // a fragment must name a real file
        span.* = .{
            .byte_start = try c.int(u32),
            .byte_end = try c.int(u32),
            .line_start = try c.int(u32),
            .line_end = try c.int(u32),
        };
        const len = try c.int(u16);
        if (len > silhouette_mod.k) return error.Corrupt;
        sil.* = Silhouette.empty;
        sil.len = len;
        for (sil.h[0..len]) |*v| v.* = try c.int(u64);
        if (len != 0) for (1..len) |i| if (sil.h[i - 1] > sil.h[i]) return error.Corrupt;
    }
    if (c.pos != body.len) return error.Corrupt;
    return .{
        .built_ns = built_ns,
        .path_blob = path_blob,
        .paths = paths,
        .roots_blob = roots.blob,
        .roots = roots.slices,
        .path_idx = path_idx,
        .spans = spans,
        .silhouettes = silhouettes,
    };
}

/// Load the persisted fragment index, silent on a miss (the verb falls back to a
/// live build); corruption also returns null. The shared fail-open loader, bound
/// to this artifact.
pub fn loadQuiet(gpa: std.mem.Allocator, io: std.Io) ?Frag {
    return frame.loadQuiet(Frag, gpa, io, frag_path.get(), "fragment index", parse);
}

/// Does `path` still exist as a file? The emit-time deletion gate for fragments
/// served from a folded index (O(results), not O(corpus)) — the shared frame gate.
pub const onDisk = frame.onDisk;

// ── the freshness fold ──

/// A folded fragment view: per-fragment path + span + silhouette as of NOW
/// (modulo deletions, gated at emit). Path strings borrow the source `Frag`
/// (unchanged files) or the arena (re-extracted files); silhouettes are values.
pub const Folded = struct {
    arena: std.heap.ArenaAllocator,
    paths: std.ArrayList([]const u8),
    spans: std.ArrayList(Span),
    silhouettes: std.ArrayList(Silhouette),
    refreshed: usize,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *Folded) void {
        self.paths.deinit(self.gpa);
        self.spans.deinit(self.gpa);
        self.silhouettes.deinit(self.gpa);
        self.arena.deinit();
    }
};

/// Fold every file changed since the anchor back in: keep the fragments of
/// unchanged files verbatim, drop and re-extract the fragments of every
/// changed/new file from live bytes. O(changed) files, never O(corpus). A file
/// that no longer reads as a corpus member (unreadable, now-binary, now-empty)
/// contributes no fragments. `roots` is the corpus the index was built over.
pub fn fold(gpa: std.mem.Allocator, io: std.Io, f: *const Frag, roots: []const []const u8) !Folded {
    var out = Folded{
        .arena = std.heap.ArenaAllocator.init(gpa),
        .paths = .empty,
        .spans = .empty,
        .silhouettes = .empty,
        .refreshed = 0,
        .gpa = gpa,
    };
    errdefer out.deinit();
    const a = out.arena.allocator();

    var changed: std.ArrayList([]const u8) = .empty;
    try fresh.changedSince(gpa, io, roots, f.built_ns, a, &changed);

    // The set of files whose persisted fragments are now stale — re-extracted
    // below. Empty ⇒ the whole persisted index is current; copy it wholesale.
    var stale: std.StringHashMapUnmanaged(void) = .empty;
    defer stale.deinit(gpa);
    for (changed.items) |p| try stale.put(gpa, p, {});

    // 1. Keep every fragment whose file did not change.
    for (f.path_idx, f.spans, f.silhouettes) |pidx, span, sil| {
        const path = f.paths[pidx];
        if (stale.contains(path)) continue;
        try out.paths.append(gpa, path);
        try out.spans.append(gpa, span);
        try out.silhouettes.append(gpa, sil);
    }

    // 2. Re-extract every changed/new file's fragments from live bytes. The
    //    changed walk may repeat one path on its degraded path — guard exactly.
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(gpa);
    for (changed.items) |path| {
        if ((try seen.getOrPut(gpa, path)).found_existing) continue;
        const body = corpus_mod.readMember(io, Dir.cwd(), path, a) orelse continue;
        var regs: std.ArrayList(regions.Region) = .empty;
        defer regs.deinit(gpa);
        try regions.extractAll(gpa, path, body, 0, &regs);
        if (regs.items.len == 0) continue;
        const owned = try a.dupe(u8, path);
        out.refreshed += 1;
        for (regs.items) |r| {
            const sil = silhouette_mod.build(gpa, body[r.start..r.end]) catch Silhouette.empty;
            try out.paths.append(gpa, owned);
            try out.spans.append(gpa, spanOf(r));
            try out.silhouettes.append(gpa, sil);
        }
    }
    return out;
}
