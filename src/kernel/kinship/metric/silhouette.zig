//! irregex — the STRUCTURE half of kinship: silhouette sketches.
//!
//! The LZJD sketch (sketch.zig) measures kinship over raw bytes, so its
//! signal is vocabulary-dominated: two modules with the same skeleton but
//! different identifiers (Type-2 clones, in the Roy–Cordy clone taxonomy)
//! land in its ≥0.5 noise zone. The silhouette is the same file with the
//! vocabulary stripped away — a deliberate squint, not a parse:
//!
//!   string literals → S    numbers → N    comments → dropped
//!   identifiers     → I    (a pan-language keyword set survives verbatim —
//!                           keywords ARE structure)    whitespace → dropped
//!
//! then MOSS-style fingerprinting over the normalized TOKEN stream
//! (Schleimer, Wilkerson & Aiken, "Winnowing: Local Algorithms for Document
//! Fingerprinting", SIGMOD 2003): hash every `gram`-token shingle, keep the
//! minimum of every `window` consecutive shingle hashes (so any shared run
//! of gram+window−1 tokens is guaranteed a shared fingerprint), and KMV
//! bottom-k the picks into a flat, mergeable record — the same estimator
//! discipline as the LZJD sketch (Beyer et al., SIGMOD 2007).
//!
//! Why token shingles and not normalize-then-LZ78: normalization shrinks the
//! alphabet to ~I/N/S/keywords/punctuation, so LZ78 phrase dictionaries over
//! the normalized bytes go generic — kinship inflates uniformly and
//! discrimination dies (measured: renamed-twin retrieval got WORSE than raw,
//! twin@1 0.50 → 0.33 on the hard corpus). Positional shingles keep the
//! token-sequence structure that whole-phrase dictionaries wash out
//! (twin@1 0.50 → 0.83, MRR 0.676 → 0.889 on the same corpus).
//!
//! The scanner is language-agnostic on purpose (relate's covenant: no
//! parsers, no language list): quote/comment openers and identifier shapes
//! are recognized generically, and the keyword set is the UNION of the
//! structural words across Billy's languages. Misclassifying a `#` inside a
//! C string or a keyword-named identifier merely perturbs a few shingles —
//! the estimator absorbs it; it can never crash or reorder a parse.
//!
//! Kernel-profile like sketch.zig: explicit allocator for scratch only, no
//! I/O, deterministic (same bytes ⇒ same silhouette on every platform), and
//! a built `Silhouette` is an immutable value type.

const std = @import("std");
const sketch = @import("sketch.zig");
const mix = @import("irregex").inner.math.mix;

/// Sketch width. Structure fingerprints are sparser than LZ78 phrases and
/// renamed-twin ranking measurably degrades at 128 (twin@1 0.83 → 0.67 on
/// the hard-corpus eval); 256 matches the exact-set answer at 2 KiB/file.
pub const k = 256;

/// Shingle width in TOKENS (MOSS's t): two files share a fingerprint only if
/// they share `gram` consecutive normalized tokens.
pub const gram = 5;

/// Winnow window (MOSS's w): every `window` consecutive shingles contribute
/// at least one fingerprint, so any shared token run of gram+window−1 = 8
/// tokens is guaranteed to surface in both files' fingerprint sets.
pub const window = 4;

/// A file's structure summary: the `len` smallest distinct fingerprints of
/// its winnowed normalized-token shingles, ascending in `h[0..len]`.
/// `len < k` only for inputs too short to shed k fingerprints. A value type —
/// copy, persist, or share across threads freely.
pub const Silhouette = struct {
    h: [k]u64,
    len: u16,

    pub const empty: Silhouette = .{ .h = @splat(0), .len = 0 };

    /// The fingerprint slots, ascending.
    pub fn slots(self: *const Silhouette) []const u64 {
        return self.h[0..self.len];
    }
};

/// Structure distance: the shared KMV estimator (`sketch.kmvDistance`) over the
/// winnowed shingle bottom-k. 0 = same shape, → 1 = nothing shared. Symmetric;
/// O(k). Two EMPTY silhouettes (both inputs shorter than one shingle) are 0.
pub fn distance(a: *const Silhouette, b: *const Silhouette) f64 {
    return sketch.kmvDistance(a.slots(), b.slots());
}

/// That distance, or null when it provably exceeds `ceiling` — see
/// `sketch.kmvWithin`. Structure is the channel a nearest-miss sweep ranks on,
/// and a sweep only ever needs the distances that beat the one it is holding.
pub fn within(a: *const Silhouette, b: *const Silhouette, ceiling: f64) ?f64 {
    return sketch.kmvWithin(a.slots(), b.slots(), ceiling);
}

// ── the pan-language keyword shelf ──
// One closed union of the structural words across Billy's seven languages
// (no per-file language detection). Keywords survive normalization verbatim;
// every other identifier-shaped run becomes the class token I.
const keywords = std.StaticStringMap(void).initComptime(.{
    .{"and"},        .{"as"},       .{"assert"},         .{"async"},    .{"await"},
    .{"break"},      .{"case"},     .{"catch"},          .{"class"},    .{"comptime"},
    .{"const"},      .{"continue"}, .{"def"},            .{"defer"},    .{"do"},
    .{"elif"},       .{"else"},     .{"enum"},           .{"errdefer"}, .{"except"},
    .{"exhaustive"}, .{"extern"},   .{"false"},          .{"final"},    .{"finally"},
    .{"fn"},         .{"for"},      .{"from"},           .{"func"},     .{"go"},
    .{"guard"},      .{"if"},       .{"impl"},           .{"import"},   .{"in"},
    .{"init"},       .{"inline"},   .{"interface"},      .{"is"},       .{"let"},
    .{"loop"},       .{"map"},      .{"match"},          .{"mod"},      .{"mut"},
    .{"nil"},        .{"none"},     .{"not"},            .{"null"},     .{"or"},
    .{"orelse"},     .{"package"},  .{"pass"},           .{"protocol"}, .{"pub"},
    .{"raise"},      .{"range"},    .{"return"},         .{"select"},   .{"self"},
    .{"static"},     .{"struct"},   .{"switch"},         .{"test"},     .{"throw"},
    .{"throws"},     .{"trait"},    .{"true"},           .{"try"},      .{"type"},
    .{"union"},      .{"unsafe"},   .{"usingnamespace"}, .{"var"},      .{"void"},
    .{"where"},      .{"while"},    .{"with"},           .{"yield"},
});

// Identifier byte classes come from `anatomy/token.zig` — one definition
// shared with the dependency scanner, so the two planes cannot drift.
const token = @import("../../anatomy/token.zig");
const isIdentStart = token.isIdentStart;
const isIdentCont = token.isIdentByte;
fn isNumCont(c: u8) bool {
    // Digits, radix/exponent letters, separators, and the decimal point —
    // one class token N regardless of base or width suffix.
    return isIdentCont(c) or c == '.';
}

// ── the streaming scanner → shingle → winnow pipeline ──

/// Feeds normalized tokens into the shingle ring and collects raw winnow-able
/// shingle hashes. Token identity is a 64-bit FNV-1a of the token's bytes
/// (class tokens hash their class letter); a shingle hashes its `gram` token
/// hashes in order.
const Shingler = struct {
    ring: [gram]u64 = @splat(0),
    n: usize = 0, // tokens seen
    grams: *std.ArrayList(u64),
    gpa: std.mem.Allocator,

    fn tokenHash(text: []const u8) u64 {
        var h: u64 = mix.fnv_offset;
        for (text) |b| h = (h ^ b) *% mix.fnv_prime;
        return h;
    }

    fn push(self: *Shingler, text: []const u8) !void {
        self.ring[self.n % gram] = tokenHash(text);
        self.n += 1;
        if (self.n < gram) return;
        // Hash the last `gram` token hashes oldest → newest.
        var h: u64 = mix.fnv_offset;
        var i: usize = self.n - gram;
        while (i < self.n) : (i += 1) {
            const w = self.ring[i % gram];
            inline for (0..8) |byte| h = (h ^ @as(u8, @truncate(w >> (8 * byte)))) *% mix.fnv_prime;
        }
        try self.grams.append(self.gpa, h);
    }
};

/// One generic scanner pass over `bytes`, emitting normalized tokens into
/// `sh`. No language dispatch — see the module header for the class rules.
fn scan(bytes: []const u8, sh: *Shingler) !void {
    var i: usize = 0;
    const n = bytes.len;
    while (i < n) {
        const c = bytes[i];
        // string literals (' " ` and triple quotes) → S
        if (c == '\'' or c == '"' or c == '`') {
            if (i + 3 <= n and bytes[i + 1] == c and bytes[i + 2] == c) {
                const q = bytes[i .. i + 3];
                const end = std.mem.indexOfPos(u8, bytes, i + 3, q);
                i = if (end) |e| e + 3 else n;
            } else {
                var j = i + 1;
                while (j < n and bytes[j] != c and bytes[j] != '\n') {
                    j += if (bytes[j] == '\\') 2 else 1;
                }
                i = @min(j + 1, n);
            }
            try sh.push("S");
            continue;
        }
        // comments → dropped (# and // to end of line, /* */ block)
        if (c == '#' or (c == '/' and i + 1 < n and bytes[i + 1] == '/')) {
            i = std.mem.indexOfScalarPos(u8, bytes, i, '\n') orelse n;
            continue;
        }
        if (c == '/' and i + 1 < n and bytes[i + 1] == '*') {
            const end = std.mem.indexOfPos(u8, bytes, i + 2, "*/");
            i = if (end) |e| e + 2 else n;
            continue;
        }
        // numbers → N
        if (c >= '0' and c <= '9') {
            var j = i;
            while (j < n and isNumCont(bytes[j])) j += 1;
            i = j;
            try sh.push("N");
            continue;
        }
        // identifier-shaped runs → I (keywords survive verbatim)
        if (isIdentStart(c)) {
            var j = i;
            while (j < n and isIdentCont(bytes[j])) j += 1;
            const word = bytes[i..j];
            i = j;
            try sh.push(if (keywords.has(word)) word else "I");
            continue;
        }
        // whitespace dropped; every other byte is a 1-byte punctuation token
        i += 1;
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') continue;
        try sh.push(bytes[i - 1 .. i]);
    }
}

/// Normalize `bytes`, shingle the token stream, winnow, and return the
/// bottom-k silhouette. `gpa` covers only the shingle/pick scratch, freed
/// before return. Deterministic — no pointers, no iteration-order dependence.
pub fn build(gpa: std.mem.Allocator, bytes: []const u8) !Silhouette {
    var grams: std.ArrayList(u64) = .empty;
    defer grams.deinit(gpa);
    var sh = Shingler{ .grams = &grams, .gpa = gpa };
    try scan(bytes, &sh);
    const gs = grams.items;
    if (gs.len == 0) return .empty;

    // Winnow: the minimum of every `window` consecutive shingle hashes (one
    // window over everything when fewer than `window` exist), deduplicated.
    var picks: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer picks.deinit(gpa);
    if (gs.len <= window) {
        try picks.put(gpa, std.mem.min(u64, gs), {});
    } else {
        var lo: usize = 0;
        while (lo + window <= gs.len) : (lo += 1) {
            try picks.put(gpa, std.mem.min(u64, gs[lo .. lo + window]), {});
        }
    }

    // Finalize (splitmix64 — bottom-k needs uniform keys) and keep the k
    // smallest, ascending. splitmix64 is a bijection, so the pre-finalize
    // dedupe loses nothing.
    var fps: std.ArrayList(u64) = .empty;
    defer fps.deinit(gpa);
    try fps.ensureTotalCapacityPrecise(gpa, picks.count());
    var it = picks.keyIterator();
    while (it.next()) |key| fps.appendAssumeCapacity(mix.finalize(key.*));
    std.mem.sort(u64, fps.items, {}, comptime std.sort.asc(u64));

    var out = Silhouette.empty;
    out.len = @intCast(@min(fps.items.len, k));
    @memcpy(out.h[0..out.len], fps.items[0..out.len]);
    return out;
}
