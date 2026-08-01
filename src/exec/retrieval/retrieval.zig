//! Persisted candidate retrieval — the engine under a text probe (`relate
//! similar <text>`) and `relate pack`.
//!
//! The exact Ziv–Merhav decider is intentionally per-document; rebuilding its
//! recall lexicon over every corpus byte before each query is not. This module
//! nominates a bounded pool from Gist's mmap-backed trigram postings, folds in
//! changed files through the shared T3 freshness overlay, then reads only that
//! pool for exact suffix-automaton pricing. Missing, incompatible, or corrupt
//! state returns `null`, so the caller can use the live lexicon oracle.

const std = @import("std");
const scope = @import("irregex").commands.scope.filter;
const corpus = @import("irregex").corpus;
const fresh = @import("irregex").fresh;
const persist = @import("irregex").persist;
const coverage = @import("../../kernel/kinship/recall/coverage.zig");
const zipper = @import("../../kernel/kinship/recall/zipper.zig");

const Dir = std.Io.Dir;

pub const Hit = struct {
    path: []u8,
    evidence_bits: f64,
    cost: zipper.Cost,
};

pub const Result = struct {
    hits: []Hit,
    indexed_files: usize,
    candidates: usize,
    refreshed: usize,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *Result) void {
        for (self.hits) |h| self.gpa.free(h.path);
        self.gpa.free(self.hits);
    }
};

pub const PackPick = struct {
    path: []u8,
    marginal_bits: f64,
    covered_bits: f64,
    solo_bits: f64,
    owns: u64,
};

pub const PackResult = struct {
    picks: []PackPick,
    /// The priced aspect table the picks were scored against — borrowed term
    /// slices into the caller's query, so the renderer can name what each pick
    /// is there for without re-tokenizing.
    aspects: []coverage.Aspect,
    total_bits: f64,
    foreign: usize,
    glue: usize,
    indexed_files: usize,
    candidates: usize,
    pool: usize,
    refreshed: usize,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *PackResult) void {
        for (self.picks) |pick| self.gpa.free(pick.path);
        self.gpa.free(self.picks);
        self.gpa.free(self.aspects);
    }
};

const Candidate = struct {
    doc: u32,
    evidence_bits: f64,

    fn before(paths: []const []const u8, a: Candidate, b: Candidate) bool {
        if (a.evidence_bits != b.evidence_bits) return a.evidence_bits > b.evidence_bits;
        return std.mem.order(u8, paths[a.doc], paths[b.doc]) == .lt;
    }
};

fn hitBefore(_: void, a: Hit, b: Hit) bool {
    if (a.cost.bits != b.cost.bits) return a.cost.bits < b.cost.bits;
    if (a.evidence_bits != b.evidence_bits) return a.evidence_bits > b.evidence_bits;
    return std.mem.order(u8, a.path, b.path) == .lt;
}

fn rootsCovered(roots: []const []const u8, indexed: []const []const u8) bool {
    const filter: scope.PathFilter = .{ .roots = indexed };
    for (roots) |root| if (!filter.admits(scope.normalizeRoot(root))) return false;
    return true;
}

fn liveEvidence(body: []const u8, needles: []const []const u8, weights: []const f64) f64 {
    var score: f64 = 0.0;
    for (needles, weights) |needle, weight|
        if (std.mem.find(u8, body, needle) != null) {
            score += weight;
        };
    return score;
}

fn referenceFor(gpa: std.mem.Allocator, body: []const u8, needles: []const []const u8) ![]u8 {
    const radius = 4 << 10;
    const max_reference = 64 << 10;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (needles) |needle| {
        const pos = std.mem.find(u8, body, needle) orelse continue;
        const lo = pos -| radius;
        const hi = @min(body.len, pos + needle.len + radius);
        if (out.items.len > 0) try out.append(gpa, 0);
        const room = max_reference -| out.items.len;
        try out.appendSlice(gpa, body[lo..@min(hi, lo + room)]);
        if (out.items.len >= max_reference) break;
    }
    if (out.items.len == 0)
        try out.appendSlice(gpa, body[0..@min(body.len, radius * 2)]);
    return out.toOwnedSlice(gpa);
}

/// Where a `WarmQuery`'s warm state comes from. `.load` is the one-shot CLI
/// lane: mmap the index and walk the tree for freshness, both discarded when
/// the query ends. `.resident` is the daemon/resident-session lane: the
/// session holds the mmap'd index warm across queries and hands a freshness
/// overlay it recomputes only when its watcher reports the tree dirty — so an
/// eligible query skips both the per-call index map AND the O(tree) stat walk,
/// the two costs that dominate a cold retrieval. The injected `fresh_ids`
/// index the session's own path table (base ∪ its overlay), which the caller
/// guarantees outlives the query; the query never mutates it.
pub const Source = union(enum) {
    load,
    resident: struct { persisted: *persist.Persisted, fresh_ids: []const u32 },
};

/// Owns the common warm-retrieval lane: persisted state, corpus-priced query
/// terms, posting nominees, and the freshness overlay. Search and pack consume
/// the same live-folded evidence through different final deciders — and one-shot
/// and resident callers share this whole lane, differing only in `Source`: who
/// owns the index and whether the freshness walk runs or is handed in.
const WarmQuery = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    roots: []const []const u8,
    /// Borrowed pointer; `owns_persisted` decides whether `deinit` unmaps it.
    persisted: *persist.Persisted,
    owns_persisted: bool,
    terms: [][]const u8,
    weights: []f64,
    /// Postings per active term — the corpus document frequency `pack` prices
    /// its aspects from, kept so nobody queries the index twice for it.
    dfs: []usize,
    selective: std.ArrayList([]const u8) = .empty,
    matches: std.AutoHashMapUnmanaged(u32, f64) = .empty,
    /// The freshness walk result — set (and owned) ONLY on the `.load` lane.
    /// A resident query injects `fresh_ids` directly and leaves this null.
    freshness: ?fresh.Candidates = null,
    /// The changed-doc set folded live in `foldFresh`, aliasing either
    /// `freshness.fresh_ids` (one-shot) or the session's cached overlay.
    fresh_ids: []const u32 = &.{},

    /// `max_terms` caps how many query chunks participate — `pack` needs its
    /// aspect table to fit one `u64` attribution mask, while a search has no
    /// reason to drop a term.
    fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        query: []const u8,
        roots: []const []const u8,
        max_terms: usize,
        src: Source,
    ) !?WarmQuery {
        const p: *persist.Persisted, const owns = switch (src) {
            .load => blk: {
                const loaded = (persist.loadQuiet(gpa, io) catch return null) orelse return null;
                const box = gpa.create(persist.Persisted) catch |e| {
                    var tmp = loaded;
                    tmp.deinit();
                    return e;
                };
                box.* = loaded;
                break :blk .{ box, true };
            },
            .resident => |r| .{ r.persisted, false },
        };
        errdefer if (owns) {
            p.deinit();
            gpa.destroy(p);
        };
        if (!rootsCovered(roots, p.roots.items)) return null;

        const query_terms = try coverage.decompose(gpa, query);
        if (query_terms.len == 0) {
            gpa.free(query_terms);
            return null;
        }
        const active = query_terms[0..@min(query_terms.len, max_terms)];
        const weights = gpa.alloc(f64, active.len) catch |err| {
            gpa.free(query_terms);
            return err;
        };
        const dfs = gpa.alloc(usize, active.len) catch |err| {
            gpa.free(weights);
            gpa.free(query_terms);
            return err;
        };
        var self: WarmQuery = .{
            .gpa = gpa,
            .io = io,
            .roots = roots,
            .persisted = p,
            .owns_persisted = owns,
            .terms = query_terms,
            .weights = weights,
            .dfs = dfs,
        };
        errdefer self.deinit();

        const n = self.persisted.paths.items.len;
        for (active, self.weights, self.dfs) |needle, *weight, *df| {
            const ids = self.persisted.queryLiteral(gpa, needle) catch return null;
            defer gpa.free(ids);
            df.* = ids.len;
            // Ubiquitous glue words carry little information. A lone broad
            // term stays honest; broad branches yield to rarer companions.
            if (coverage.kindOf(ids.len, n, active.len) == .glue) {
                weight.* = 0.0;
                continue;
            }
            try self.selective.append(gpa, needle);
            weight.* = self.dfBits(ids.len);
            for (ids) |doc| {
                const gop = try self.matches.getOrPut(gpa, doc);
                gop.value_ptr.* = (if (gop.found_existing) gop.value_ptr.* else 0.0) + weight.*;
            }
        }

        switch (src) {
            // One-shot: walk the tree now, appending brand-new files to the
            // owned path table so their fresh ids resolve; own the result.
            .load => {
                const filters = if (self.selective.items.len > 0) self.selective.items else active;
                self.freshness = try fresh.candidates(
                    gpa,
                    io,
                    self.persisted,
                    &self.persisted.paths,
                    filters,
                    if (roots.len > 0) roots else self.persisted.roots.items,
                );
                self.fresh_ids = self.freshness.?.fresh_ids;
            },
            // Resident: the session already walked (or proved clean) and
            // extended its path table; just fold the changed docs it names.
            .resident => |r| self.fresh_ids = r.fresh_ids,
        }
        try self.foldFresh();
        return self;
    }

    fn deinit(self: *WarmQuery) void {
        if (self.freshness) |*f| f.deinit();
        self.matches.deinit(self.gpa);
        self.selective.deinit(self.gpa);
        self.gpa.free(self.dfs);
        self.gpa.free(self.weights);
        self.gpa.free(self.terms);
        if (self.owns_persisted) {
            self.persisted.deinit();
            self.gpa.destroy(self.persisted);
        }
    }

    fn activeTerms(self: *const WarmQuery) []const []const u8 {
        return self.terms[0..self.weights.len];
    }

    fn admits(self: *const WarmQuery, path: []const u8) bool {
        return (scope.PathFilter{ .roots = self.roots }).admits(scope.normalizeRoot(path));
    }

    fn dfBits(self: *const WarmQuery, df: usize) f64 {
        const count = self.persisted.paths.items.len;
        return if (df == 0)
            std.math.log2(@as(f64, @floatFromInt(@max(count, 2))))
        else
            std.math.log2(@as(f64, @floatFromInt(count)) / @as(f64, @floatFromInt(df)));
    }

    fn foldFresh(self: *WarmQuery) !void {
        for (self.fresh_ids) |doc| {
            if (doc >= self.persisted.paths.items.len or !self.admits(self.persisted.paths.items[doc])) {
                _ = self.matches.remove(doc);
                continue;
            }
            const body = corpus.readMember(self.io, Dir.cwd(), self.persisted.paths.items[doc], self.gpa) orelse {
                _ = self.matches.remove(doc);
                continue;
            };
            defer self.gpa.free(body);
            const evidence = liveEvidence(body, self.activeTerms(), self.weights);
            if (evidence > 0.0)
                try self.matches.put(self.gpa, doc, evidence)
            else
                _ = self.matches.remove(doc);
        }
    }

    /// The nominee pool, strongest posting evidence first. Both deciders start
    /// here: the index can say which documents mention the query, never which
    /// are about it, so the ranking exists to bound how many bodies get read.
    fn nominate(self: *const WarmQuery, gpa: std.mem.Allocator) !std.ArrayList(Candidate) {
        var ranked: std.ArrayList(Candidate) = .empty;
        errdefer ranked.deinit(gpa);
        var it = self.matches.iterator();
        while (it.next()) |entry| {
            const doc = entry.key_ptr.*;
            if (doc < self.persisted.paths.items.len and self.admits(self.persisted.paths.items[doc]))
                try ranked.append(gpa, .{ .doc = doc, .evidence_bits = entry.value_ptr.* });
        }
        std.mem.sort(Candidate, ranked.items, self.persisted.paths.items, Candidate.before);
        return ranked;
    }

    fn refreshed(self: *const WarmQuery) usize {
        return self.fresh_ids.len;
    }
};

/// Return an index-backed answer, or `null` when the persisted index cannot
/// soundly cover this query/root shape. The caller owns the returned result.
/// `src` picks the lane: `.load` maps the index and walks the tree fresh
/// (one-shot CLI, discarded when done); `.resident` reuses the daemon's warm
/// index + cached freshness so an eligible query pays neither cost.
pub fn retrieve(
    gpa: std.mem.Allocator,
    io: std.Io,
    query: []const u8,
    roots: []const []const u8,
    top: usize,
    src: Source,
) !?Result {
    if (query.len < 3 or top == 0) return null;
    var warm = (try WarmQuery.init(gpa, io, query, roots, std.math.maxInt(usize), src)) orelse return null;
    defer warm.deinit();

    var ranked = try warm.nominate(gpa);
    defer ranked.deinit(gpa);

    const pool = @min(ranked.items.len, @max(top * 3, 12));
    var hits: std.ArrayList(Hit) = .empty;
    errdefer {
        for (hits.items) |h| gpa.free(h.path);
        hits.deinit(gpa);
    }
    for (ranked.items[0..pool]) |candidate| {
        const path = warm.persisted.paths.items[candidate.doc];
        const body = corpus.readMember(io, Dir.cwd(), path, gpa) orelse continue;
        defer gpa.free(body);
        const reference = try referenceFor(gpa, body, warm.activeTerms());
        defer gpa.free(reference);
        var automaton = try zipper.Automaton.build(gpa, reference);
        defer automaton.deinit();
        var cost = automaton.crossParse(query);
        // A copied factor must identify its window inside the original file,
        // not merely inside our bounded decider excerpt. Restore that pointer
        // cost so giant omnibus files do not beat focused modules for free.
        if (cost.factors > 0 and body.len > reference.len)
            cost.bits += @as(f64, @floatFromInt(cost.factors)) *
                std.math.log2(@as(f64, @floatFromInt(body.len + 1)) /
                    @as(f64, @floatFromInt(reference.len + 1)));
        try hits.append(gpa, .{
            .path = try gpa.dupe(u8, path),
            .evidence_bits = candidate.evidence_bits,
            .cost = cost,
        });
    }
    std.mem.sort(Hit, hits.items, {}, hitBefore);
    if (hits.items.len > top) {
        for (hits.items[top..]) |h| gpa.free(h.path);
        hits.shrinkRetainingCapacity(top);
    }
    return .{
        .hits = try hits.toOwnedSlice(gpa),
        .indexed_files = warm.persisted.paths.items.len,
        .candidates = ranked.items.len,
        .refreshed = warm.refreshed(),
        .gpa = gpa,
    };
}

/// How many nominees `pack` reads before grading. The index knows which
/// documents MENTION the query; only the bytes say which are about it, and a
/// changelog that name-drops every term outranks the module on postings alone.
/// Deep enough that the right file survives a bad nomination order, shallow
/// enough to stay inside the query budget (~48 reads ≈ 200 ms warm).
fn poolSize(top: usize) usize {
    return @max(top * 8, 48);
}

/// Index-backed graded coverage packing for `relate pack`.
///
/// Postings nominate, bytes decide. Aspects are priced from corpus document
/// frequency (`−log₂(df/N)`), every pooled body is graded on each aspect by
/// saturating density, and the greedy facility-location sweep picks the set
/// that jointly explains the most priced bits. `src` picks the lane (see
/// `retrieve`).
pub fn pack(
    gpa: std.mem.Allocator,
    io: std.Io,
    query: []const u8,
    roots: []const []const u8,
    top: usize,
    src: Source,
) !?PackResult {
    if (query.len < 3 or top == 0) return null;
    var warm = (try WarmQuery.init(gpa, io, query, roots, coverage.max_aspects, src)) orelse return null;
    defer warm.deinit();

    const n = warm.persisted.paths.items.len;
    const paths = warm.persisted.paths.items;
    const active = warm.activeTerms();

    // Price the aspects against the whole indexed corpus, not the pool: what a
    // term is WORTH is a fact about the corpus, and pool-local frequency would
    // reprice it by however the nomination happened to land.
    const aspects = try gpa.alloc(coverage.Aspect, active.len);
    errdefer gpa.free(aspects);
    for (active, warm.dfs, aspects) |term, df, *aspect| {
        const kind = coverage.kindOf(df, n, active.len);
        aspect.* = .{
            .term = term,
            .bits = if (kind == .priced) coverage.bitsOf(df, n) else 0.0,
            .df = df,
            .kind = kind,
        };
    }

    var ranked = try warm.nominate(gpa);
    defer ranked.deinit(gpa);
    const pool = @min(ranked.items.len, poolSize(top));

    // Read the pool once; grade it once the mean length is known.
    var bodies: std.ArrayList([]u8) = .empty;
    defer {
        for (bodies.items) |body| gpa.free(body);
        bodies.deinit(gpa);
    }
    var docs: std.ArrayList(u32) = .empty;
    defer docs.deinit(gpa);
    var total_len: u64 = 0;
    for (ranked.items[0..pool]) |candidate| {
        const body = corpus.readMember(io, Dir.cwd(), paths[candidate.doc], gpa) orelse continue;
        try bodies.append(gpa, body);
        try docs.append(gpa, candidate.doc);
        total_len += body.len;
    }
    const mean_len = if (bodies.items.len == 0) 0.0 else @as(f64, @floatFromInt(total_len)) / @as(f64, @floatFromInt(bodies.items.len));

    const grades = try gpa.alloc(f64, bodies.items.len * active.len);
    defer gpa.free(grades);
    const cands = try gpa.alloc(coverage.Candidate, bodies.items.len);
    defer gpa.free(cands);
    for (bodies.items, docs.items, 0..) |body, doc, i| {
        const row = grades[i * active.len ..][0..active.len];
        coverage.gradeBody(row, aspects, body, mean_len);
        cands[i] = .{ .doc = doc, .strength = row };
    }

    const total_bits = coverage.pricedBits(aspects);
    const selected = try coverage.greedy(gpa, aspects, cands, paths, top, minGain(total_bits));
    defer gpa.free(selected);

    var picks: std.ArrayList(PackPick) = .empty;
    errdefer {
        for (picks.items) |pick| gpa.free(pick.path);
        picks.deinit(gpa);
    }
    for (selected) |pick|
        try picks.append(gpa, .{
            .path = try gpa.dupe(u8, paths[pick.doc]),
            .marginal_bits = pick.marginal_bits,
            .covered_bits = pick.covered_bits,
            .solo_bits = pick.solo_bits,
            .owns = pick.owns,
        });

    return .{
        .picks = try picks.toOwnedSlice(gpa),
        .aspects = aspects,
        .total_bits = total_bits,
        .foreign = countKind(aspects, .foreign),
        .glue = countKind(aspects, .glue),
        .indexed_files = n,
        .candidates = ranked.items.len,
        .pool = bodies.items.len,
        .refreshed = warm.refreshed(),
        .gpa = gpa,
    };
}

fn countKind(aspects: []const coverage.Aspect, kind: coverage.Kind) usize {
    var n: usize = 0;
    for (aspects) |aspect| n += @intFromBool(aspect.kind == kind);
    return n;
}

/// The floor a pick must clear to earn a place in the reading set: 2% of the
/// query's priced description, and never less than a quarter-bit. Padding a
/// pack out to `--top` with files that explain nothing new is the same lie as
/// reporting 100% coverage from one pick — it just costs more to read.
pub fn minGain(total_bits: f64) f64 {
    return @max(0.02 * total_bits, 0.25);
}

test "the read pool is deep enough that a bad nomination order is survivable" {
    // The nomination order is posting evidence, which cannot tell "mentions it"
    // from "is about it" — so the pool has to be much deeper than the ask.
    try std.testing.expect(poolSize(4) >= 48);
    try std.testing.expectEqual(@as(usize, 160), poolSize(20));
}

test "a pick must clear a floor relative to the query it is answering" {
    // 2% of the priced description, never under a quarter-bit: a pack padded
    // out to --top with files that explain nothing new just costs more to read.
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), minGain(30.0), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), minGain(1.0), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), minGain(0.0), 1e-9);
}

test "evidence reference is bounded and keeps distant query neighborhoods" {
    const gpa = std.testing.allocator;
    const body = try gpa.alloc(u8, 200 << 10);
    defer gpa.free(body);
    @memset(body, 'x');
    @memcpy(body[100..103], "dog");
    @memcpy(body[150 << 10 ..][0..9], "freshness");

    const reference = try referenceFor(gpa, body, &.{ "dog", "freshness" });
    defer gpa.free(reference);
    try std.testing.expect(reference.len <= 64 << 10);
    try std.testing.expect(std.mem.find(u8, reference, "dog") != null);
    try std.testing.expect(std.mem.find(u8, reference, "freshness") != null);
}
