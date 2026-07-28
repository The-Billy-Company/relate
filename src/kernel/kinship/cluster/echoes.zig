//! echoes — the repetition kernel: what repeats in this corpus?
//!
//! One question, asked three ways over one comparison table. Four verbs used to
//! own a private answer to it — `dups` (byte pairs), `clusters` (byte families),
//! `echoes` (structural-gap pairs), `concepts` (structural families of
//! functions) — each with its own nomination, its own noise floors, its own
//! ordering, and its own drift. They differ in exactly three axes:
//!
//!   • **unit** — is a row a file or a function? The caller decides by which
//!     table it hands over; nothing here knows the difference beyond `lines`.
//!   • **channel** — `copies` (verbatim duplication and its drift), `shapes`
//!     (shared skeleton), `twins` (bytes−structure gap: same skeleton, renamed
//!     vocabulary — Type-2 clones), `any` (closest of either).
//!   • **shape** — `pairs` (which two repeat), `families` (the whole fork
//!     family, transitively closed), `distinct` (the complement: which units
//!     have NO kin here, each with its nearest miss).
//!
//! Nomination follows the channel's own record — byte seed buckets for `copies`,
//! silhouette buckets for `shapes`/`twins`, the union for `any` — so no channel
//! is ever nominated through a proxy it disagrees with. Every emitted relation
//! is then verified exactly against both full records; buckets may only skip
//! work, never decide. Both channel scores ride every row: they are reported
//! side by side, never fused into one opaque number.
//!
//! Two noise classes are excluded before scoring, because a repetition report
//! is about authored code:
//!   • **Codegen.** Twin templates are the densest structural clones there are
//!     (identical shape, renamed symbols), but the fix lives in the template,
//!     never the output — so generated units are dropped the way `gist --rank`
//!     sinks them (path suffix only, no byte re-read). `include_generated`
//!     restores them for a drift audit.
//!   • **Sub-mass units.** A unit too short to shed `min_mass` fingerprints has
//!     a distance estimated over a handful of KMV samples, where `≈ 0` is
//!     small-sample noise: an 86-member family of one-line `__init__.py`
//!     re-exports is arithmetic, not a finding.
//!
//! Pure: no corpus, argv, stdout, or I/O. The driver resolves a unit view and
//! renders; this nominates, admits, groups, ranks, and prices.

const std = @import("std");
const sketch_mod = @import("../metric/sketch.zig");
const silhouette_mod = @import("../metric/silhouette.zig");
const channel_mod = @import("../metric/channel.zig");
const pairs_mod = @import("pairs.zig");
const families_mod = @import("families.zig");
const signals = @import("../../rank/signals.zig");
const parallel = @import("../../math/parallel.zig");

const Sketch = sketch_mod.Sketch;
const Silhouette = silhouette_mod.Silhouette;

pub const Channel = channel_mod.Channel;

/// The mass floors, one per RECORD TYPE. Thinness is a property of the record,
/// not of its container: sixteen min-hashes are sixteen min-hashes whether they
/// came from a 900-line file or a 40-line function, and a distance between two
/// records this thin is arithmetic rather than kinship (two empty records share
/// every absent fingerprint, so they read as `identical`).
///
/// Indexing these by unit instead — the shape they were born in, when `dups`
/// only ever asked bytes-over-files and `concepts` only ever asked
/// shapes-over-functions — silently compared a silhouette length against a
/// sketch-calibrated number the moment either verb could name the other's
/// channel, which withheld every candidate on `--as shapes` over files.
///
/// A sketch needs the bottom-k seed width in min-hashes: below it a record
/// barely buckets.
pub const sketch_mass = pairs_mod.seed_hashes;

/// A silhouette needs this many FINGERPRINTS. Note the unit: the winnow
/// guarantees that a shared run of `gram + window − 1` = 8 *tokens* surfaces in
/// both sets, and reusing that expression here read as a derivation while
/// actually comparing tokens against fingerprints. The number is the same; only
/// one of the two is a real calibration.
///
/// Measured on this kernel's own tree with `--as shapes --shape families`: at 4
/// a nineteen-member "family" of README prose skeletons enters (markdown
/// normalizes to a handful of fingerprints, and every README in a tree shares
/// them — structurally true, useless as a consolidation target); at 16 genuine
/// code families are lost. Eight fingerprints is also where a single
/// disagreement stops being able to cross a whole calibrated band.
pub const silhouette_mass = 8;

/// The floor for whichever record `chan` nominates on.
pub fn massFloor(chan: Channel) usize {
    return switch (chan) {
        .copies => sketch_mass,
        .shapes, .twins, .any => silhouette_mass,
        .recall, .context => 0,
    };
}

/// A pair priced on both channels, plus the score the caller's channel ranks
/// by. Both raw numbers ride every row — they are reported side by side, never
/// fused into one opaque number.
const Scores = struct { score: f64, bytes: f64, structure: f64 };

/// Which shape of repetition answer the caller wants.
pub const Shape = enum {
    /// Which two units repeat — the flat, closest-first pair list.
    pairs,
    /// The transitive closure: the whole fork family in one row, so a caller
    /// never re-runs union-find over a pair list (every consumer did).
    families,
    /// The complement — units with no kin at this threshold, each with its
    /// nearest miss. "Which of these 14 implementations is genuinely unique?"
    distinct,
};

/// The comparison table: one row per unit, in the caller's canonical order.
///
/// `labels` order the answer deterministically and carry the generated-path
/// check (`path` for files, `path#Lstart` for functions — the anchor is
/// stripped before the check). `lines` is the per-unit line count, or empty
/// when the source cannot supply one; `min_lines` then does not apply. A
/// channel's record array may be empty when that channel is unused.
pub const Table = struct {
    labels: []const []const u8,
    lines: []const u32 = &.{},
    sketches: []const Sketch = &.{},
    silhouettes: []const Silhouette = &.{},

    pub fn len(self: Table) usize {
        return self.labels.len;
    }

    fn bytesAt(self: Table, i: u32, j: u32) f64 {
        if (self.sketches.len == 0) return std.math.nan(f64);
        return sketch_mod.distance(&self.sketches[i], &self.sketches[j]);
    }

    fn structureAt(self: Table, i: u32, j: u32) f64 {
        if (self.silhouettes.len == 0) return std.math.nan(f64);
        return silhouette_mod.distance(&self.silhouettes[i], &self.silhouettes[j]);
    }

    /// The same distance, or null when it provably exceeds `ceiling`. An
    /// unmeasurable channel answers null too: both spellings of "this pair is
    /// not it" reach the same `continue`, and neither can be mistaken for a
    /// relation.
    fn bytesWithin(self: Table, i: u32, j: u32, ceiling: f64) ?f64 {
        if (self.sketches.len == 0) return null;
        return sketch_mod.within(&self.sketches[i], &self.sketches[j], ceiling);
    }

    fn structureWithin(self: Table, i: u32, j: u32, ceiling: f64) ?f64 {
        if (self.silhouettes.len == 0) return null;
        return silhouette_mod.within(&self.silhouettes[i], &self.silhouettes[j], ceiling);
    }

    /// A pair's exact score in both channels, or null when this channel's
    /// threshold provably cannot admit it.
    ///
    /// Every number returned is exact — a ceiling decides only whether the
    /// merge runs to the end or abandons a pair it has already disqualified,
    /// never what it reports. Two savings follow, and the second is the larger:
    /// the disqualifying channel stops early, and the companion channel — which
    /// the row prints but no threshold consults — is priced only for a pair
    /// that survived. In a repetition sweep the survivors are a fraction of a
    /// percent, so nearly every pair now pays one truncated merge instead of
    /// two complete ones.
    fn priced(self: Table, params: Params, a: u32, z: u32) ?Scores {
        return switch (params.channel) {
            // The score IS one channel's distance: bound that one.
            .copies => if (self.bytesWithin(a, z, params.max_dist)) |b|
                .{ .score = b, .bytes = b, .structure = self.structureAt(a, z) }
            else
                null,
            .shapes => if (self.structureWithin(a, z, params.max_dist)) |s|
                .{ .score = s, .bytes = self.bytesAt(a, z), .structure = s }
            else
                null,
            // A gap needs both sides, but a distance can never exceed 1, so a
            // gap of `min_echo` caps how structurally distant its pair may be.
            // That ceiling is where the unrelated majority dies: strangers sit
            // at a structure distance near 1.0, which no admissible gap allows.
            .twins => if (self.structureWithin(a, z, 1.0 - params.min_echo)) |s| gap: {
                const b = self.bytesAt(a, z);
                break :gap if (params.admits(b - s))
                    .{ .score = b - s, .bytes = b, .structure = s }
                else
                    null;
            } else null,
            // Close in EITHER channel. Whichever answers under the ceiling
            // admits the pair; the other is then priced in full for the row.
            .any => either: {
                if (self.bytesWithin(a, z, params.max_dist)) |b| {
                    const s = self.structureAt(a, z);
                    break :either .{ .score = @min(b, s), .bytes = b, .structure = s };
                }
                const s = self.structureWithin(a, z, params.max_dist) orelse break :either null;
                const b = self.bytesAt(a, z);
                break :either .{ .score = @min(b, s), .bytes = b, .structure = s };
            },
            // Neither is a pairwise channel: no relation can be admitted.
            .recall, .context => null,
        };
    }

    /// Does unit `i` carry enough of EVERY record this channel reads? `twins`
    /// and `any` combine both measurements, so a fat silhouette must not excuse
    /// a sketch too thin to have produced its own number — one bogus 0.0 on
    /// either side propagates straight into the combined score.
    ///
    /// `override` is the caller's `--min-mass`, applied to every record it
    /// governs; null defers to each record's own calibration.
    fn massy(self: Table, chan: Channel, i: u32, override: ?usize) bool {
        if (chan == .recall) return true;
        const bytes = chan == .copies or chan == .twins or chan == .any;
        const shape = chan != .copies;
        if (bytes and self.sketches.len > i and
            self.sketches[i].len < (override orelse sketch_mass)) return false;
        if (shape and self.silhouettes.len > i and
            self.silhouettes[i].len < (override orelse silhouette_mass)) return false;
        // A record the view never resolved is absent, not thin: the score for
        // that channel comes back NaN and the pair is dropped on its own merits.
        return true;
    }
};

/// The repetition knobs. `max_dist` admits a distance-channel edge at ≤ T;
/// `min_echo` admits a `twins` edge at gap ≥ E — one flag per polarity, never
/// one spelling for both (that silently inverts a threshold).
pub const Params = struct {
    channel: Channel = .twins,
    shape: Shape = .pairs,
    max_dist: f64 = 0.25,
    min_echo: f64 = 0.15,
    /// Units shorter than this cannot anchor a relation. 0 = no floor (and the
    /// default for the file unit, whose line counts the atlas does not carry).
    min_lines: usize = 0,
    /// The smallest family emitted (`families` only).
    min_size: usize = 2,
    /// Records thinner than this cannot anchor a relation. Null = each record's
    /// own calibration (`massFloor`), which is what a caller almost always
    /// wants: the right floor follows from the channel, not from restating it.
    min_mass: ?usize = null,
    /// Keep generated units in the population — a drift audit, not a DRY sweep.
    include_generated: bool = false,
    /// Compare every pair instead of nominating through seed buckets. Sound
    /// either way; only worth it for a small exact-narrowed set, where the
    /// bucket pass can miss a pair the caller explicitly asked about.
    exhaustive: bool = false,

    /// Is `score` admitted on this channel?
    pub fn admits(self: Params, score: f64) bool {
        if (std.math.isNan(score)) return false;
        return switch (self.channel.polarity()) {
            .distance => score <= self.max_dist,
            .stronger => score >= self.min_echo,
        };
    }

    /// The admission threshold in force, whichever polarity it belongs to.
    pub fn floor(self: Params) f64 {
        return if (self.channel.polarity() == .stronger) self.min_echo else self.max_dist;
    }
};

/// One verified relation between two units (i < j), with both channels priced.
pub const Pair = struct {
    i: u32,
    j: u32,
    /// This channel's score — the one the answer is ordered by.
    score: f64,
    bytes: f64,
    structure: f64,
};

/// One fork family. `edge` is the LOOSEST admitted edge inside it (a family is
/// only as tight as its weakest link), `bytes`/`structure` that same worst
/// admitted edge priced in each channel — the pairs the family was actually
/// built from, not the transitive closure's diameter — and `repeated_lines` the
/// conservative consolidation opportunity: the smallest member's length times
/// the redundant copies.
pub const Family = struct {
    members: []u32,
    edge: f64,
    bytes: f64,
    structure: f64,
    repeated_lines: usize,
};

/// One unit with no kin, and the nearest thing that isn't kin — the receipt
/// that makes "genuinely distinct" a measurement instead of an absence.
pub const Lonely = struct {
    unit: u32,
    nearest: ?u32,
    bytes: f64,
    structure: f64,
};

pub const Report = struct {
    gpa: std.mem.Allocator,
    shape: Shape,
    pairs: []Pair = &.{},
    families: []Family = &.{},
    distinct: []Lonely = &.{},
    /// Units that passed the participation floor — the population "repeats"
    /// is relative to.
    candidates: usize = 0,
    /// Admitted relations, before grouping.
    edges: usize = 0,

    pub fn deinit(self: *Report) void {
        self.gpa.free(self.pairs);
        for (self.families) |f| self.gpa.free(f.members);
        self.gpa.free(self.families);
        self.gpa.free(self.distinct);
    }

    /// How many rows this report holds, whatever shape it is.
    pub fn rows(self: *const Report) usize {
        return switch (self.shape) {
            .pairs => self.pairs.len,
            .families => self.families.len,
            .distinct => self.distinct.len,
        };
    }
};

/// The plain file path of a `path#Lstart` label — the generated check keys on
/// the file, not the line anchor.
fn labelPath(label: []const u8) []const u8 {
    return if (std.mem.lastIndexOf(u8, label, "#L")) |at| label[0..at] else label;
}

/// Which units may take part: long enough, enough fingerprint mass for the
/// channel they'd be compared on, and authored (not codegen output). A
/// non-participant is never nominated and never joins a family.
pub fn participation(gpa: std.mem.Allocator, table: Table, params: Params) ![]bool {
    const ok = try gpa.alloc(bool, table.len());
    for (ok, 0..) |*o, i| {
        const id: u32 = @intCast(i);
        const long_enough = params.min_lines == 0 or
            (table.lines.len > i and table.lines[i] >= params.min_lines);
        const authored = params.include_generated or !signals.isGeneratedPath(labelPath(table.labels[i]));
        o.* = long_enough and authored and table.massy(params.channel, id, params.min_mass);
    }
    return ok;
}

/// Answer the repetition question in the requested shape. Caller owns the
/// result. Ordering is total in every shape, so two runs over the same bytes
/// print the same rows in the same order.
pub fn survey(gpa: std.mem.Allocator, table: Table, params: Params) !Report {
    const participates = try participation(gpa, table, params);
    defer gpa.free(participates);
    var candidates: usize = 0;
    for (participates) |p| candidates += @intFromBool(p);

    var edges = try admit(gpa, table, params, participates);
    defer edges.deinit(gpa);

    var report = Report{ .gpa = gpa, .shape = params.shape, .candidates = candidates, .edges = edges.items.len };
    switch (params.shape) {
        .pairs => {
            std.mem.sort(Pair, edges.items, Order{ .labels = table.labels, .stronger = params.channel.polarity() == .stronger }, Order.less);
            report.pairs = try edges.toOwnedSlice(gpa);
        },
        .families => report.families = try group(gpa, table, params, edges.items),
        .distinct => report.distinct = try isolated(gpa, table, participates, edges.items),
    }
    return report;
}

/// Total order over pairs: strongest first, then both labels — so a tie never
/// depends on hash iteration order.
const Order = struct {
    labels: []const []const u8,
    stronger: bool,

    fn less(self: Order, x: Pair, y: Pair) bool {
        if (x.score != y.score) return if (self.stronger) x.score > y.score else x.score < y.score;
        const c = std.mem.order(u8, self.labels[x.i], self.labels[y.i]);
        if (c != .eq) return c == .lt;
        return std.mem.order(u8, self.labels[x.j], self.labels[y.j]) == .lt;
    }
};

/// Nominate through the channel's own record, verify exactly, keep what the
/// threshold admits.
fn admit(
    gpa: std.mem.Allocator,
    table: Table,
    params: Params,
    participates: []const bool,
) !std.ArrayList(Pair) {
    var out: std.ArrayList(Pair) = .empty;
    errdefer out.deinit(gpa);

    const Ctx = struct {
        gpa: std.mem.Allocator,
        table: Table,
        params: Params,
        participates: []const bool,
        out: *std.ArrayList(Pair),

        fn visit(self: *@This(), a: u32, z: u32) error{OutOfMemory}!void {
            if (!self.participates[a] or !self.participates[z]) return;
            const s = self.table.priced(self.params, a, z) orelse return;
            try self.out.append(self.gpa, .{
                .i = @min(a, z),
                .j = @max(a, z),
                .score = s.score,
                .bytes = s.bytes,
                .structure = s.structure,
            });
        }
    };
    var ctx = Ctx{ .gpa = gpa, .table = table, .params = params, .participates = participates, .out = &out };

    if (params.exhaustive) {
        for (0..table.len()) |a|
            for (a + 1..table.len()) |z|
                try ctx.visit(@intCast(a), @intCast(z));
        return out;
    }
    // Nominate on the record the channel actually scores. `any` is close in
    // EITHER channel, so it needs both bucket passes and a dedup — a pair both
    // nominate would otherwise be reported twice.
    switch (params.channel) {
        .copies => try pairs_mod.forEachCandidatePair(Sketch, gpa, table.sketches, &ctx, Ctx.visit),
        .shapes, .twins => try pairs_mod.forEachCandidatePair(Silhouette, gpa, table.silhouettes, &ctx, Ctx.visit),
        .any => {
            try pairs_mod.forEachCandidatePair(Sketch, gpa, table.sketches, &ctx, Ctx.visit);
            try pairs_mod.forEachCandidatePair(Silhouette, gpa, table.silhouettes, &ctx, Ctx.visit);
            dedup(&out);
        },
        // Neither is a pairwise channel: no relation can be admitted.
        .recall, .context => {},
    }
    return out;
}

/// Drop duplicate (i,j) relations after a two-pass nomination. Both passes
/// price a pair identically, so keeping the first occurrence is exact.
fn dedup(list: *std.ArrayList(Pair)) void {
    const by_ids = struct {
        fn less(_: void, x: Pair, y: Pair) bool {
            return if (x.i != y.i) x.i < y.i else x.j < y.j;
        }
    }.less;
    std.mem.sort(Pair, list.items, {}, by_ids);
    var w: usize = 0;
    for (list.items, 0..) |p, r| {
        if (r > 0 and p.i == list.items[w - 1].i and p.j == list.items[w - 1].j) continue;
        list.items[w] = p;
        w += 1;
    }
    list.shrinkRetainingCapacity(w);
}

/// Union-find over the admitted edges, then materialize families ≥ `min_size`,
/// each priced by its worst ADMITTED edge in both channels. Ranked by the
/// consolidation opportunity — repeated lines when the unit has them, else
/// family size — so the top row is the biggest safe win rather than the highest
/// number.
///
/// A family is priced from the pairs that actually formed it, which is both the
/// honest reading and the only tractable one. A family is a transitive closure:
/// two members at opposite ends of a chain were never adjudicated as kin, so
/// scoring them as "the family's worst pair" reports a number no admission
/// decision ever stood behind, and inflates looseness with chain length. It is
/// also quadratic in a way the corpus does not survive — on this tree the
/// closure yields one 8,968-member component, whose all-pairs scan is 40.2M
/// distances (~17 s) for a row the deletion gate then discards. Every admitted
/// edge is already priced in both channels by `admit`, so the worst of them is
/// one O(edges) pass with no distance recomputed at all.
fn group(gpa: std.mem.Allocator, table: Table, params: Params, edges: []const Pair) ![]Family {
    const graph = try gpa.alloc(families_mod.Edge, edges.len);
    defer gpa.free(graph);
    for (edges, graph) |e, *g| g.* = .{ .i = e.i, .j = e.j, .w = e.score };
    // "Loosest" follows the polarity: a bigger distance is looser, a smaller
    // gap is looser.
    const dir: families_mod.EdgeDir = if (params.channel.polarity() == .stronger) .min else .max;
    const groups = try families_mod.components(gpa, table.labels, graph, dir, params.min_size);
    defer gpa.free(groups);

    // Member → the family it landed in, so one pass over the edges can price
    // every family at once. Members of a sub-`min_size` component map to
    // `unplaced` and their edges are skipped.
    const unplaced = std.math.maxInt(u32);
    const family_of = try gpa.alloc(u32, table.len());
    defer gpa.free(family_of);
    @memset(family_of, unplaced);
    for (groups, 0..) |g, fi| for (g.members) |m| {
        family_of[m] = @intCast(fi);
    };

    const worst = try gpa.alloc(Priced, groups.len);
    defer gpa.free(worst);
    @memset(worst, .{});
    for (edges) |e| {
        const fi = family_of[e.i];
        if (fi == unplaced) continue;
        worst[fi].widen(e);
    }

    const list = try gpa.alloc(Family, groups.len);
    var built: usize = 0;
    errdefer {
        for (list[0..built]) |f| gpa.free(f.members);
        gpa.free(list);
    }
    for (groups, worst, list) |g, w, *f| {
        f.* = summarize(table, g.members, g.edge, w);
        built += 1;
    }
    std.mem.sort(Family, list, table.labels, familyLess);
    return list;
}

/// The loosest admitted edge a family has seen in each channel, accumulated as
/// its edges stream past. A channel stays at its zero until a non-NaN edge
/// widens it, so an unresolved record reports 0.0 rather than poisoning the max.
const Priced = struct {
    bytes: f64 = 0.0,
    structure: f64 = 0.0,

    fn widen(self: *Priced, e: Pair) void {
        if (!std.math.isNan(e.bytes)) self.bytes = @max(self.bytes, e.bytes);
        if (!std.math.isNan(e.structure)) self.structure = @max(self.structure, e.structure);
    }
};

/// Family-level channel stats + opportunity. Both channel numbers arrive
/// already accumulated over the family's admitted edges (`group`); all this
/// adds is the conservative consolidation estimate, which is O(members).
fn summarize(table: Table, members: []u32, edge: f64, worst: Priced) Family {
    var shortest: u32 = std.math.maxInt(u32);
    for (members) |m| if (table.lines.len > m) {
        shortest = @min(shortest, table.lines[m]);
    };
    return .{
        .members = members,
        .edge = edge,
        .bytes = if (table.sketches.len == 0) std.math.nan(f64) else worst.bytes,
        .structure = if (table.silhouettes.len == 0) std.math.nan(f64) else worst.structure,
        .repeated_lines = if (shortest == std.math.maxInt(u32)) 0 else @as(usize, shortest) * (members.len - 1),
    };
}

/// Biggest safe consolidation first: repeated lines desc when the unit carries
/// them, else size desc; then exemplar label asc. Families own disjoint member
/// sets, so exemplars never tie — a total order.
fn familyLess(labels: []const []const u8, x: Family, y: Family) bool {
    if (x.repeated_lines != y.repeated_lines) return x.repeated_lines > y.repeated_lines;
    if (x.members.len != y.members.len) return x.members.len > y.members.len;
    return std.mem.order(u8, labels[x.members[0]], labels[y.members[0]]) == .lt;
}

/// The complement: participants no admitted edge touched, each with its nearest
/// miss. Exhaustive by construction — "nothing is close to this" is a claim
/// about every other unit, so it cannot be answered from seed buckets.
fn isolated(gpa: std.mem.Allocator, table: Table, participates: []const bool, edges: []const Pair) ![]Lonely {
    const connected = try gpa.alloc(bool, table.len());
    defer gpa.free(connected);
    @memset(connected, false);
    for (edges) |e| {
        connected[e.i] = true;
        connected[e.j] = true;
    }

    // The lonely units, in canonical order. Every one of them costs a full
    // sweep of the participating population, so this list — not the table — is
    // the work.
    var lonely: std.ArrayList(u32) = .empty;
    defer lonely.deinit(gpa);
    for (0..table.len()) |i| {
        if (connected[i] or !participates[i]) continue;
        try lonely.append(gpa, @intCast(i));
    }

    const out = try gpa.alloc(Lonely, lonely.items.len);
    errdefer gpa.free(out);
    // Each sweep reads shared immutable records and writes only its own row, so
    // the shards are independent and the answer is order-free. Two thresholds
    // gate the spawn: enough sweeps to divide, and enough population per sweep
    // that the scan dominates the thread cost.
    const population = table.len();
    const nthr = shardCount(lonely.items.len, population);
    if (nthr < 2) {
        for (lonely.items, out) |me, *row| row.* = nearestMiss(table, participates, me);
    } else {
        const shards = try gpa.alloc(MissShard, nthr);
        defer gpa.free(shards);
        const threads = try gpa.alloc(std.Thread, nthr);
        defer gpa.free(threads);
        // Equal sweep counts, because every sweep costs the same population
        // walk — the byte-greedy split the fingerprint passes use has nothing
        // to balance here.
        const per = (lonely.items.len + nthr - 1) / nthr;
        for (shards, 0..) |*sh, s| {
            const lo = @min(s * per, lonely.items.len);
            sh.* = .{
                .table = table,
                .participates = participates,
                .units = lonely.items[lo..@min(lo + per, lonely.items.len)],
                .out = out[lo..@min(lo + per, lonely.items.len)],
            };
        }
        parallel.fanOut(MissShard, shards, threads, MissShard.run);
    }
    std.mem.sort(Lonely, out, table.labels, lonelyLess);
    return out;
}

/// One contiguous run of lonely units and the rows they fill. Holds no
/// allocator: a shard only reads the shared table and writes its own slice.
const MissShard = struct {
    table: Table,
    participates: []const bool,
    units: []const u32,
    out: []Lonely,

    fn run(sh: *MissShard) void {
        for (sh.units, sh.out) |me, *row| row.* = nearestMiss(sh.table, sh.participates, me);
    }
};

/// How many shards the complement sweep earns, or `<2` to stay serial. The
/// work is `sweeps × population` comparisons rather than bytes, so the shared
/// byte floor doesn't apply; this is the same discipline against the quantity
/// that actually scales.
fn shardCount(sweeps: usize, population: usize) usize {
    if (sweeps *| population < min_comparisons) return 1;
    const cores = std.Thread.getCpuCount() catch 1;
    return @min(@min(cores, sweeps), parallel.max_shards);
}

/// Below this many pair comparisons the complement stays serial — thread spawn
/// costs more than the sweep saves.
const min_comparisons: usize = 1 << 16;

/// The nearest unit that is NOT kin to `me`, priced on both channels.
///
/// The channel the table can measure ranks the miss and the other breaks ties,
/// so the secondary is priced only for a candidate that could still win — once
/// a close miss is in hand most of the population is rejected on the primary
/// alone, which halves the cost of the one query shape that cannot be answered
/// from seed buckets.
///
/// That rejection is itself the bound: `primary ≤ best` is exactly the question
/// the bounded merge answers, and `best` only ever tightens as the sweep runs.
/// So each candidate is measured against the standing champion rather than
/// measured and then compared — a pair that cannot beat the incumbent abandons
/// its merge instead of completing one whose answer is discarded. An
/// unmeasurable pair answers null and is rejected, matching the total order
/// below (where the old `!(p <= best)` guard rejected its NaN).
fn nearestMiss(table: Table, participates: []const bool, me: u32) Lonely {
    const prefer_structure = table.silhouettes.len > 0;
    var nearest: ?u32 = null;
    var best_primary = std.math.inf(f64);
    var best_secondary = std.math.inf(f64);
    for (0..table.len()) |j| {
        const other: u32 = @intCast(j);
        if (other == me or !participates[j]) continue;
        const primary = (if (prefer_structure)
            table.structureWithin(me, other, best_primary)
        else
            table.bytesWithin(me, other, best_primary)) orelse continue;
        const secondary = if (prefer_structure) table.bytesAt(me, other) else table.structureAt(me, other);
        const closer = primary < best_primary or
            secondary < best_secondary or
            (secondary == best_secondary and nearest != null and
                std.mem.order(u8, table.labels[other], table.labels[nearest.?]) == .lt);
        if (closer) {
            nearest = other;
            best_primary = primary;
            best_secondary = secondary;
        }
    }
    const bytes = if (prefer_structure) best_secondary else best_primary;
    const structure = if (prefer_structure) best_primary else best_secondary;
    return .{
        .unit = me,
        .nearest = nearest,
        .bytes = if (nearest == null) 1.0 else bytes,
        .structure = if (nearest == null) 1.0 else structure,
    };
}

/// Least-related first — the most genuinely distinct unit leads.
fn lonelyLess(labels: []const []const u8, x: Lonely, y: Lonely) bool {
    const xs = if (std.math.isNan(x.structure)) x.bytes else x.structure;
    const ys = if (std.math.isNan(y.structure)) y.bytes else y.structure;
    if (xs != ys) return xs > ys;
    return std.mem.order(u8, labels[x.unit], labels[y.unit]) == .lt;
}

// ── tests ──────────────────────────────────────────────────────────────────

const t = std.testing;

/// Build a comparison table from inline bodies + labels, both channels filled.
const Fixture = struct {
    gpa: std.mem.Allocator,
    labels: [][]const u8,
    lines: []u32,
    sketches: []Sketch,
    silhouettes: []Silhouette,

    fn init(gpa: std.mem.Allocator, labels: []const []const u8, bodies: []const []const u8) !Fixture {
        const sk = try gpa.alloc(Sketch, bodies.len);
        const sil = try gpa.alloc(Silhouette, bodies.len);
        const ln = try gpa.alloc(u32, bodies.len);
        const lb = try gpa.alloc([]const u8, labels.len);
        for (bodies, sk, sil, ln) |b, *s, *h, *n| {
            s.* = try sketch_mod.build(gpa, b);
            h.* = try silhouette_mod.build(gpa, b);
            n.* = @intCast(std.mem.count(u8, b, "\n") + 1);
        }
        @memcpy(lb, labels);
        return .{ .gpa = gpa, .labels = lb, .lines = ln, .sketches = sk, .silhouettes = sil };
    }

    fn deinit(self: *Fixture) void {
        self.gpa.free(self.silhouettes);
        self.gpa.free(self.sketches);
        self.gpa.free(self.lines);
        self.gpa.free(self.labels);
    }

    fn table(self: *const Fixture) Table {
        return .{ .labels = self.labels, .lines = self.lines, .sketches = self.sketches, .silhouettes = self.silhouettes };
    }

    fn run(self: *const Fixture, params: Params) !Report {
        return survey(self.gpa, self.table(), params);
    }
};

// Small bodies: ~100 bytes each. These shed a real SILHOUETTE (10–14
// fingerprints) but a threadbare SKETCH (alpha 8, beta 2 min-hashes), so they
// exercise the structure channel and are correctly refused by any channel that
// reads bytes. That asymmetry is the calibration working — a 2-hash sketch
// cannot produce a byte distance worth printing — so the byte-reading channels
// get the `ample` pair below instead of a relaxed floor.
const alpha = "fn alpha(items: []Item) usize {\n  var total: usize = 0;\n  for (items) |it| total += it.size;\n  return total;\n}";
const beta = "fn beta(rows: []Row) usize {\n  var sum: usize = 0;\n  for (rows) |r| sum += r.width;\n  return sum;\n}";
const parser = "fn parse(text: []const u8) !Node {\n  var cur = try scanner.open(text);\n  defer cur.close();\n  return cur.build();\n}";

// Renamed twins with real records on BOTH channels (sketch 42/40, silhouette
// 31): one skeleton, disjoint vocabulary. Close in shape, far in bytes — which
// is the definition of the `twins` gap.
const ample =
    \\fn tally(items: []Item, cfg: Config) !usize {
    \\  var total: usize = 0;
    \\  var skipped: usize = 0;
    \\  for (items) |it| {
    \\    if (it.size == 0) {
    \\      skipped += 1;
    \\      continue;
    \\    }
    \\    if (it.size > cfg.ceiling) return error.TooWide;
    \\    total += it.size;
    \\  }
    \\  if (skipped > cfg.tolerance) return error.TooSparse;
    \\  return total;
    \\}
;
const ample_renamed =
    \\fn weigh(rows: []Row, opts: Options) !usize {
    \\  var sum: usize = 0;
    \\  var dropped: usize = 0;
    \\  for (rows) |r| {
    \\    if (r.width == 0) {
    \\      dropped += 1;
    \\      continue;
    \\    }
    \\    if (r.width > opts.maximum) return error.Overflowed;
    \\    sum += r.width;
    \\  }
    \\  if (dropped > opts.slack) return error.Underfilled;
    \\  return sum;
    \\}
;

test "one table, three shapes: pairs, families, and the distinct complement" {
    const gpa = t.allocator;
    // Two renamed twins and one unrelated parser — the same population the
    // retired `concepts` verb was calibrated on.
    var fx = try Fixture.init(gpa, &.{ "a.zig#L1", "b.zig#L1", "c.zig#L1" }, &.{ alpha, beta, parser });
    defer fx.deinit();
    const base = Params{ .channel = .shapes, .max_dist = 0.34, .min_lines = 3, .min_mass = silhouette_mass, .exhaustive = true };

    var as_pairs = try fx.run(base);
    defer as_pairs.deinit();
    try t.expectEqual(@as(usize, 1), as_pairs.pairs.len);
    try t.expectEqual(@as(u32, 0), as_pairs.pairs[0].i);
    try t.expectEqual(@as(u32, 1), as_pairs.pairs[0].j);
    // Both channels ride the row: the pair is close in shape, far in bytes.
    try t.expect(as_pairs.pairs[0].structure < as_pairs.pairs[0].bytes);

    var as_families = try fx.run(.{ .channel = .shapes, .shape = .families, .max_dist = 0.34, .min_lines = 3, .min_mass = silhouette_mass, .exhaustive = true });
    defer as_families.deinit();
    try t.expectEqual(@as(usize, 1), as_families.families.len);
    try t.expectEqualSlices(u32, &.{ 0, 1 }, as_families.families[0].members);
    // Conservative opportunity: the shorter member's 5 lines, once redundant.
    try t.expectEqual(@as(usize, 5), as_families.families[0].repeated_lines);

    // The complement names the parser and proves it: its nearest miss, priced.
    var as_distinct = try fx.run(.{ .channel = .shapes, .shape = .distinct, .max_dist = 0.34, .min_lines = 3, .min_mass = silhouette_mass, .exhaustive = true });
    defer as_distinct.deinit();
    try t.expectEqual(@as(usize, 1), as_distinct.distinct.len);
    try t.expectEqual(@as(u32, 2), as_distinct.distinct[0].unit);
    try t.expect(as_distinct.distinct[0].nearest != null);
    try t.expect(as_distinct.distinct[0].structure > 0.34);
}

test "the channel decides what repeats: shapes group, copies do not" {
    const gpa = t.allocator;
    var fx = try Fixture.init(gpa, &.{ "a.zig#L1", "b.zig#L1" }, &.{ ample, ample_renamed });
    defer fx.deinit();
    // Renamed twins share a skeleton…
    var shapes = try fx.run(.{ .channel = .shapes, .max_dist = 0.34, .exhaustive = true });
    defer shapes.deinit();
    try t.expectEqual(@as(usize, 1), shapes.pairs.len);
    // …but almost no bytes, so the copy-paste question correctly finds nothing.
    var copies = try fx.run(.{ .channel = .copies, .max_dist = 0.25, .exhaustive = true });
    defer copies.deinit();
    try t.expectEqual(@as(usize, 0), copies.pairs.len);
    // The twins channel is the gap between those two answers.
    var twins = try fx.run(.{ .channel = .twins, .min_echo = 0.15, .exhaustive = true });
    defer twins.deinit();
    try t.expectEqual(@as(usize, 1), twins.pairs.len);
    try t.expect(twins.pairs[0].score > 0.15);
}

test "generated units are out of a DRY sweep and back in for a drift audit" {
    const gpa = t.allocator;
    // Same body twice, one of them codegen output: verbatim duplication that a
    // refactor must not chase, because the template owns it.
    var fx = try Fixture.init(gpa, &.{ "hand/written.zig", "wire/thing_pb2.py" }, &.{ alpha, alpha });
    defer fx.deinit();
    var dry = try fx.run(.{ .channel = .copies, .max_dist = 0.25, .min_mass = 0, .exhaustive = true });
    defer dry.deinit();
    try t.expectEqual(@as(usize, 0), dry.pairs.len);
    try t.expectEqual(@as(usize, 1), dry.candidates); // only the authored file

    var audit = try fx.run(.{ .channel = .copies, .max_dist = 0.25, .min_mass = 0, .include_generated = true, .exhaustive = true });
    defer audit.deinit();
    try t.expectEqual(@as(usize, 1), audit.pairs.len);
    try t.expectEqual(@as(usize, 2), audit.candidates);
}

test "the mass floor drops the identical-stub storm without a byte re-read" {
    const gpa = t.allocator;
    // The measured noise: an 86-member family of one-line `__init__.py`
    // re-exports at distance 0.0000. Identical, and not a finding.
    const stub = "from .v1 import *\n";
    var fx = try Fixture.init(gpa, &.{ "a/__init__.py", "b/__init__.py", "c/__init__.py" }, &.{ stub, stub, stub });
    defer fx.deinit();
    var floored = try fx.run(.{ .channel = .copies, .shape = .families, .min_mass = sketch_mass, .exhaustive = true });
    defer floored.deinit();
    try t.expectEqual(@as(usize, 0), floored.families.len);
    try t.expectEqual(@as(usize, 0), floored.candidates);
    // With the floor lifted the arithmetic is still there for whoever wants it.
    var unfloored = try fx.run(.{ .channel = .copies, .shape = .families, .min_mass = 0, .exhaustive = true });
    defer unfloored.deinit();
    try t.expectEqual(@as(usize, 1), unfloored.families.len);
    try t.expectEqual(@as(usize, 3), unfloored.families[0].members.len);
}

test "the default mass floor follows the channel's record, not the unit's container" {
    const gpa = t.allocator;
    // A body substantial enough to fingerprint on either channel. With the
    // floor left unset, EVERY channel must reach the pair: indexing the floor
    // by unit meant a silhouette length (winnowed fingerprints, ~10s) was
    // compared against the sketch calibration (16 min-hashes), so the shapes
    // family of a file-unit sweep came back empty while copies over the same
    // bytes worked. Two calibrations, one selector — chosen on the wrong axis.
    var fx = try Fixture.init(gpa, &.{ "a.zig", "b.zig" }, &.{ ample, ample });
    defer fx.deinit();
    for ([_]Channel{ .copies, .shapes, .any }) |chan| {
        var d = try fx.run(.{ .channel = chan, .max_dist = 0.25, .exhaustive = true });
        defer d.deinit();
        try t.expectEqual(@as(usize, 2), d.candidates);
        try t.expectEqual(@as(usize, 1), d.pairs.len);
    }
    // And each floor is the one its own record is calibrated in.
    try t.expectEqual(sketch_mass, massFloor(.copies));
    try t.expectEqual(silhouette_mass, massFloor(.shapes));
    try t.expectEqual(silhouette_mass, massFloor(.twins));
    try t.expectEqual(@as(usize, 0), massFloor(.recall));
}

test "a channel that reads both records needs mass in both" {
    const gpa = t.allocator;
    // `any` and `twins` combine the two measurements, so a fat silhouette must
    // not carry a sketch too thin to have produced its own number: one bogus
    // 0.0 on either side propagates straight into the combined score.
    //
    // `alpha` is exactly that unit — silhouette 10 (over the structure floor of
    // 8), sketch 8 (under the byte floor of 16) — so the two identical copies
    // are a real structural pair and NOT an admissible byte pair. No synthetic
    // threshold: the default calibration does the discriminating.
    var fx = try Fixture.init(gpa, &.{ "a.zig", "b.zig" }, &.{ alpha, alpha });
    defer fx.deinit();
    var shapes = try fx.run(.{ .channel = .shapes, .max_dist = 0.25, .exhaustive = true });
    defer shapes.deinit();
    try t.expectEqual(@as(usize, 2), shapes.candidates);
    try t.expectEqual(@as(usize, 1), shapes.pairs.len);

    for ([_]Channel{ .any, .twins, .copies }) |chan| {
        var thin_bytes = try fx.run(.{ .channel = chan, .max_dist = 0.25, .exhaustive = true });
        defer thin_bytes.deinit();
        try t.expectEqual(@as(usize, 0), thin_bytes.candidates);
    }
}

test "the line floor drops the trivial-helper storm" {
    const gpa = t.allocator;
    const getter = "fn get(self) i32 {\n  return self.x;\n}";
    var fx = try Fixture.init(gpa, &.{ "a.zig#L1", "b.zig#L1", "c.zig#L1" }, &.{ getter, getter, getter });
    defer fx.deinit();
    var d = try fx.run(.{ .channel = .shapes, .shape = .families, .min_lines = 8, .min_mass = silhouette_mass, .exhaustive = true });
    defer d.deinit();
    try t.expectEqual(@as(usize, 0), d.families.len);
    try t.expectEqual(@as(usize, 0), d.candidates);
}

test "families rank by the biggest safe consolidation, priced by the worst pair" {
    const gpa = t.allocator;
    const big = "fn a(xs: []T) usize {\n  var n: usize = 0;\n  for (xs) |x| {\n    n += weigh(x);\n  }\n  return n;\n}";
    const small = "fn s(a: i32, b: i32) i32 {\n  const c = a + b;\n  const d = c * c;\n  log(d);\n  return d;\n}";
    var fx = try Fixture.init(gpa, &.{ "a.zig#L1", "b.zig#L1", "c.zig#L1", "d.zig#L1", "e.zig#L1" }, &.{ big, big, big, small, small });
    defer fx.deinit();
    var d = try fx.run(.{ .channel = .shapes, .shape = .families, .max_dist = 0.2, .min_lines = 5, .min_mass = silhouette_mass, .exhaustive = true });
    defer d.deinit();
    try t.expectEqual(@as(usize, 2), d.families.len);
    // 7 lines × 2 redundant copies beats 6 × 1.
    try t.expectEqual(@as(usize, 14), d.families[0].repeated_lines);
    try t.expectEqual(@as(usize, 3), d.families[0].members.len);
    try t.expectEqual(@as(usize, 6), d.families[1].repeated_lines);
}

// A transitive chain, built so the closure's endpoints share nothing: `chain_a`
// and `chain_b` share one half, `chain_b` and `chain_c` share the other, and
// `chain_a` vs `chain_c` have no block in common. Union-find still collapses all
// three into one family — which is what makes this the fixture where "worst
// admitted edge" and "worst member pair" give different answers.
const block_p =
    \\  const parsed_pa = try decode_pa(buffer_pa, cursor_pa);
    \\  const parsed_pb = try verify_pb(parsed_pa, checksum_pb);
    \\  const parsed_pc = try expand_pc(parsed_pb, dictionary_pc);
    \\  if (parsed_pc.width_pd > limit_pd) return error.WidePd;
    \\  var running_pe: usize = parsed_pc.width_pd + offset_pe;
    \\  running_pe += tail_pf(parsed_pc, running_pe, scale_pf);
    \\
;
const block_q =
    \\  const merged_qa = try gather_qa(stream_qa, window_qa);
    \\  const merged_qb = try flatten_qb(merged_qa, depth_qb);
    \\  const merged_qc = try reorder_qc(merged_qb, comparator_qc);
    \\  if (merged_qc.height_qd < floor_qd) return error.ShortQd;
    \\  var tally_qe: usize = merged_qc.height_qd * factor_qe;
    \\  tally_qe -= trim_qf(merged_qc, tally_qe, margin_qf);
    \\
;
const block_r =
    \\  const staged_ra = try admit_ra(payload_ra, quota_ra);
    \\  const staged_rb = try balance_rb(staged_ra, weighting_rb);
    \\  const staged_rc = try publish_rc(staged_rb, registry_rc);
    \\  if (staged_rc.depth_rd == sentinel_rd) return error.FlatRd;
    \\  var ledger_re: usize = staged_rc.depth_rd ^ salt_re;
    \\  ledger_re |= seal_rf(staged_rc, ledger_re, nonce_rf);
    \\
;
const block_s =
    \\  const routed_sa = try dispatch_sa(envelope_sa, lane_sa);
    \\  const routed_sb = try annotate_sb(routed_sa, provenance_sb);
    \\  const routed_sc = try compress_sc(routed_sb, codebook_sc);
    \\  if (routed_sc.girth_sd != expected_sd) return error.SkewSd;
    \\  var receipt_se: usize = routed_sc.girth_sd +% pepper_se;
    \\  receipt_se &= close_sf(routed_sc, receipt_se, epilogue_sf);
    \\
;
const chain_a = "fn one_a() !usize {\n" ++ block_p ++ block_q ++ "}";
const chain_b = "fn two_b() !usize {\n" ++ block_q ++ block_r ++ "}";
const chain_c = "fn three_c() !usize {\n" ++ block_r ++ block_s ++ "}";

test "a family is priced by its worst ADMITTED edge, not the closure's diameter" {
    const gpa = t.allocator;
    var fx = try Fixture.init(gpa, &.{ "a.zig#L1", "b.zig#L1", "c.zig#L1" }, &.{ chain_a, chain_b, chain_c });
    defer fx.deinit();
    const tbl = fx.table();

    // Calibrate off the fixture itself rather than three magic constants: a-b
    // and b-c are the links, a-c is the closure the chain manufactures.
    const d_ab = tbl.bytesAt(0, 1);
    const d_bc = tbl.bytesAt(1, 2);
    const d_ac = tbl.bytesAt(0, 2);
    const links = @max(d_ab, d_bc);
    try t.expect(d_ac > links); // the endpoints really are the far pair

    // A threshold that admits both links and refuses the closure.
    var d = try fx.run(.{ .channel = .copies, .shape = .families, .max_dist = links, .min_size = 3, .min_mass = 1, .exhaustive = true });
    defer d.deinit();
    try t.expectEqual(@as(usize, 1), d.families.len);
    try t.expectEqualSlices(u32, &.{ 0, 1, 2 }, d.families[0].members);

    // The contract: every number on the row came from an edge some admission
    // decision actually stood behind, so it cannot exceed the threshold. The
    // all-pairs reading would report `d_ac` here — a distance this run
    // explicitly REFUSED — and would grow with chain length forever.
    try t.expectEqual(links, d.families[0].bytes);
    try t.expect(d.families[0].bytes <= links);
    try t.expect(d.families[0].bytes < d_ac);
}

test "a same-name, different-implementation pair does not group" {
    const gpa = t.allocator;
    const migrate = "fn run(cfg: Config) !void {\n  const db = try open(cfg.dsn);\n  defer db.close();\n  try db.migrate();\n  try db.seed();\n}";
    const pump = "fn run(sig: Signal) void {\n  while (queue.pop()) |msg| {\n    dispatch(msg);\n  }\n  flush();\n}";
    var fx = try Fixture.init(gpa, &.{ "a.zig#L1", "b.zig#L1" }, &.{ migrate, pump });
    defer fx.deinit();
    var d = try fx.run(.{ .channel = .shapes, .shape = .families, .max_dist = 0.25, .min_lines = 3, .min_mass = silhouette_mass, .exhaustive = true });
    defer d.deinit();
    try t.expectEqual(@as(usize, 0), d.families.len);
}

test "the any channel reports a pair once, not once per nomination pass" {
    const gpa = t.allocator;
    // Identical bodies: both the byte buckets and the silhouette buckets
    // nominate this pair, and a naive union would print it twice.
    var fx = try Fixture.init(gpa, &.{ "a.zig", "b.zig" }, &.{ alpha, alpha });
    defer fx.deinit();
    var d = try survey(gpa, fx.table(), .{ .channel = .any, .max_dist = 0.25, .min_mass = 0 });
    defer d.deinit();
    try t.expectEqual(@as(usize, 1), d.pairs.len);
}

test "pair order is total and strongest-first in both polarities" {
    const labels = [_][]const u8{ "a", "b", "c" };
    const near = Pair{ .i = 0, .j = 1, .score = 0.10, .bytes = 0.10, .structure = 0.90 };
    const far = Pair{ .i = 0, .j = 2, .score = 0.80, .bytes = 0.80, .structure = 0.90 };
    const by_distance = Order{ .labels = &labels, .stronger = false };
    const by_gap = Order{ .labels = &labels, .stronger = true };
    try t.expect(Order.less(by_distance, near, far));
    try t.expect(Order.less(by_gap, far, near));
    try t.expect(!Order.less(by_distance, near, near)); // strict
    // A score tie falls back to labels, never to nomination order.
    const tie_ab = Pair{ .i = 0, .j = 1, .score = 0.5, .bytes = 0.5, .structure = 0.5 };
    const tie_bc = Pair{ .i = 1, .j = 2, .score = 0.5, .bytes = 0.5, .structure = 0.5 };
    try t.expect(Order.less(by_distance, tie_ab, tie_bc));
    try t.expect(!Order.less(by_distance, tie_bc, tie_ab));
}

test "recall is not a repetition channel and admits nothing" {
    const gpa = t.allocator;
    var fx = try Fixture.init(gpa, &.{ "a.zig", "b.zig" }, &.{ alpha, alpha });
    defer fx.deinit();
    var d = try survey(gpa, fx.table(), .{ .channel = .recall, .min_mass = 0 });
    defer d.deinit();
    try t.expectEqual(@as(usize, 0), d.pairs.len);
}
