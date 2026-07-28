//! irregex — the RELATE half: compression-kinship sketches.
//!
//! Where a regular expression asks "do these bytes MATCH this shape?", the
//! irregular half asks "how much do these bytes RESEMBLE those bytes?" — with
//! zero parsing, over any language. The signal is the relative-entropy
//! distance of Benedetto, Caglioti & Loreto ("Language Trees and Zipping",
//! Phys. Rev. Lett. 88, 048702 / cond-mat/0108530): two texts are close when
//! one compresses well in the other's dictionary. The mechanism is the fast
//! successor to running a real compressor per pair — the Lempel–Ziv Jaccard
//! Distance of Raff & Nicholas (KDD 2017): parse each text into its LZ78
//! phrase DICTIONARY, then compare dictionaries as sets. Same signal as NCD,
//! comparable-or-better accuracy, and the sets min-hash down to a fixed-size
//! sketch, so a repo-scale distance query is O(k) per pair instead of a
//! compressor run.
//!
//! Three primitives, kernel-profile (explicit allocator for scratch only, no
//! I/O, thread-safe by construction — a built `Sketch` is immutable):
//!
//!   build(bytes)          → Sketch     one LZ78 parse, bottom-k of the phrase hashes
//!   distance(a, b)        → f64        1 − Jaccard, estimated from the two sketches
//!   Sketch (value type)   fixed k=128 u64 slots — mmap-friendly, mergeable, tiny
//!
//! The sketch is a KMV ("k minimum values") summary: the k smallest 64-bit
//! phrase hashes, ascending. Jaccard between two KMV sketches is estimated on
//! the k smallest of their UNION (Beyer et al., SIGMOD 2007) — an unbiased
//! estimator that needs no per-permutation signatures, stays mergeable, and
//! keeps the record a flat `[k]u64` a future persisted-blob section can alias
//! zero-copy (the same discipline as the trigram posting table).
//!
//! Phrase identity is a 64-bit hash, never the phrase bytes (LZJD does the
//! same): an FNV-1a accumulator extends per byte — O(1)/byte, no substring
//! materialization — and a splitmix64 finalizer spreads it to the uniformity
//! bottom-k selection assumes. Hash collisions merely coalesce two phrases;
//! at 2^64 the effect on a k=128 estimate is beneath measurement.

const std = @import("std");

/// Sketch width. 128 slots × 8 bytes = 1 KiB/file; the standard MinHash
/// operating range (100–200 hashes) puts the Jaccard estimator's standard
/// error at ~1/√k ≈ 0.09 — ample for nearest-neighbor ranking.
pub const k = 128;

/// Phrases shorter than this stay in the LZ dictionary (they must — the
/// parse's phrase boundaries depend on them) but are NOT offered to the
/// sketch. Every text over one character set shares the 1–2 byte phrase
/// base, so admitting it spends sketch slots on a constant noise floor that
/// washes out kinship (measured on this repo with min=1: `relate similar` on a
/// Zig kernel surfaced Rust, Markdown, and TSX within ±0.02 of each other).
/// Three bytes is where style begins — the same floor the trigram index is
/// built on. Length, not content — the parse itself stays classic LZ78.
pub const min_phrase = 3;

/// A file's compression-kinship summary: the `len` smallest distinct phrase
/// hashes of its LZ78 dictionary, ascending in `h[0..len]`. `len < k` only
/// for tiny inputs whose whole dictionary fits. A value type — copy, persist,
/// or share across threads freely; nothing points back at the parsed bytes.
pub const Sketch = struct {
    h: [k]u64,
    len: u16,

    pub const empty: Sketch = .{ .h = @splat(0), .len = 0 };

    /// The sketch's phrase-hash slots, ascending.
    pub fn slots(self: *const Sketch) []const u64 {
        return self.h[0..self.len];
    }
};

// The FNV constants and splitmix64 finalizer live in `math/mix.zig` —
// generic bit-spreading, not kinship. Bound privately so the parse below
// reads unchanged.
const mix = @import("../../math/mix.zig");
const fnv_offset = mix.fnv_offset;
const fnv_prime = mix.fnv_prime;
const finalize = mix.finalize;

/// Open-addressed u64 set for the seen-phrase dictionary — the only scratch
/// the parse needs. Power-of-two capacity, linear probing, grow at 7/8 load.
/// Key 0 is the empty slot sentinel; a real hash of 0 remaps to 1 (one
/// phrase pair coalesced per 2^64 — beneath the estimator's noise floor).
const PhraseSet = struct {
    slots: []u64,
    count: usize,

    fn init(gpa: std.mem.Allocator, cap_hint: usize) !PhraseSet {
        const cap = std.math.ceilPowerOfTwoAssert(usize, @max(cap_hint, 64)); // hint is bounded by per-file caps far below overflow
        const slots = try gpa.alloc(u64, cap);
        @memset(slots, 0);
        return .{ .slots = slots, .count = 0 };
    }

    fn deinit(self: *PhraseSet, gpa: std.mem.Allocator) void {
        gpa.free(self.slots);
    }

    /// Insert `key`; returns true when it was NEW. Grows before the probe
    /// chain can degrade, so the parse stays O(1) amortized per phrase.
    fn insert(self: *PhraseSet, gpa: std.mem.Allocator, key_in: u64) !bool {
        const key = if (key_in == 0) 1 else key_in;
        if (self.count * 8 >= self.slots.len * 7) try self.grow(gpa);
        const mask = self.slots.len - 1;
        // `key` is a u64 hash and `mask` a slot index, so the masked probe is
        // ≤ `mask` and narrows exactly — but only an explicit cast says so on a
        // 32-bit target, where peer resolution would otherwise leave `i` u64.
        var i: usize = @intCast(key & mask);
        while (true) : (i = (i + 1) & mask) {
            const s = self.slots[i];
            if (s == key) return false;
            if (s == 0) {
                self.slots[i] = key;
                self.count += 1;
                return true;
            }
        }
    }

    fn grow(self: *PhraseSet, gpa: std.mem.Allocator) !void {
        const old = self.slots;
        self.slots = try gpa.alloc(u64, old.len * 2);
        @memset(self.slots, 0);
        const mask = self.slots.len - 1;
        for (old) |key| {
            if (key == 0) continue;
            var i: usize = @intCast(key & mask); // exact: masked to a slot index
            while (self.slots[i] != 0) i = (i + 1) & mask;
            self.slots[i] = key;
        }
        gpa.free(old);
    }
};

/// Bottom-k tracker: a size-`k` max-heap so the common case (candidate ≥
/// current worst) is one compare, no write. O(n log k) worst case.
const BottomK = struct {
    heap: [k]u64, // max-heap once saturated
    len: u16,

    const init: BottomK = .{ .heap = @splat(0), .len = 0 };

    fn offer(self: *BottomK, v: u64) void {
        if (self.len < k) {
            // Filling phase: append then sift up.
            self.heap[self.len] = v;
            self.len += 1;
            var i: usize = self.len - 1;
            while (i > 0) {
                const parent = (i - 1) / 2;
                if (self.heap[parent] >= self.heap[i]) break;
                std.mem.swap(u64, &self.heap[parent], &self.heap[i]);
                i = parent;
            }
            return;
        }
        if (v >= self.heap[0]) return; // not smaller than the worst kept
        // Replace the max, sift down.
        self.heap[0] = v;
        var i: usize = 0;
        while (true) {
            const l = 2 * i + 1;
            const r = 2 * i + 2;
            var m = i;
            if (l < k and self.heap[l] > self.heap[m]) m = l;
            if (r < k and self.heap[r] > self.heap[m]) m = r;
            if (m == i) break;
            std.mem.swap(u64, &self.heap[i], &self.heap[m]);
            i = m;
        }
    }
};

/// Parse `bytes` into its LZ78 phrase dictionary and return the bottom-k
/// sketch of the phrase hashes. One pass, O(1)/byte; `gpa` covers only the
/// seen-phrase scratch set, freed before return. Deterministic: the same
/// bytes always produce the same sketch, on every platform (no pointers, no
/// iteration-order dependence).
pub fn build(gpa: std.mem.Allocator, bytes: []const u8) !Sketch {
    // LZ78 phrase count grows ~n/log n; /8 is a comfortable overshoot that
    // avoids most grows without over-reserving for incompressible input.
    var seen = try PhraseSet.init(gpa, bytes.len / 8);
    defer seen.deinit(gpa);
    var low: BottomK = .init;

    var h: u64 = fnv_offset;
    var plen: usize = 0;
    for (bytes) |b| {
        h = (h ^ b) *% fnv_prime;
        plen += 1;
        if (try seen.insert(gpa, h)) {
            if (plen >= min_phrase) low.offer(finalize(h));
            h = fnv_offset; // phrase complete — start the next one
            plen = 0;
        }
        // else: the phrase is already in the dictionary; keep extending it.
    }
    // A trailing partial phrase (already in the dictionary) is dropped —
    // classic LZ78 tail behavior; its prefix phrases are all present.

    var out = Sketch.empty;
    out.len = low.len;
    @memcpy(out.h[0..low.len], low.heap[0..low.len]);
    std.mem.sort(u64, out.h[0..out.len], {}, comptime std.sort.asc(u64));
    return out;
}

// ── the KMV estimator ──────────────────────────────────────────────────────
//
// Both kinship channels — bytes (`Sketch`) and structure (`Silhouette`) —
// price a pair here, so this merge IS the cost of every repetition sweep,
// every nomination, and every neighbor probe. A `relate echoes --shape
// distinct` run over this repo calls it ~760M times, which is why it is
// written as a block kernel rather than the obvious three-way branch: at one
// element per iteration the branch is data-dependent and unpredictable by
// construction (two uncorrelated hash streams interleave at random), so a
// scalar merge spends most of its cycles on mispredicted branches rather than
// on comparisons.

/// Elements compared per block step. Both blocks are compared all-pairs, so
/// the compare count grows as `lanes²` while the elements retired grow as
/// `lanes` — but the loop-carried branch is paid once per BLOCK, and on real
/// records that trade keeps paying out to 8 (measured: 4.0× at k=128 and 2.4×
/// at k=256 over the shipped scalar merge; 16 loses to the compare growth).
const lanes = 8;
const Block = @Vector(lanes, u64);

/// Lane `t` of `rotation(r)` selects source lane `t + r`, so the `lanes`
/// rotations of one block sweep every pairing exactly once.
inline fn rotation(comptime r: usize) @Vector(lanes, i32) {
    var m: [lanes]i32 = undefined;
    for (&m, 0..) |*e, t| e.* = @intCast((t + r) % lanes);
    return m;
}

/// How many values two ascending blocks share. Counts accumulate in a vector
/// and reduce once, because extracting a comparison mask to a scalar per
/// rotation costs more than the comparison it reports on both NEON and AVX.
/// Ascending-and-distinct is what makes the popcount exact: a value can match
/// at most one lane on either side, so no pairing is counted twice.
inline fn blockShared(va: Block, vb: Block) usize {
    const one: Block = @splat(1);
    const zero: Block = @splat(0);
    var acc: Block = zero;
    inline for (0..lanes) |r| {
        const rot = @shuffle(u64, vb, undefined, rotation(r));
        acc += @select(u64, va == rot, one, zero);
    }
    return @intCast(@reduce(.Add, acc));
}

/// The estimator's one arithmetic definition, so every bound, abort, and
/// answer in this module is the SAME f64 expression. It is non-increasing in
/// `shared`, which is what lets an upper bound on `shared` stand in for the
/// distance when deciding to give up early.
inline fn jaccard(shared: usize, budget: usize) f64 {
    return 1.0 - @as(f64, @floatFromInt(shared)) / @as(f64, @floatFromInt(budget));
}

/// A shared count below which the pair has certainly lost — the integer
/// restatement of `distance > ceiling`, so the merge can quit on counts instead
/// of dividing.
///
/// Deliberately **conservative**: it may sit one hash below the true threshold,
/// and never above it. That asymmetry is what makes it cheap. The verdict a
/// caller receives is always `jaccard` compared against `ceiling` directly
/// (see `admit`), so this number only ever decides *when to stop merging* —
/// under-shooting costs one pair a slightly later exit, while the exact
/// restatement it replaces cost every pair two float divides in a correction
/// loop, which on a twenty-slot silhouette is the entire merge.
fn abortFloor(budget: usize, ceiling: f64) usize {
    if (ceiling >= 1.0) return 0; // every distance is ≤ 1: nothing to prove
    if (!(ceiling >= 0.0)) return budget + 1; // NaN or negative: unreachable
    const exact = (1.0 - ceiling) * @as(f64, @floatFromInt(budget));
    const floor: usize = @intFromFloat(@max(0.0, @floor(exact)));
    return floor -| 1; // one hash of slack absorbs any rounding in `exact`
}

/// Admit an exact distance against a ceiling — the one place the contract
/// "null means, and only means, `distance > ceiling`" is spelled.
inline fn admit(d: f64, ceiling: f64) ?f64 {
    return if (d <= ceiling) d else null;
}

/// How many of the bottom-`budget` union values the two records share.
///
/// `floor` is a count the pair must still be able to reach for its distance to
/// have any chance of clearing its caller's ceiling; the walk abandons a pair
/// whose remaining values can no longer reach it and answers null.
///
/// `bounded` is comptime so that the unbounded question — which is most of
/// them, and the one `kmvDistance` asks — compiles to a merge with no abort
/// test in it at all, rather than one carrying a branch it can never take.
fn sharedCount(
    as: []const u64,
    bs: []const u64,
    budget: usize,
    comptime bounded: bool,
    floor: usize,
) ?usize {
    var i: usize = 0;
    var j: usize = 0;
    var hits: usize = 0;
    // Retire whole blocks while a step provably cannot overshoot the budget:
    // one step consumes at most `lanes` from each side, so `2*lanes` of slack
    // is the safe margin. Advancing the side with the smaller maximum keeps
    // every match inside the block pair being compared, exactly as the
    // one-at-a-time merge would find it.
    while (i + lanes <= as.len and j + lanes <= bs.len and
        i + j - hits + 2 * lanes < budget)
    {
        const va: Block = as[i..][0..lanes].*;
        const vb: Block = bs[j..][0..lanes].*;
        hits += blockShared(va, vb);
        const ahi = as[i + lanes - 1];
        const bhi = bs[j + lanes - 1];
        i += if (ahi <= bhi) lanes else 0;
        j += if (bhi <= ahi) lanes else 0;
        // Nothing left to find can reach the ceiling: give up on the pair
        // rather than merge the rest of two records that already lost.
        if (bounded and
            hits + @min(@min(as.len - i, bs.len - j), budget - (i + j - hits)) < floor)
            return null;
    }

    // The tail, one union value at a time. Branchless because by here the
    // remaining work is short enough that a mispredict costs more than the two
    // extra increments.
    var taken = i + j - hits;
    while (taken < budget and i < as.len and j < bs.len) {
        const av = as[i];
        const bv = bs[j];
        hits += @intFromBool(av == bv);
        i += @intFromBool(av <= bv);
        j += @intFromBool(av >= bv);
        taken += 1;
    }
    return hits;
}

/// KMV Jaccard distance between two ascending bottom-k hash slices (Beyer et
/// al., SIGMOD 2007): `1 − Ĵ(A,B)`, estimating Jaccard on the k smallest of the
/// union. 0 = identical set, → 1 = nothing shared. Symmetric; O(k). Two EMPTY
/// slices are distance 0; one empty against a non-empty is 1. The one estimator
/// both kinship channels share — bytes (`Sketch`) and structure (`Silhouette`).
pub fn kmvDistance(as: []const u64, bs: []const u64) f64 {
    // A distance can never exceed 1, so the unbounded question is the bounded
    // one with a ceiling nothing can fail — one kernel, not two that can drift.
    return kmvWithin(as, bs, 1.0).?;
}

/// The distance, or null when it provably exceeds `ceiling`.
///
/// Every caller of this estimator is really asking a bounded question — is
/// this pair inside `--max-distance`, is it nearer than the nearest miss so
/// far, does it belong in the top N — and answering the unbounded one first
/// throws away the cheapest information available: a pair whose records barely
/// overlap in range cannot be close, and no merge is needed to say so. Null is
/// exactly `distance > ceiling`; a returned value is exactly what
/// `kmvDistance` returns, to the bit.
pub fn kmvWithin(as: []const u64, bs: []const u64, ceiling: f64) ?f64 {
    if (as.len == 0 and bs.len == 0) return admit(0.0, ceiling);
    if (as.len == 0 or bs.len == 0) return admit(1.0, ceiling);

    // The merge counts intersections among the first `budget` distinct union
    // values — never judge past the resolution either bottom-k set actually
    // has. Values beyond it on one side still consume budget but can no longer
    // intersect; they only dilute (correctly).
    const budget = @min(as.len, bs.len);

    // Ranges that do not overlap at all share nothing, and two compares say so.
    if (as[as.len - 1] < bs[0] or bs[bs.len - 1] < as[0]) return admit(1.0, ceiling);

    // The abort fires once remaining capacity falls under `floor`, so a bounded
    // merge retires about `budget - floor` slots where the full one retires
    // `budget`: cost tracks the ceiling, and a tight one is answered in a
    // fraction of the work. Measured over this repository, a 0.05 ceiling on
    // file sketches is 8.2× and a 0.15 one 4.4×, which is where `--max-distance`
    // lives; a ceiling loose enough to admit most pairs converges on the plain
    // merge, having skipped nothing and cost a handful of instructions to try.
    const floor = abortFloor(budget, ceiling);
    const hits = if (floor > 0)
        sharedCount(as, bs, budget, true, floor) orelse return null
    else
        sharedCount(as, bs, budget, false, 0).?;
    return admit(jaccard(hits, budget), ceiling);
}

/// LZJD distance between two sketches: the shared KMV estimator over their
/// LZ78 phrase-hash bottom-k. 0 = same dictionary, → 1 = nothing shared.
pub fn distance(a: *const Sketch, b: *const Sketch) f64 {
    return kmvDistance(a.slots(), b.slots());
}

/// That distance, or null when it provably exceeds `ceiling` — see `kmvWithin`.
pub fn within(a: *const Sketch, b: *const Sketch, ceiling: f64) ?f64 {
    return kmvWithin(a.slots(), b.slots(), ceiling);
}
