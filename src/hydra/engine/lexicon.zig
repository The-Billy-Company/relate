//! hydra — the lexicon: a corpus-priced fingerprint index, hand-rolled.
//!
//! The recall half of compression-as-search. The question is Benedetto,
//! Caglioti & Loreto's ("Language Trees and Zipping", 2001): which docs
//! would describe this query cheaply? Answering it exactly per doc is the
//! zipper's job (`zipper.zig`, the Ziv–Merhav cross-parse); answering it
//! across N docs at once needs an index, and the index must NOT inherit a
//! compressor's parse: the first draft of this module borrowed LZJD's LZ78
//! phrase dictionary and lost short queries to boundary noise — LZ78 phrase
//! boundaries are an artifact of parse ORDER, so two texts sharing a
//! paragraph need not share one phrase (measured; see lexicon_test.zig).
//!
//! The hand-rolled replacement is boundary-free by construction:
//!
//!   Fingerprints (winnowing — Schleimer/Wilkerson/Aiken 2003, the MOSS
//!   sampler). Hash every `gram`-byte window of a doc; within each run of
//!   `window` consecutive hashes keep the minimum. GUARANTEE: any shared
//!   substring of at least gram+window−1 bytes shares at least one selected
//!   fingerprint, wherever it sits in either text. Selection depends only
//!   on content, never on a parse.
//!
//!   Pricing (Shannon). A fingerprint's information content in this corpus
//!   is −log2(df/N) bits: boilerplate every doc carries prices at EXACTLY
//!   zero — it cannot rank anything — while a fingerprint unique to one doc
//!   is worth log2 N. `bitsSaved(q, doc)` = Σ price over the query
//!   fingerprints the doc contains: the bits of q's description that doc
//!   has already paid for. IDF is not imported from information retrieval;
//!   it falls out of the coding argument.
//!
//! `retrieve` composes the two halves: the lexicon nominates (cheap,
//! index-shaped, no doc bytes touched), the zipper decides (exact
//! conditional description length per candidate). Kernel profile: explicit
//! allocator, no I/O, deterministic (ties never swap); a built `Lexicon` is
//! immutable and thread-safe.

const std = @import("std");
const zipper = @import("zipper.zig");

/// Fingerprint window: one hash per `gram` consecutive bytes. Eight bytes —
/// past the trigram floor where style begins, short enough that a one-line
/// query still carries dozens of fingerprints.
pub const gram = 8;

/// Winnowing window: keep the minimum hash of every `window` consecutive
/// gram-hashes. Density ≈ 2/(window+1) of positions; the shared-substring
/// guarantee threshold is gram + window − 1 = 11 bytes.
pub const window = 4;

/// Minimum shared-substring length the index is guaranteed to see.
pub const guarantee = gram + window - 1;

const fnv_offset: u64 = 0xcbf29ce484222325;
const fnv_prime: u64 = 0x100000001b3;

/// splitmix64 finalizer — same spreader the sketch uses; gram-hash values
/// must look uniform for min-selection to sample content-independently.
inline fn finalize(x: u64) u64 {
    var z = x +% 0x9e3779b97f4a7c15;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

/// One ranked recall answer: `bits` of the query's description this doc
/// already paid for (higher = closer).
pub const Hit = struct {
    doc: u32,
    bits: f64,
};

/// One two-stage answer: nominated by the lexicon, decided by the zipper.
pub const Ranked = struct {
    doc: u32,
    bits_saved: f64,
    cost: zipper.Cost,
};

/// The winnowed fingerprint set of `bytes`: sorted, deduplicated. Caller
/// frees. O(n) time, one pass; deterministic.
pub fn fingerprints(gpa: std.mem.Allocator, bytes: []const u8) ![]u64 {
    if (bytes.len < gram) return gpa.alloc(u64, 0);
    const n_hashes = bytes.len - gram + 1;

    var out: std.ArrayListUnmanaged(u64) = .empty;
    errdefer out.deinit(gpa);

    // Ring of the last `window` gram-hashes; emit each window's minimum.
    // (Same winnowing rule as MOSS: rightmost minimum, emitted on change.)
    var ring: [window]u64 = undefined;
    var last_emitted: u64 = 0;
    var has_emitted = false;
    for (0..n_hashes) |i| {
        var h: u64 = fnv_offset;
        for (bytes[i .. i + gram]) |b| h = (h ^ b) *% fnv_prime;
        ring[i % window] = finalize(h);
        if (i + 1 < window) continue;
        var m = ring[0];
        for (ring[1..]) |v| m = @min(m, v);
        if (!has_emitted or m != last_emitted) {
            try out.append(gpa, m);
            last_emitted = m;
            has_emitted = true;
        }
    }

    // Tiny docs (< window hashes): keep every hash — better exact than blind.
    if (n_hashes < window) {
        for (0..n_hashes) |i| try out.append(gpa, ring[i % window]);
    }

    const slice = try out.toOwnedSlice(gpa);
    std.mem.sort(u64, slice, {}, comptime std.sort.asc(u64));
    var w: usize = 0;
    for (slice) |v| {
        if (w > 0 and v == slice[w - 1]) continue;
        slice[w] = v;
        w += 1;
    }
    if (w == slice.len) return slice;
    defer gpa.free(slice);
    return gpa.dupe(u64, slice[0..w]);
}

fn containsSorted(haystack: []const u64, needle: u64) bool {
    return std.sort.binarySearch(u64, haystack, needle, orderU64) != null;
}

fn orderU64(ctx: u64, item: u64) std.math.Order {
    return std.math.order(ctx, item);
}

/// The corpus fingerprint lexicon: per-doc winnowed sets + the inverted
/// document-frequency view that prices every fingerprint. Borrows `docs`
/// (needed by the zipper stage); immutable and thread-safe once built.
pub const Lexicon = struct {
    gpa: std.mem.Allocator,
    docs: []const []const u8,
    sets: [][]u64,
    /// fingerprint → number of docs whose set contains it
    df: std.AutoHashMapUnmanaged(u64, u32),

    /// Fingerprint every doc and fold the document-frequency table.
    /// O(total bytes).
    pub fn build(gpa: std.mem.Allocator, docs: []const []const u8) !Lexicon {
        const sets = try gpa.alloc([]u64, docs.len);
        var built: usize = 0;
        errdefer {
            for (sets[0..built]) |s| gpa.free(s);
            gpa.free(sets);
        }
        var df: std.AutoHashMapUnmanaged(u64, u32) = .empty;
        errdefer df.deinit(gpa);

        for (docs, 0..) |bytes, i| {
            sets[i] = try fingerprints(gpa, bytes);
            built = i + 1;
            for (sets[i]) |fp| {
                const gop = try df.getOrPut(gpa, fp);
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += 1;
            }
        }
        return .{ .gpa = gpa, .docs = docs, .sets = sets, .df = df };
    }

    pub fn deinit(self: *Lexicon) void {
        for (self.sets) |s| self.gpa.free(s);
        self.gpa.free(self.sets);
        self.df.deinit(self.gpa);
    }

    pub fn docCount(self: *const Lexicon) usize {
        return self.docs.len;
    }

    /// The information content of one fingerprint in this corpus:
    /// −log2(df/N) bits. Present in every doc ⇒ exactly 0; unique to one
    /// doc ⇒ log2 N; known to no doc ⇒ 0 (nothing was saved anywhere).
    pub fn fingerprintBits(self: *const Lexicon, fp: u64) f64 {
        const n = self.docs.len;
        if (n == 0) return 0.0;
        const df = self.df.get(fp) orelse return 0.0;
        return -std.math.log2(@as(f64, @floatFromInt(df)) / @as(f64, @floatFromInt(n)));
    }

    /// bitsSaved: Î(q; doc) over the winnowed index — Σ price of the query
    /// fingerprints this doc's set contains. `query_fps` from
    /// `fingerprints()`. O(|q_fps| log |set|); no doc bytes touched.
    pub fn bitsSaved(self: *const Lexicon, query_fps: []const u64, doc: u32) f64 {
        var bits: f64 = 0.0;
        for (query_fps) |fp| {
            if (containsSorted(self.sets[doc], fp)) bits += self.fingerprintBits(fp);
        }
        return bits;
    }

    /// Recall: rank every doc by bitsSaved. bits desc, doc asc on ties;
    /// only bits > 0 appear; at most `top`. Caller frees. No doc bytes
    /// touched — pure index work.
    pub fn rank(self: *const Lexicon, gpa: std.mem.Allocator, query: []const u8, top: usize) ![]Hit {
        const qfps = try fingerprints(gpa, query);
        defer gpa.free(qfps);

        var hits: std.ArrayListUnmanaged(Hit) = .empty;
        errdefer hits.deinit(gpa);
        for (0..self.sets.len) |d| {
            const bits = self.bitsSaved(qfps, @intCast(d));
            if (bits > 0.0) try hits.append(gpa, .{ .doc = @intCast(d), .bits = bits });
        }
        std.mem.sort(Hit, hits.items, {}, hitBefore);
        if (hits.items.len > top) hits.shrinkRetainingCapacity(top);
        return hits.toOwnedSlice(gpa);
    }

    /// Precision: the exact conditional description length of `query` under
    /// this doc — build the doc's suffix automaton, cross-parse, tear down.
    /// O(|doc| + |q|).
    pub fn crossCost(self: *const Lexicon, gpa: std.mem.Allocator, doc: u32, query: []const u8) !zipper.Cost {
        var a = try zipper.Automaton.build(gpa, self.docs[doc]);
        defer a.deinit();
        return a.crossParse(query);
    }

    /// The full two-stage retrieval: the lexicon nominates a candidate pool
    /// (4× the ask, min 8 — recall is noisy at the margin and the exact
    /// stage may overturn it), the zipper decides. Final order: conditional
    /// cost asc, then bits_saved desc, then doc asc. Caller frees.
    pub fn retrieve(self: *const Lexicon, gpa: std.mem.Allocator, query: []const u8, top: usize) ![]Ranked {
        const pool = try self.rank(gpa, query, @max(top * 4, 8));
        defer gpa.free(pool);

        var out: std.ArrayListUnmanaged(Ranked) = .empty;
        errdefer out.deinit(gpa);
        try out.ensureTotalCapacityPrecise(gpa, pool.len);
        for (pool) |h| {
            const c = try self.crossCost(gpa, h.doc, query);
            out.appendAssumeCapacity(.{ .doc = h.doc, .bits_saved = h.bits, .cost = c });
        }
        std.mem.sort(Ranked, out.items, {}, rankedBefore);
        if (out.items.len > top) out.shrinkRetainingCapacity(top);
        return out.toOwnedSlice(gpa);
    }

    fn hitBefore(_: void, a: Hit, b: Hit) bool {
        if (a.bits != b.bits) return a.bits > b.bits;
        return a.doc < b.doc;
    }

    fn rankedBefore(_: void, a: Ranked, b: Ranked) bool {
        if (a.cost.bits != b.cost.bits) return a.cost.bits < b.cost.bits;
        if (a.bits_saved != b.bits_saved) return a.bits_saved > b.bits_saved;
        return a.doc < b.doc;
    }
};

/// The unconditioned baseline (re-exported for callers scoring gain).
pub const coldBits = zipper.coldBits;
