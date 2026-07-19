//! cento — the corpus-quotation parse (Ziv–Merhav cross-parse on a codex).
//!
//! A cento is a text composed entirely of quotations from other works. This
//! module rewrites a query as exactly that: a greedy parse into maximal
//! phrases, each a verbatim substring of the indexed corpus, priced in bits.
//! Ziv & Merhav (IEEE-IT 1993) proved the phrase count of such a cross-parse
//! estimates the relative entropy rate between the query's and the corpus's
//! sources — so the total price is a principled, corpus-global relatedness
//! measure: the fewer bits it takes to quote Q out of C, the more C already
//! knows Q. This is hydra's zipper (per-document ΔAb) lifted to the whole
//! corpus in one pass, with no per-candidate automaton.
//!
//! Mechanics: FM backward search extends a phrase by PREPENDING a byte in
//! O(code length) rank steps, so the greedy parse scans the query right-to-
//! left, growing each phrase leftward until extension fails. Ziv–Merhav's
//! asymptotics are direction-agnostic (any greedy maximal parse rule serves);
//! the direction here simply follows the search primitive. Each query byte is
//! consumed by exactly one successful extension and each phrase costs at most
//! one failed probe, so a full parse is O(m) extend calls — corpus size never
//! appears.
//!
//! Pricing is an explicit code construction, not a vibe: a matched phrase of
//! length ℓ whose interval holds w of the corpus's n suffix rows costs
//! log₂(n/w) bits to name the interval (any row inside identifies the phrase;
//! w-wide intervals are exactly the ℓ-th-order empirical probability mass
//! w/n) plus 2·log₂(ℓ+1)+1 bits of Elias-γ-shaped length header. A byte the
//! corpus has never seen escapes as a literal: 8 bits plus the same header.
//! Σ over phrases is `Parse.bits` — the number of bits a decoder holding only
//! the codex needs to reproduce the query exactly.

const std = @import("std");
const codexmod = @import("codex.zig");

const Codex = codexmod.Codex;

/// One phrase of the parse: `query[pos .. pos+len)`. `width` is the phrase's
/// suffix-interval width in the corpus (its occurrence count); `width == 0`
/// marks a literal escape — a single byte the corpus does not contain. `row`
/// is the interval's first suffix row — feed it to `Codex.posOf` to locate
/// one exemplar occurrence (meaningless when `width == 0`).
pub const Phrase = struct {
    pos: u32,
    len: u32,
    width: u32,
    row: u32 = 0,

    /// The phrase's price in bits under the quotation code over a corpus
    /// with `n` suffix rows.
    pub fn bits(self: Phrase, n: usize) f64 {
        const header = 2.0 * @log2(@as(f64, @floatFromInt(self.len)) + 1.0) + 1.0;
        if (self.width == 0) return 8.0 + header;
        return @log2(@as(f64, @floatFromInt(n)) / @as(f64, @floatFromInt(self.width))) + header;
    }
};

/// Allocation-free iterator over the greedy parse, last phrase first (the
/// scan direction of backward search). Sum of `len` over all phrases is
/// exactly `query.len`.
pub const Phrases = struct {
    cx: *const Codex,
    query: []const u8,
    end: usize, // exclusive end of the next (leftward) phrase

    pub fn init(cx: *const Codex, query: []const u8) Phrases {
        return .{ .cx = cx, .query = query, .end = query.len };
    }

    pub fn next(self: *Phrases) ?Phrase {
        if (self.end == 0) return null;
        var span = self.cx.whole();
        var start = self.end;
        while (start > 0) {
            const grown = self.cx.extend(span, self.query[start - 1]);
            if (grown.width() == 0) break;
            span = grown;
            start -= 1;
        }
        if (start == self.end) { // first byte unseen by the corpus: literal escape
            self.end -= 1;
            return .{ .pos = @intCast(self.end), .len = 1, .width = 0 };
        }
        defer self.end = start;
        return .{ .pos = @intCast(start), .len = @intCast(self.end - start), .width = @intCast(span.width()), .row = @intCast(span.lo) };
    }
};

/// A materialized parse. `phrases` are in query order (position ascending).
pub const Parse = struct {
    phrases: []Phrase,
    bits: f64,

    pub fn deinit(self: *Parse, gpa: std.mem.Allocator) void {
        gpa.free(self.phrases);
    }

    /// Bits per query byte — the corpus-conditional compression rate.
    pub fn bitsPerByte(self: *const Parse, query_len: usize) f64 {
        return self.bits / @as(f64, @floatFromInt(@max(query_len, 1)));
    }
};

/// Materialize the full parse of `query` against the codex. Caller frees.
pub fn parse(cx: *const Codex, gpa: std.mem.Allocator, query: []const u8) !Parse {
    var list: std.ArrayList(Phrase) = .empty;
    errdefer list.deinit(gpa);
    var total: f64 = 0;
    var it = Phrases.init(cx, query);
    while (it.next()) |ph| {
        total += ph.bits(cx.n);
        try list.append(gpa, ph);
    }
    std.mem.reverse(Phrase, list.items); // iterator yields right-to-left
    return .{ .phrases = try list.toOwnedSlice(gpa), .bits = total };
}

/// Price of quoting `query` out of the corpus, in bits — the streaming,
/// allocation-free scoring path for relate workloads. Identical to
/// `parse(...).bits`.
pub fn price(cx: *const Codex, query: []const u8) f64 {
    var total: f64 = 0;
    var it = Phrases.init(cx, query);
    while (it.next()) |ph| total += ph.bits(cx.n);
    return total;
}
