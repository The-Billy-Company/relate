//! relate — the zipper: an exact cross-parse, hand-rolled.
//!
//! The precision half of compression-as-search. Benedetto, Caglioti & Loreto
//! ("Language Trees and Zipping", 2001) measure how close b is to A by how
//! few bits a ziplike coder spends writing b with A's window warm — but they
//! approximate it by literally running gzip. This module computes the same
//! quantity EXACTLY, with no compressor run and no entropy coder, because
//! ranking only ever needs code LENGTHS, never encoded bytes:
//!
//!   Build a suffix automaton over the doc — the minimal DFA of all of its
//!   substrings (Blumer et al. 1985; ≤ 2n states, online O(n) build). It is
//!   the match-finder an ideal LZ77 wishes it had: from the root, one walk
//!   answers "what is the longest prefix of this text that occurs ANYWHERE
//!   in the doc?" in O(1) amortized per byte.
//!
//!   crossParse(q) then greedily factors q into longest doc-substrings —
//!   the Ziv–Merhav cross-parsing (1993), whose factor count estimates the
//!   cross-entropy between the processes that produced q and the doc. Each
//!   factor is priced as a real copy op (flag + position + length); a byte
//!   the doc has never seen is a real literal (flag + 8 bits). Familiar
//!   text is swallowed in long cheap factors; alien text pays 9 bits/byte.
//!
//! No LZ78 phrases, no parse-order boundaries, no minhash estimate — the
//! factorization is over ALL substrings of the doc, so a shared fragment
//! scores wherever it sits. This is the module the borrowed-algorithm draft
//! could not become: its LZ78 dictionary saw only parse-aligned phrases and
//! lost short queries to boundary noise (measured; see lexicon_test.zig).
//!
//! Kernel profile: explicit allocator, no I/O, deterministic; a built
//! `Automaton` is immutable and thread-safe to walk.

const std = @import("std");

/// Minimum copy-factor length. Any two ASCII texts share almost every 1–3
/// byte string, so admitting them as factors lets EVERYTHING "compress"
/// against everything — the discrimination collapses. Real coders make the
/// same call for the same reason (deflate MIN_MATCH = 3, zstd = 3); ours is
/// 4 because we rank by margin, not decode. Shorter matches are literals.
pub const min_factor = 4;

/// Description length of `n` as an Elias-gamma-shaped code: 2·log2(n+1)+1
/// bits. Used for factor lengths (short factors are cheap to say, long ones
/// still sublinear) — a real, decodable cost, not a tuning knob.
inline fn gammaBits(n: usize) f64 {
    return 2.0 * std.math.log2(@as(f64, @floatFromInt(n + 1))) + 1.0;
}

/// The result of a cross-parse.
pub const Cost = struct {
    /// Total description length of the query, in bits, under this code.
    bits: f64,
    /// Copy factors emitted (fewer = longer shared runs = closer).
    factors: u32,
    /// Literal bytes emitted (bytes the doc has never seen, anywhere).
    literals: u32,
};

/// coldBits: the description length of `query` with NOTHING warm — every
/// byte a literal (1-bit flag + 8-bit byte). The ΔEb baseline every
/// conditional parse is measured against; any sharing at all beats it.
pub fn coldBits(query: []const u8) f64 {
    return 9.0 * @as(f64, @floatFromInt(query.len));
}

/// The minimal automaton of every substring of one doc. Edges live in one
/// flat arena (head[state] → linked adjacency), so construction does O(1)
/// allocator calls per growth instead of per state, and clones copy an
/// adjacency by walking it — no per-state hash maps.
pub const Automaton = struct {
    /// longest substring length represented by this state
    len: []u32,
    /// suffix link
    link: []i32,
    /// head[state] → first edge index in `edges`, -1 = none
    head: []i32,
    edges: std.ArrayList(Edge),
    n_states: u32,
    /// bytes of the source doc (for pointer cost: log2(doc len))
    doc_len: usize,
    gpa: std.mem.Allocator,

    const Edge = struct { byte: u8, to: u32, next: i32 };

    /// Build over `bytes`. O(n) states/edges, deterministic.
    pub fn build(gpa: std.mem.Allocator, bytes: []const u8) !Automaton {
        const max_states = 2 * @max(bytes.len, 1) + 2;
        var self: Automaton = .{
            .len = try gpa.alloc(u32, max_states),
            .link = try gpa.alloc(i32, max_states),
            .head = try gpa.alloc(i32, max_states),
            .edges = .empty,
            .n_states = 1,
            .doc_len = bytes.len,
            .gpa = gpa,
        };
        errdefer self.deinit();
        self.len[0] = 0;
        self.link[0] = -1;
        self.head[0] = -1;

        var last: u32 = 0;
        for (bytes) |c| last = try self.extend(last, c);
        return self;
    }

    pub fn deinit(self: *Automaton) void {
        self.gpa.free(self.len);
        self.gpa.free(self.link);
        self.gpa.free(self.head);
        self.edges.deinit(self.gpa);
    }

    fn newState(self: *Automaton) u32 {
        const s = self.n_states;
        self.n_states += 1;
        self.head[s] = -1;
        return s;
    }

    fn transition(self: *const Automaton, s: u32, c: u8) ?u32 {
        var e = self.head[s];
        while (e >= 0) {
            const edge = self.edges.items[@intCast(e)];
            if (edge.byte == c) return edge.to;
            e = edge.next;
        }
        return null;
    }

    fn setTransition(self: *Automaton, s: u32, c: u8, to: u32) !void {
        var e = self.head[s];
        while (e >= 0) {
            const edge = &self.edges.items[@intCast(e)];
            if (edge.byte == c) {
                edge.to = to;
                return;
            }
            e = edge.next;
        }
        try self.edges.append(self.gpa, .{ .byte = c, .to = to, .next = self.head[s] });
        self.head[s] = @intCast(self.edges.items.len - 1);
    }

    /// Classic online suffix-automaton extension (Blumer et al.).
    fn extend(self: *Automaton, last: u32, c: u8) !u32 {
        const cur = self.newState();
        self.len[cur] = self.len[last] + 1;
        self.link[cur] = 0;

        var p: i32 = @intCast(last);
        while (p >= 0 and self.transition(@intCast(p), c) == null) {
            try self.setTransition(@intCast(p), c, cur);
            p = self.link[@intCast(p)];
        }
        if (p >= 0) {
            const q = self.transition(@intCast(p), c).?;
            if (self.len[@intCast(p)] + 1 == self.len[q]) {
                self.link[cur] = @intCast(q);
            } else {
                const clone = self.newState();
                self.len[clone] = self.len[@intCast(p)] + 1;
                self.link[clone] = self.link[q];
                // copy q's adjacency
                var e = self.head[q];
                while (e >= 0) {
                    const edge = self.edges.items[@intCast(e)];
                    try self.setTransition(clone, edge.byte, edge.to);
                    e = edge.next;
                }
                while (p >= 0 and self.transition(@intCast(p), c) == @as(?u32, q)) {
                    try self.setTransition(@intCast(p), c, clone);
                    p = self.link[@intCast(p)];
                }
                self.link[q] = @intCast(clone);
                self.link[cur] = @intCast(clone);
            }
        }
        return cur;
    }

    /// Is `needle` a substring of the doc? (test/diagnostic surface)
    pub fn contains(self: *const Automaton, needle: []const u8) bool {
        var s: u32 = 0;
        for (needle) |c| s = self.transition(s, c) orelse return false;
        return true;
    }

    /// Ziv–Merhav (1993) greedy cross-parse: longest doc-substrings of `query`,
    /// priced as copy ops; unseen bytes as literals. Deterministic, O(|q|).
    pub fn crossParse(self: *const Automaton, query: []const u8) Cost {
        const pos_bits = std.math.log2(@as(f64, @floatFromInt(self.doc_len + 1)));
        // A whole short query is evidence, not ambient 1–3 byte overlap.
        // Longer queries retain `min_factor`, so incidental trigrams cannot
        // make unrelated prose look compressible.
        const factor_floor = @min(min_factor, query.len);
        var bits: f64 = 0.0;
        var factors: u32 = 0;
        var literals: u32 = 0;

        var i: usize = 0;
        while (i < query.len) {
            var s: u32 = 0;
            var l: usize = 0;
            while (i + l < query.len) {
                s = self.transition(s, query[i + l]) orelse break;
                l += 1;
            }
            if (l < factor_floor) {
                bits += 1.0 + 8.0; // flag + literal byte
                literals += 1;
                i += 1;
            } else {
                bits += 1.0 + pos_bits + gammaBits(l); // flag + position + length
                factors += 1;
                i += l;
            }
        }
        return .{ .bits = bits, .factors = factors, .literals = literals };
    }
};

test "automaton recognizes exactly the substrings" {
    const gpa = std.testing.allocator;
    var a = try Automaton.build(gpa, "abcbc");
    defer a.deinit();
    for ([_][]const u8{ "a", "abc", "bcbc", "cb", "abcbc", "" }) |s|
        try std.testing.expect(a.contains(s));
    for ([_][]const u8{ "ac", "cc", "abcbcb", "d" }) |s|
        try std.testing.expect(!a.contains(s));
}

test "cross-parse: familiar text is factors, alien text is literals" {
    const gpa = std.testing.allocator;
    var a = try Automaton.build(gpa, "the quick brown fox jumps over the lazy dog");
    defer a.deinit();

    const verbatim = a.crossParse("quick brown fox");
    try std.testing.expectEqual(@as(u32, 1), verbatim.factors);
    try std.testing.expectEqual(@as(u32, 0), verbatim.literals);
    try std.testing.expect(verbatim.bits < coldBits("quick brown fox") / 4.0);

    const alien = a.crossParse("ZZZZ");
    try std.testing.expectEqual(@as(u32, 0), alien.factors);
    try std.testing.expectEqual(@as(u32, 4), alien.literals);
    try std.testing.expectEqual(coldBits("ZZZZ"), alien.bits);
}

test "cross-parse treats a whole short query as evidence" {
    const gpa = std.testing.allocator;
    var a = try Automaton.build(gpa, "the lazy dog sleeps");
    defer a.deinit();

    const exact = a.crossParse("dog");
    try std.testing.expectEqual(@as(u32, 1), exact.factors);
    try std.testing.expectEqual(@as(u32, 0), exact.literals);
    try std.testing.expect(exact.bits < coldBits("dog"));
}
