//! Persisted candidate retrieval for `relate search`.
//!
//! The exact Ziv–Merhav decider is intentionally per-document; rebuilding its
//! recall lexicon over every corpus byte before each query is not. This module
//! nominates a bounded pool from Gist's mmap-backed trigram postings, folds in
//! changed files through the shared T3 freshness overlay, then reads only that
//! pool for exact suffix-automaton pricing. Missing, incompatible, or corrupt
//! state returns `null`, so the caller can use the live lexicon oracle.

const std = @import("std");
const scope = @import("../../../../corpus/scope/glob.zig");
const corpus = @import("../../../../corpus/tree/corpus.zig");
const fresh = @import("../../../../corpus/index/trigrams/fresh.zig");
const persist = @import("../../../../corpus/index/trigrams/persist.zig");
const coverage = @import("../../../../kernel/kinship/recall/coverage.zig");
const zipper = @import("../../../../kernel/kinship/recall/zipper.zig");

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
};

pub const PackResult = struct {
    picks: []PackPick,
    total_bits: f64,
    foreign: usize,
    indexed_files: usize,
    candidates: usize,
    refreshed: usize,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *PackResult) void {
        for (self.picks) |pick| self.gpa.free(pick.path);
        self.gpa.free(self.picks);
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

fn terms(gpa: std.mem.Allocator, query: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);

    // Exact phrasing is the strongest evidence when present; words recover the
    // descriptive-query case where no document repeats the whole sentence.
    if (query.len >= 3) try out.append(gpa, query);
    var it = std.mem.tokenizeAny(u8, query, " \t\r\n.,;:!?()[]{}<>/\\|\"'`~@#$%^&*+=-");
    while (it.next()) |term| {
        if (term.len < 3) continue;
        var duplicate = false;
        for (out.items) |seen| duplicate = duplicate or std.mem.eql(u8, seen, term);
        if (!duplicate) try out.append(gpa, term);
    }
    return out.toOwnedSlice(gpa);
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

const Mode = enum { search, pack };

const Match = struct {
    evidence_bits: f64 = 0.0,
    mask: u64 = 0,
};

/// Where a `WarmQuery`'s warm state comes from. `.load` is the one-shot CLI
/// lane: mmap the index and walk the tree for freshness, both discarded when
/// the query ends. `.resident` is the daemon lane (ADR-352 rung 2.5): the
/// session holds the mmap'd index warm across queries and hands a freshness
/// overlay it recomputes only when its watcher reports the tree dirty — so an
/// eligible query skips both the per-call index map AND the O(tree) stat walk,
/// the two costs that dominate a cold `relate search`. The injected `fresh_ids`
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
    mode: Mode,
    /// Borrowed pointer; `owns_persisted` decides whether `deinit` unmaps it.
    persisted: *persist.Persisted,
    owns_persisted: bool,
    terms: [][]const u8,
    weights: []f64,
    selective: std.ArrayList([]const u8) = .empty,
    matches: std.AutoHashMapUnmanaged(u32, Match) = .empty,
    /// The freshness walk result — set (and owned) ONLY on the `.load` lane.
    /// A resident query injects `fresh_ids` directly and leaves this null.
    freshness: ?fresh.Candidates = null,
    /// The changed-doc set folded live in `foldFresh`, aliasing either
    /// `freshness.fresh_ids` (one-shot) or the session's cached overlay.
    fresh_ids: []const u32 = &.{},
    foreign: usize = 0,

    fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        query: []const u8,
        roots: []const []const u8,
        mode: Mode,
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

        const query_terms = try terms(gpa, query);
        if (query_terms.len == 0) {
            gpa.free(query_terms);
            return null;
        }
        const active = query_terms[0..@min(query_terms.len, if (mode == .pack) 64 else query_terms.len)];
        const weights = gpa.alloc(f64, active.len) catch |err| {
            gpa.free(query_terms);
            return err;
        };
        var self: WarmQuery = .{
            .gpa = gpa,
            .io = io,
            .roots = roots,
            .mode = mode,
            .persisted = p,
            .owns_persisted = owns,
            .terms = query_terms,
            .weights = weights,
        };
        errdefer self.deinit();

        for (active, self.weights, 0..) |needle, *weight, bit| {
            const ids = self.persisted.idx.queryLiteral(gpa, needle) catch return null;
            defer gpa.free(ids);
            if (mode == .pack and ids.len == 0) {
                self.foreign += 1;
                weight.* = 0.0;
                continue;
            }
            // Ubiquitous glue words carry little information. A lone broad
            // term stays honest; broad branches yield to rarer companions.
            if (active.len > 1 and ids.len > @max(self.persisted.paths.items.len / 20, 1024)) {
                weight.* = 0.0;
                continue;
            }
            try self.selective.append(gpa, needle);
            weight.* = self.dfBits(ids.len);
            for (ids) |doc| {
                const gop = try self.matches.getOrPut(gpa, doc);
                if (!gop.found_existing) gop.value_ptr.* = .{};
                switch (mode) {
                    .search => gop.value_ptr.evidence_bits += weight.*,
                    .pack => gop.value_ptr.mask |= @as(u64, 1) << @intCast(bit),
                }
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
                    &self.persisted.idx,
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

    fn liveMatch(self: *const WarmQuery, body: []const u8) Match {
        if (self.mode == .search)
            return .{ .evidence_bits = liveEvidence(body, self.activeTerms(), self.weights) };

        var mask: u64 = 0;
        for (self.activeTerms(), self.weights, 0..) |needle, weight, bit|
            if (weight > 0.0 and std.mem.find(u8, body, needle) != null) {
                mask |= @as(u64, 1) << @intCast(bit);
            };
        return .{ .mask = mask };
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
            const match = self.liveMatch(body);
            if (match.evidence_bits > 0.0 or match.mask != 0)
                try self.matches.put(self.gpa, doc, match)
            else
                _ = self.matches.remove(doc);
        }
    }

    fn refreshed(self: *const WarmQuery) usize {
        return self.fresh_ids.len;
    }
};

/// Return an index-backed answer, or `null` when the persisted index cannot
/// soundly cover this query/root shape. The caller owns the returned result.
/// One-shot: maps the index and walks the tree, discarding both when done.
pub fn retrieve(
    gpa: std.mem.Allocator,
    io: std.Io,
    query: []const u8,
    roots: []const []const u8,
    top: usize,
) !?Result {
    return retrieveWith(gpa, io, query, roots, top, .load);
}

/// `retrieve` over an explicit `Source` — the resident daemon passes `.resident`
/// with its warm index + cached freshness so an eligible query pays neither the
/// index map nor the stat walk.
pub fn retrieveWith(
    gpa: std.mem.Allocator,
    io: std.Io,
    query: []const u8,
    roots: []const []const u8,
    top: usize,
    src: Source,
) !?Result {
    if (query.len < 3 or top == 0) return null;
    var warm = (try WarmQuery.init(gpa, io, query, roots, .search, src)) orelse return null;
    defer warm.deinit();

    var ranked: std.ArrayList(Candidate) = .empty;
    defer ranked.deinit(gpa);
    var sit = warm.matches.iterator();
    while (sit.next()) |entry| {
        const doc = entry.key_ptr.*;
        if (doc < warm.persisted.paths.items.len and warm.admits(warm.persisted.paths.items[doc]))
            try ranked.append(gpa, .{ .doc = doc, .evidence_bits = entry.value_ptr.evidence_bits });
    }
    std.mem.sort(Candidate, ranked.items, warm.persisted.paths.items, Candidate.before);

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

/// Index-backed weighted max-coverage for `relate pack`. Query chunks are
/// corpus-priced from posting frequency; a picked document pays only for
/// chunks not covered by earlier picks.
pub fn pack(
    gpa: std.mem.Allocator,
    io: std.Io,
    query: []const u8,
    roots: []const []const u8,
    top: usize,
) !?PackResult {
    return packWith(gpa, io, query, roots, top, .load);
}

/// `pack` over an explicit `Source` (see `retrieveWith`).
pub fn packWith(
    gpa: std.mem.Allocator,
    io: std.Io,
    query: []const u8,
    roots: []const []const u8,
    top: usize,
    src: Source,
) !?PackResult {
    if (query.len < 3 or top == 0) return null;
    var warm = (try WarmQuery.init(gpa, io, query, roots, .pack, src)) orelse return null;
    defer warm.deinit();

    var docs: std.ArrayList(coverage.MaskCandidate) = .empty;
    defer docs.deinit(gpa);
    var mit = warm.matches.iterator();
    while (mit.next()) |entry| {
        const doc = entry.key_ptr.*;
        if (doc >= warm.persisted.paths.items.len or !warm.admits(warm.persisted.paths.items[doc])) continue;
        const size = (Dir.cwd().statFile(io, warm.persisted.paths.items[doc], .{}) catch continue).size;
        try docs.append(gpa, .{
            .doc = doc,
            .mask = entry.value_ptr.mask,
            .cost = std.math.log2(@as(f64, @floatFromInt(size + 2))),
        });
    }

    var total_bits: f64 = 0.0;
    for (warm.weights) |weight| total_bits += weight;
    const selected = try coverage.greedyMasks(gpa, docs.items, warm.weights, warm.persisted.paths.items, top);
    defer gpa.free(selected);
    var picks: std.ArrayList(PackPick) = .empty;
    errdefer {
        for (picks.items) |pick| gpa.free(pick.path);
        picks.deinit(gpa);
    }
    for (selected) |pick|
        try picks.append(gpa, .{
            .path = try gpa.dupe(u8, warm.persisted.paths.items[pick.doc]),
            .marginal_bits = pick.marginal_bits,
            .covered_bits = pick.covered_bits,
        });

    return .{
        .picks = try picks.toOwnedSlice(gpa),
        .total_bits = total_bits,
        .foreign = warm.foreign,
        .indexed_files = warm.persisted.paths.items.len,
        .candidates = docs.items.len,
        .refreshed = warm.refreshed(),
        .gpa = gpa,
    };
}

test "query chunks retain a three-byte term and deduplicate whole-query words" {
    const gpa = std.testing.allocator;
    const short = try terms(gpa, "dog");
    defer gpa.free(short);
    try std.testing.expectEqual(@as(usize, 1), short.len);
    try std.testing.expectEqualStrings("dog", short[0]);

    const phrase = try terms(gpa, "resident session freshness");
    defer gpa.free(phrase);
    try std.testing.expectEqual(@as(usize, 4), phrase.len);
    try std.testing.expectEqualStrings("resident session freshness", phrase[0]);
    try std.testing.expectEqualStrings("resident", phrase[1]);
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
