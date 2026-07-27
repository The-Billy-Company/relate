//! relate — graded aspect coverage, the submodular core of `pack`.
//!
//! Pure kernel: given a query decomposed into corpus-priced ASPECTS and a pool
//! of candidate documents graded on each of them, pick the SET that jointly
//! explains the most priced bits, every pick scored by the bits it adds BEYOND
//! the picks before it.
//!
//! **Why graded and not set-cover.** The first version of this kernel ran
//! max-coverage over binary sets: an aspect was covered iff a document
//! contained its literal. That objective is degenerate for the query lengths
//! agents actually type. A six-word query yields ~5 priced aspects after glue
//! is dropped, so the first document mentioning all six words covers every
//! element, reports 100% coverage, and the submodular machinery never engages
//! — there is no coverage problem left to solve. Worse, "mentions the word" is
//! not "explains the thing": a CHANGELOG that name-drops each term once beat
//! the module the query was about.
//!
//! Lin & Bilmes ("A Class of Submodular Functions for Document
//! Summarization", ACL 2011) make exactly this argument for summarization and
//! give the fix: replace the 0/1 cover with a facility-location objective over
//! a GRADED notion of how well a pick represents each element.
//!
//!     F(S) = Σ_a bits(a) · max_{d ∈ S} strength(d, a)
//!
//! `strength ∈ [0,1]` saturates rather than switching, so a document that
//! merely mentions an aspect leaves most of that aspect's bits on the table
//! for a later pick that is actually about it. F stays monotone submodular
//! (a weighted sum of maxima of non-negative terms), so the classic greedy
//! sweep (Nemhauser–Wolsey–Fisher 1978) is still within (1−1/e) of optimal and
//! the marginal of a pick can only shrink as the set grows. Coverage now
//! reaches 1.0 only when every aspect is maximally explained, which is the
//! honest reading of "these files jointly describe your query".
//!
//! **The strength function is BM25's, and only BM25's.** `strength` is the
//! saturating, length-normalized term frequency of Robertson & Spärck Jones
//! (1976) / Robertson & Walker (1994): tf/(tf+k) over a density normalized by
//! the pool's mean document length. Length normalization is what separates the
//! 10 KB module that says "freshness" fifteen times from the 60 KB changelog
//! that says it twice, and saturation is what stops a fixture farm repeating
//! one token from owning an aspect outright.
//!
//! **The pricing is Shannon's, unchanged.** An aspect is worth −log₂(df/N)
//! bits in this corpus: ubiquitous glue prices at ~0 and cannot rank anything,
//! an aspect no document holds is `foreign` and cannot be covered by anyone.
//! Both are reported rather than folded into the denominator, so `coverage` is
//! always a fraction of a total the corpus could actually pay.
//!
//! Kernel profile: explicit allocator, no I/O, deterministic (ties break
//! toward the lexicographically-smaller path). The verb driver loads bodies,
//! prices aspects, and renders.

const std = @import("std");

/// The aspect mask is one `u64` word, matching `compose/candidates.zig`'s
/// pattern cap. A query with more than 64 distinct terms is a document, not a
/// question, and its tail terms carry no information the head does not.
pub const max_aspects = 64;

/// BM25's saturation constant `k₁`, in density units. At `k = 2` a document of
/// average length mentioning an aspect once scores 0.33 ("mentions it"), five
/// times scores 0.71, and a half-length document mentioning it fifteen times
/// scores 0.94 ("is about it"). Tuned on this repo's corpus against hand-known
/// answers; see `bench/diag/` and the README's pack section.
pub const saturation = 2.0;

/// Why an aspect prices at zero — the two reasons are opposite and a caller
/// that conflates them reports a corpus gap as a boring word.
pub const Kind = enum {
    /// `0 < df < glue floor` — real information content, coverable.
    priced,
    /// Ubiquitous in this corpus. Prices at ~0 bits: it cannot discriminate,
    /// so covering it would be free and meaningless.
    glue,
    /// `df == 0`. Nothing in the corpus holds it, so nothing can cover it.
    foreign,
};

/// One priced dimension of the query.
pub const Aspect = struct {
    term: []const u8,
    /// Shannon self-information −log₂(df/N); exactly 0 for `glue`/`foreign`.
    bits: f64,
    /// Documents containing the term.
    df: usize,
    kind: Kind,
};

/// A candidate document, graded on every aspect. `strength[i] ∈ [0,1]` is how
/// strongly this document is ABOUT `aspects[i]`.
pub const Candidate = struct {
    doc: u32,
    strength: []const f64,
};

/// One greedy pick, in pick order.
pub const Pick = struct {
    doc: u32,
    /// Priced bits this pick added beyond every earlier pick.
    marginal_bits: f64,
    /// Cumulative priced bits after this pick.
    covered_bits: f64,
    /// Priced bits this document explains ALONE — its standalone relevance,
    /// kept separate from its marginal contribution so a strong third pick is
    /// not mistaken for a weak document.
    solo_bits: f64,
    /// The aspects that account for this pick's gain: bit `i` is set when
    /// aspect `i` supplied at least `attribution_share` of `marginal_bits`.
    /// This is the pick's justification, and it is why it is in the answer.
    owns: u64,
};

/// The share of a pick's gain an aspect must supply to be named as a reason
/// for it. Low enough that a genuine second reason shows, high enough that the
/// row does not list every term the file happens to contain.
pub const attribution_share = 0.15;

/// Greedy facility-location maximization of `F(S) = Σ bits(a)·max_{d∈S} s(d,a)`.
///
/// Stops at `limit` picks, or as soon as the best remaining document adds less
/// than `min_gain_bits` — a pick that explains nothing new is noise in a
/// reading set, not a longer answer. Deterministic: equal gains break toward
/// the lexicographically-smaller path.
///
/// O(limit · |candidates| · |aspects|), no allocation per iteration beyond the
/// working copy. Caller frees the returned slice.
pub fn greedy(
    gpa: std.mem.Allocator,
    aspects: []const Aspect,
    candidates: []const Candidate,
    paths: []const []const u8,
    limit: usize,
    min_gain_bits: f64,
) ![]Pick {
    std.debug.assert(aspects.len <= max_aspects);

    const covered = try gpa.alloc(f64, aspects.len);
    defer gpa.free(covered);
    @memset(covered, 0.0);

    // A working copy so a taken candidate can be swap-removed without
    // mutating the caller's pool.
    const remaining_storage = try gpa.dupe(Candidate, candidates);
    defer gpa.free(remaining_storage);
    var remaining = remaining_storage;

    var picks: std.ArrayList(Pick) = .empty;
    errdefer picks.deinit(gpa);
    var covered_bits: f64 = 0.0;

    while (picks.items.len < limit and remaining.len > 0) {
        var best: usize = 0;
        var best_gain: f64 = 0.0;
        for (remaining, 0..) |candidate, i| {
            const gain = marginalOf(aspects, covered, candidate.strength);
            if (gain > best_gain or (gain == best_gain and gain > 0.0 and
                std.mem.order(u8, paths[candidate.doc], paths[remaining[best].doc]) == .lt))
            {
                best = i;
                best_gain = gain;
            }
        }
        if (best_gain < min_gain_bits or best_gain <= 0.0) break;

        const chosen = remaining[best];
        var owns: u64 = 0;
        var solo: f64 = 0.0;
        for (aspects, 0..) |aspect, a| {
            const s = chosen.strength[a];
            solo += aspect.bits * s;
            if (s > covered[a]) {
                if (aspect.bits * (s - covered[a]) >= attribution_share * best_gain)
                    owns |= @as(u64, 1) << @intCast(a);
                covered[a] = s;
            }
        }
        covered_bits += best_gain;
        try picks.append(gpa, .{
            .doc = chosen.doc,
            .marginal_bits = best_gain,
            .covered_bits = covered_bits,
            .solo_bits = solo,
            .owns = owns,
        });
        remaining[best] = remaining[remaining.len - 1];
        remaining = remaining[0 .. remaining.len - 1];
    }
    return picks.toOwnedSlice(gpa);
}

fn marginalOf(aspects: []const Aspect, covered: []const f64, grades: []const f64) f64 {
    var gain: f64 = 0.0;
    for (aspects, covered, grades) |aspect, held, s|
        if (s > held) {
            gain += aspect.bits * (s - held);
        };
    return gain;
}

/// The priced total: what a perfect answer would cover. `glue` and `foreign`
/// aspects contribute nothing, so `covered_bits / total` is a fraction of what
/// this corpus could actually pay.
pub fn pricedBits(aspects: []const Aspect) f64 {
    var total: f64 = 0.0;
    for (aspects) |aspect| total += aspect.bits;
    return total;
}

// ── decomposition ─────────────────────────────────────────────────────────

/// The shortest term worth pricing. Below three bytes a token is a fragment of
/// syntax, and the trigram index cannot answer it either.
pub const min_term = 3;

/// Split a query into the aspects a corpus can price: the whole phrase first
/// (exact phrasing is the strongest evidence when a document really carries it),
/// then each distinct word. Borrows `query`; caller frees the slice only.
///
/// One decomposition for every rung — warm, live, and narrowed — because
/// "the query's aspects" has to mean the same thing whichever lane answered,
/// or a `--json` consumer cannot compare two runs of the same question.
pub fn decompose(gpa: std.mem.Allocator, query: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);
    if (query.len >= min_term) try out.append(gpa, query);
    var it = std.mem.tokenizeAny(u8, query, " \t\r\n.,;:!?()[]{}<>/\\|\"'`~@#$%^&*+=-");
    while (it.next()) |term| {
        if (term.len < min_term or out.items.len >= max_aspects) continue;
        var duplicate = false;
        for (out.items) |seen| duplicate = duplicate or std.ascii.eqlIgnoreCase(seen, term);
        if (!duplicate) try out.append(gpa, term);
    }
    return out.toOwnedSlice(gpa);
}

// ── pricing and grading ───────────────────────────────────────────────────

/// Shannon self-information of a term appearing in `df` of `n` documents.
pub fn bitsOf(df: usize, n: usize) f64 {
    if (df == 0 or n == 0) return 0.0;
    return -std.math.log2(@as(f64, @floatFromInt(df)) / @as(f64, @floatFromInt(n)));
}

/// The document-frequency share above which a term is `glue`. A term in more
/// than one document in twenty prices under 4.33 bits here and is far more
/// likely to be house vocabulary ("index", "session") than a query's subject.
pub const glue_share = 20;

/// The absolute presence a term needs before `glue_share` may retire it. A
/// share alone is wrong on a small population: inside a twelve-file
/// `--matching` set, a term in one file is 8% of the corpus AND the most
/// discriminating thing in it. Below this floor, share carries no evidence.
pub const min_glue_docs = 8;

/// Classify an aspect from its document frequency. A single-term query is
/// never glue: the caller asked about that one word, and refusing to price it
/// would answer nothing at all.
pub fn kindOf(df: usize, n: usize, terms: usize) Kind {
    if (df == 0) return .foreign;
    if (terms > 1 and df >= min_glue_docs and df * glue_share > n) return .glue;
    return .priced;
}

/// How strongly a document of `doc_len` bytes containing `hits` occurrences of
/// a term is ABOUT that term: BM25's saturating length-normalized tf, in
/// `[0,1)`. `mean_len` is the pool's mean document length, so "dense" means
/// dense relative to the documents this query actually surfaced.
pub fn strength(hits: usize, doc_len: usize, mean_len: f64) f64 {
    if (hits == 0 or doc_len == 0 or mean_len <= 0.0) return 0.0;
    const density = @as(f64, @floatFromInt(hits)) * mean_len / @as(f64, @floatFromInt(doc_len));
    return density / (density + saturation);
}

/// Non-overlapping, ASCII-case-insensitive occurrences of `needle` in
/// `haystack`. Case folding is deliberate and one-sided: the posting lane that
/// nominates candidates is exact, but once a document is in hand, `Freshness`
/// in a doc comment is the same evidence as `freshness` in an identifier, and
/// counting only one of them mis-grades the file that is most about the term.
pub fn occurrences(haystack: []const u8, needle: []const u8) usize {
    if (needle.len == 0 or haystack.len < needle.len) return 0;
    var count: usize = 0;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) {
            count += 1;
            i += needle.len;
        } else i += 1;
    }
    return count;
}

/// Grade one body against a priced aspect table, writing `aspects.len`
/// strengths into `out`. Zero for `glue`/`foreign`: an aspect worth no bits
/// cannot be covered, so measuring it would only cost a scan.
pub fn gradeBody(out: []f64, aspects: []const Aspect, body: []const u8, mean_len: f64) void {
    for (aspects, out) |aspect, *s|
        s.* = if (aspect.kind == .priced)
            strength(occurrences(body, aspect.term), body.len, mean_len)
        else
            0.0;
}

/// A priced aspect table plus every body's grades — the whole measurement, for
/// the rungs that hold every candidate's bytes (the live corpus scan and the
/// `--matching` narrowed set). One pass yields both `df` and `tf`, so these
/// rungs never build a fingerprint lexicon they would only use for pricing.
///
/// Borrows `terms`; owns everything else. Caller calls `deinit`.
pub const Table = struct {
    gpa: std.mem.Allocator,
    aspects: []Aspect,
    candidates: []Candidate,
    /// Row-major `bodies.len × aspects.len` backing store for the grades.
    grades: []f64,

    pub fn deinit(self: *Table) void {
        self.gpa.free(self.aspects);
        self.gpa.free(self.candidates);
        self.gpa.free(self.grades);
    }

    pub fn count(self: *const Table, kind: Kind) usize {
        var n: usize = 0;
        for (self.aspects) |aspect| n += @intFromBool(aspect.kind == kind);
        return n;
    }
};

/// Price `terms` against `bodies` and grade every body, in two passes over the
/// pool: occurrences first (which yields both `df` and `tf`), then the
/// saturating normalization once the mean length is known.
pub fn measure(gpa: std.mem.Allocator, terms: []const []const u8, bodies: []const []const u8) !Table {
    const n = @min(terms.len, max_aspects);
    const aspects = try gpa.alloc(Aspect, n);
    errdefer gpa.free(aspects);
    const grades = try gpa.alloc(f64, bodies.len * n);
    errdefer gpa.free(grades);
    const candidates = try gpa.alloc(Candidate, bodies.len);
    errdefer gpa.free(candidates);

    var total_len: u64 = 0;
    for (bodies) |body| total_len += body.len;
    const mean_len = if (bodies.len == 0) 0.0 else @as(f64, @floatFromInt(total_len)) / @as(f64, @floatFromInt(bodies.len));

    // Pass one: raw occurrences, parked in the grade store, and the document
    // frequency they imply.
    for (bodies, 0..) |body, d| {
        for (terms[0..n], 0..) |term, a| {
            const hits = occurrences(body, term);
            grades[d * n + a] = @floatFromInt(hits);
        }
    }
    for (terms[0..n], 0..) |term, a| {
        var df: usize = 0;
        for (0..bodies.len) |d| df += @intFromBool(grades[d * n + a] > 0.0);
        const kind = kindOf(df, bodies.len, n);
        aspects[a] = .{
            .term = term,
            .bits = if (kind == .priced) bitsOf(df, bodies.len) else 0.0,
            .df = df,
            .kind = kind,
        };
    }

    // Pass two: normalize in place, now that the mean is known.
    for (bodies, 0..) |body, d| {
        const row = grades[d * n ..][0..n];
        for (aspects, row) |aspect, *s|
            s.* = if (aspect.kind == .priced) strength(@intFromFloat(s.*), body.len, mean_len) else 0.0;
        candidates[d] = .{ .doc = @intCast(d), .strength = row };
    }
    return .{ .gpa = gpa, .aspects = aspects, .candidates = candidates, .grades = grades };
}

// ── tests ──────────────────────────────────────────────────────────────────

const t = std.testing;

test "strength separates a document that is about a term from one that mentions it" {
    // The measured shape of the defect: a 60 KB changelog naming the term
    // twice must not grade like a 6 KB module built around it.
    const changelog = strength(2, 60 << 10, 12 << 10);
    const module = strength(15, 6 << 10, 12 << 10);
    try t.expect(module > 0.9);
    try t.expect(changelog < 0.25);
    // Saturating, so a fixture repeating one token cannot exceed 1.
    try t.expect(strength(10_000, 1 << 10, 12 << 10) < 1.0);
    try t.expectEqual(@as(f64, 0.0), strength(0, 1 << 10, 12 << 10));
    // The three calibration points `saturation` documents, pinned exactly so a
    // change to k₁ has to come here and restate what "mentions it" means
    // rather than quietly re-grading every pack. Derived from tf/(tf+k) at
    // k = 2, not from a run: 1/3, 5/7, and 30/32.
    try t.expectApproxEqAbs(@as(f64, 1.0 / 3.0), strength(1, 12 << 10, 12 << 10), 1e-9);
    try t.expectApproxEqAbs(@as(f64, 5.0 / 7.0), strength(5, 12 << 10, 12 << 10), 1e-9);
    try t.expectApproxEqAbs(@as(f64, 0.9375), module, 1e-9);
}

test "decompose keeps the whole phrase, then its distinct words" {
    const gpa = t.allocator;
    const short = try decompose(gpa, "dog");
    defer gpa.free(short);
    try t.expectEqual(@as(usize, 1), short.len);
    try t.expectEqualStrings("dog", short[0]);

    const phrase = try decompose(gpa, "resident session freshness");
    defer gpa.free(phrase);
    try t.expectEqual(@as(usize, 4), phrase.len);
    try t.expectEqualStrings("resident session freshness", phrase[0]);
    try t.expectEqualStrings("resident", phrase[1]);

    // A repeated word is one aspect, whatever its case: pricing it twice would
    // double its weight in the coverage total for free.
    const repeat = try decompose(gpa, "cache the Cache cache");
    defer gpa.free(repeat);
    try t.expectEqual(@as(usize, 3), repeat.len); // phrase + "cache" + "the"
}

test "occurrences counts non-overlapping runs and folds ASCII case" {
    try t.expectEqual(@as(usize, 3), occurrences("fresh Fresh FRESH", "fresh"));
    try t.expectEqual(@as(usize, 2), occurrences("aaaa", "aa"));
    try t.expectEqual(@as(usize, 0), occurrences("short", "longer needle"));
    try t.expectEqual(@as(usize, 0), occurrences("anything", ""));
}

test "pricing separates glue from foreign, and never prices a single-term query as glue" {
    try t.expectEqual(Kind.foreign, kindOf(0, 100, 4));
    try t.expectEqual(Kind.glue, kindOf(40, 100, 4));
    try t.expectEqual(Kind.priced, kindOf(2, 100, 4));
    // A one-word query is the caller's whole question; refusing to price it
    // would answer nothing at all.
    try t.expectEqual(Kind.priced, kindOf(40, 100, 1));
    // Share alone would retire the most discriminating term in a small
    // `--matching` population: one file out of twelve is 8% AND unique.
    try t.expectEqual(Kind.priced, kindOf(1, 12, 4));
    try t.expectEqual(Kind.glue, kindOf(10, 12, 4));
    try t.expectApproxEqAbs(@as(f64, 1.0), bitsOf(50, 100), 1e-9);
    try t.expectEqual(@as(f64, 0.0), bitsOf(0, 100));
}

test "graded coverage does not saturate on the first pick — the reported defect" {
    const gpa = t.allocator;
    // One document mentions every term once in a lot of bytes (the changelog);
    // two others are each dense in one term (the modules).
    const filler = "x" ** 4000;
    const changelog = "freshness anchor" ++ filler;
    const fresh = "freshness freshness freshness freshness freshness" ++ ("y" ** 400);
    const anchor = "anchor anchor anchor anchor anchor" ++ ("z" ** 400);
    const bodies = [_][]const u8{ changelog, fresh, anchor };
    const paths = [_][]const u8{ "CHANGELOG.md", "fresh.zig", "anchor.zig" };

    var table = try measure(gpa, &.{ "freshness", "anchor" }, &bodies);
    defer table.deinit();

    const picks = try greedy(gpa, table.aspects, table.candidates, &paths, 4, 0.0);
    defer gpa.free(picks);

    // Under binary max-coverage the changelog alone reported 100%. Graded, it
    // leaves most of both aspects on the table for the modules that own them.
    try t.expect(picks.len >= 2);
    // The changelog is the defect this test exists for: it mentions both terms
    // and must own neither, so the modules take the first two picks. WHICH of
    // them leads is not a contract — they are near-tied (0.901 vs 0.904, the
    // gap coming only from "anchor" being a shorter word than "freshness", so
    // its fixture is denser), and pinning an order would pin a coin flip.
    try t.expect(picks[0].doc != 0 and picks[1].doc != 0);
    try t.expect(picks[0].doc != picks[1].doc);
    // Each pick names the one aspect it is there for, whichever order they
    // came in: doc 1 is the freshness module, doc 2 the anchor module.
    for (picks[0..2]) |p| {
        try t.expectEqual(@as(u64, if (p.doc == 1) 0b01 else 0b10), p.owns);
    }
    const total = pricedBits(table.aspects);
    try t.expect(picks[0].covered_bits / total < 0.75);
}

test "marginals shrink pick over pick and never double-count a covered aspect" {
    const gpa = t.allocator;
    const aspects = [_]Aspect{
        .{ .term = "a", .bits = 4.0, .df = 1, .kind = .priced },
        .{ .term = "b", .bits = 6.0, .df = 1, .kind = .priced },
    };
    const strong_a = [_]f64{ 0.9, 0.1 };
    const strong_b = [_]f64{ 0.1, 0.9 };
    const weaker_a = [_]f64{ 0.5, 0.0 };
    const candidates = [_]Candidate{
        .{ .doc = 0, .strength = &strong_a },
        .{ .doc = 1, .strength = &strong_b },
        .{ .doc = 2, .strength = &weaker_a },
    };
    const paths = [_][]const u8{ "a.zig", "b.zig", "c.zig" };

    const picks = try greedy(gpa, &aspects, &candidates, &paths, 8, 0.0);
    defer gpa.free(picks);

    // b first (0.9·6 + 0.1·4 = 5.8 beats 0.9·4 + 0.1·6 = 4.2); then a, paying
    // only for what b left uncovered. c is strictly dominated and never picked.
    try t.expectEqual(@as(usize, 2), picks.len);
    try t.expectEqual(@as(u32, 1), picks[0].doc);
    try t.expectEqual(@as(u32, 0), picks[1].doc);
    try t.expect(picks[1].marginal_bits < picks[0].marginal_bits);
    try t.expectApproxEqAbs(@as(f64, 0.8 * 4.0), picks[1].marginal_bits, 1e-9);
    try t.expectApproxEqAbs(picks[0].marginal_bits + picks[1].marginal_bits, picks[1].covered_bits, 1e-9);
    // solo is standalone relevance, unaffected by pick order.
    try t.expectApproxEqAbs(@as(f64, 0.9 * 4.0 + 0.1 * 6.0), picks[1].solo_bits, 1e-9);
}

test "a pick that explains nothing new is not a longer answer" {
    const gpa = t.allocator;
    const aspects = [_]Aspect{.{ .term = "a", .bits = 4.0, .df = 1, .kind = .priced }};
    const full = [_]f64{0.9};
    const trace = [_]f64{0.91};
    const candidates = [_]Candidate{
        .{ .doc = 0, .strength = &full },
        .{ .doc = 1, .strength = &trace },
    };
    const paths = [_][]const u8{ "a.zig", "b.zig" };

    // doc 1 is marginally stronger, so it goes first; doc 0 then adds nothing
    // and the floor keeps it out rather than padding the set to `--top`.
    const picks = try greedy(gpa, &aspects, &candidates, &paths, 8, 0.25);
    defer gpa.free(picks);
    try t.expectEqual(@as(usize, 1), picks.len);
    try t.expectEqual(@as(u32, 1), picks[0].doc);
}

test "an all-foreign query packs nothing and prices nothing" {
    const gpa = t.allocator;
    const bodies = [_][]const u8{ "alpha beta gamma", "delta epsilon zeta" };
    const paths = [_][]const u8{ "a.txt", "b.txt" };
    var table = try measure(gpa, &.{ "purplemonkey", "dishwasher" }, &bodies);
    defer table.deinit();

    try t.expectEqual(@as(usize, 2), table.count(.foreign));
    try t.expectEqual(@as(f64, 0.0), pricedBits(table.aspects));
    const picks = try greedy(gpa, table.aspects, table.candidates, &paths, 8, 0.0);
    defer gpa.free(picks);
    try t.expectEqual(@as(usize, 0), picks.len);
}

test "equal gains break toward the lexicographically-smaller path" {
    const gpa = t.allocator;
    const aspects = [_]Aspect{.{ .term = "a", .bits = 4.0, .df = 1, .kind = .priced }};
    const same = [_]f64{0.5};
    const candidates = [_]Candidate{
        .{ .doc = 0, .strength = &same },
        .{ .doc = 1, .strength = &same },
    };
    const paths = [_][]const u8{ "z.zig", "a.zig" };
    const picks = try greedy(gpa, &aspects, &candidates, &paths, 1, 0.0);
    defer gpa.free(picks);
    try t.expectEqual(@as(u32, 1), picks[0].doc);
}
