//! shelf — a corpus of documents behind one codex.
//!
//! The codex indexes a single byte string; a shelf is the multi-document tier
//! both product faces actually need: it concatenates a corpus (one `\n`
//! sentinel between documents), builds the codex over the whole, and keeps the
//! catalog — each document's path and starting offset — so any corpus
//! position maps back to a file in O(log #docs). On top of that it frames the
//! one persisted artifact (`SHLF`: anchor + catalog + codex blob, all under
//! the codex's own checksummed format discipline) so a later process answers
//! exists/count/tally with ZERO corpus I/O — the index alone.
//!
//! The `\n` separator means a pattern containing no newline can never match
//! across a document boundary, so corpus-wide counts equal the sum of per-file
//! counts for every line-shaped query (the only shape the faces admit).
//! `built_ns` is the wall-clock anchor captured BEFORE the corpus read — the
//! same convention as the trigram index's T3 anchor — so a consumer can state
//! exactly which snapshot an answer is true of.

const std = @import("std");
const codexmod = @import("codex.zig");
const frame = @import("../frame/frame.zig");

const Codex = codexmod.Codex;
const Cursor = frame.Cursor;
const putInt = frame.putInt;

const MAGIC = "SHLF";
const VERSION: u32 = 1;

/// One document's share of a corpus-wide answer.
pub const DocCount = struct { doc: u32, count: u32 };

pub const Shelf = struct {
    cx: Codex,
    paths: []const []const u8, // catalog, doc-id order (owned, one buffer)
    offsets: []u64, // start of each doc in the concatenated text (ascending)
    built_ns: i64, // freshness anchor: wall clock before the corpus read
    path_blob: []const u8, // backing bytes for `paths`

    /// Build over `docs` (bodies) + `paths` (same order). The concatenation is
    /// transient — after `build` returns only the codex and catalog remain.
    pub fn build(gpa: std.mem.Allocator, docs: []const []const u8, paths: []const []const u8, built_ns: i64, opts: codexmod.Options) !Shelf {
        std.debug.assert(docs.len == paths.len);
        var total: usize = 0;
        for (docs) |d| total += d.len + 1;
        const text = try gpa.alloc(u8, total);
        defer gpa.free(text);
        const offsets = try gpa.alloc(u64, docs.len);
        errdefer gpa.free(offsets);
        var at: usize = 0;
        for (docs, offsets) |d, *off| {
            off.* = at;
            @memcpy(text[at..][0..d.len], d);
            text[at + d.len] = '\n'; // sentinel: no newline-free pattern spans docs
            at += d.len + 1;
        }

        var blob: std.ArrayList(u8) = .empty;
        errdefer blob.deinit(gpa);
        try frame.joinNul(gpa, &blob, paths);
        const path_blob = try blob.toOwnedSlice(gpa);
        errdefer gpa.free(path_blob);
        const owned_paths = try frame.splitNulExact(gpa, path_blob, docs.len, false);
        errdefer gpa.free(owned_paths);

        var cx = try Codex.build(gpa, text, opts);
        errdefer cx.deinit(gpa);
        return .{ .cx = cx, .paths = owned_paths, .offsets = offsets, .built_ns = built_ns, .path_blob = path_blob };
    }

    pub fn deinit(self: *Shelf, gpa: std.mem.Allocator) void {
        self.cx.deinit(gpa);
        gpa.free(self.paths);
        gpa.free(self.offsets);
        gpa.free(self.path_blob);
    }

    /// The doc containing corpus position `pos` (binary search on `offsets`).
    pub fn docOf(self: *const Shelf, pos: u64) u32 {
        var lo: usize = 0;
        var hi: usize = self.offsets.len;
        while (hi - lo > 1) {
            const mid = lo + (hi - lo) / 2;
            if (self.offsets[mid] <= pos) lo = mid else hi = mid;
        }
        return @intCast(lo);
    }

    /// Corpus-wide occurrence count — O(|pattern|), zero corpus I/O.
    pub fn count(self: *const Shelf, pattern: []const u8) usize {
        return self.cx.count(pattern);
    }

    /// Per-document occurrence counts, descending by count (path order breaks
    /// ties). Costs one locate per occurrence — O(m + occ·t). Caller frees.
    pub fn tally(self: *const Shelf, gpa: std.mem.Allocator, pattern: []const u8) ![]DocCount {
        const hits = try self.cx.find(gpa, pattern);
        defer gpa.free(hits);
        var per: std.AutoArrayHashMapUnmanaged(u32, u32) = .empty;
        defer per.deinit(gpa);
        for (hits) |pos| (try per.getOrPutValue(gpa, self.docOf(pos), 0)).value_ptr.* += 1;
        const out = try gpa.alloc(DocCount, per.count());
        for (out, per.keys(), per.values()) |*dc, doc, n| dc.* = .{ .doc = doc, .count = n };
        std.mem.sort(DocCount, out, {}, struct {
            fn gt(_: void, x: DocCount, y: DocCount) bool {
                return if (x.count != y.count) x.count > y.count else x.doc < y.doc;
            }
        }.gt);
        return out;
    }

    /// Frame: magic · version · built_ns · doc count · offsets · path blob ·
    /// codex blob (which carries its own checksum). Caller frees.
    pub fn save(self: *const Shelf, gpa: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try out.appendSlice(gpa, MAGIC);
        try putInt(gpa, &out, u32, VERSION);
        try putInt(gpa, &out, i64, self.built_ns);
        try putInt(gpa, &out, u32, @intCast(self.paths.len));
        for (self.offsets) |off| try putInt(gpa, &out, u64, off);
        try putInt(gpa, &out, u64, @intCast(self.path_blob.len));
        try out.appendSlice(gpa, self.path_blob);
        const cx_blob = try self.cx.save(gpa);
        defer gpa.free(cx_blob);
        try putInt(gpa, &out, u64, @intCast(cx_blob.len));
        try out.appendSlice(gpa, cx_blob);
        return out.toOwnedSlice(gpa);
    }

    /// Load a `save` buffer; fails closed on any framing violation, and the
    /// embedded codex re-validates its own checksum + structure.
    pub fn load(gpa: std.mem.Allocator, bytes: []const u8) !Shelf {
        if (bytes.len < 4 or !std.mem.eql(u8, bytes[0..4], MAGIC)) return error.Corrupt;
        var c = Cursor{ .buf = bytes, .pos = 4 };
        if (try c.int(u32) != VERSION) return error.Corrupt;
        const built_ns = try c.int(i64);
        const ndocs = try c.int(u32);
        if (ndocs > bytes.len / 8) return error.Corrupt; // offsets can't outnumber their encoding
        const offsets = try gpa.alloc(u64, ndocs);
        errdefer gpa.free(offsets);
        var prev: u64 = 0;
        for (offsets, 0..) |*off, i| {
            off.* = try c.int(u64);
            if (i > 0 and off.* <= prev) return error.Corrupt; // strictly ascending
            prev = off.*;
        }
        if (ndocs > 0 and offsets[0] != 0) return error.Corrupt;
        const blob_len = try c.int(u64);
        const path_blob = try gpa.dupe(u8, try c.bytes(@intCast(blob_len)));
        errdefer gpa.free(path_blob);
        const paths = try frame.splitNulExact(gpa, path_blob, ndocs, false);
        errdefer gpa.free(paths);
        const cx_len = try c.int(u64);
        const cx_bytes = try c.bytes(@intCast(cx_len));
        if (c.pos != bytes.len) return error.Corrupt;
        var cx = try Codex.load(gpa, cx_bytes);
        errdefer cx.deinit(gpa);
        if (ndocs > 0 and offsets[ndocs - 1] >= cx.len()) return error.Corrupt;
        return .{ .cx = cx, .paths = paths, .offsets = offsets, .built_ns = built_ns, .path_blob = path_blob };
    }
};
