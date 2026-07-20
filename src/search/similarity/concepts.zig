//! concepts — function-level concept discovery, the pure kernel.
//!
//! `relate clusters`/`echoes` answer "which FILES are forks?"; concepts answers
//! the finer question the agent actually asks: "which FUNCTIONS across this tree
//! are the same idea — the repeated engine, the duplicated JSON dump, the
//! copy-pasted validator — regardless of what they're named or which file they
//! live in?" The comparison unit is the function fragment (regions.extractAll),
//! not the file, so a 12-line helper cloned into six files surfaces as one
//! six-member family instead of hiding inside six unrelated files.
//!
//! Two shapes over one kernel:
//!   • DISCOVER (no query text) — group every fragment into families of
//!     theoretically-similar functions, ranked by the consolidation opportunity
//!     they represent.
//!   • RETRIEVE (query text) — rank fragments by structural kinship to the text,
//!     the "is THIS concept already implemented somewhere?" probe.
//!
//! Channels stay separate, never fused into one opaque score (the plan's
//! covenant): STRUCTURE (silhouette) is the default and the only channel needed
//! to nominate and group; BYTES (LZJD sketch) and ECHO (byte−structure gap, the
//! renamed-twin signal) are opt-in lenses whose sketches the driver computes
//! only for the fragments this kernel nominates (`byteTargets`) — never a
//! repo-wide byte pass. Ranking is by conservative repeated-line count then
//! channel confidence, so the top family is the biggest safe consolidation, not
//! the highest similarity number.
//!
//! Pure: no corpus, argv, stdout, or I/O. The driver resolves fragments (warm
//! `index/frag` fold or a live build), computes byte sketches for the nominated
//! set, and renders; this nominates, admits, groups, and ranks over arrays.

const std = @import("std");
const sketch = @import("sketch.zig");
const silhouette_mod = @import("silhouette.zig");
const pairs = @import("pairs.zig");
const families_mod = @import("families.zig");
const signals = @import("../rank/signals.zig");

const Sketch = sketch.Sketch;
const Silhouette = silhouette_mod.Silhouette;

/// A fragment needs at least this many structural fingerprints before its
/// silhouette is trustworthy enough to pair. This is a RELIABILITY floor, not a
/// recall floor — nomination already degrades gracefully to `min(seed_hashes,
/// len)` seeds, so a sparse fragment is still nominated; the danger is only a
/// near-empty silhouette whose Jaccard swings on one fingerprint. Consolidation
/// only ever trusts the near-identical regime (distance ≤ `max_dist`), where a
/// handful of fingerprints already estimate ~0 distance exactly, so the floor is
/// the winnow's shared-run width (gram+window−1) — the smallest structurally
/// meaningful unit — not the file-scale seed count. Functions are an order of
/// magnitude smaller than files; a five-line helper yields ~10 fingerprints and
/// is a legitimate consolidation target.
const min_mass = silhouette_mod.gram + silhouette_mod.window - 1;

/// Which kinship channel groups fragments. STRUCTURE (default, warm-only) uses
/// the silhouette; BYTES uses the LZJD sketch (near-verbatim clones); ECHO uses
/// the byte−structure gap (same shape, renamed vocabulary — Type-2 clones).
pub const Lens = enum { structure, bytes, echo };

/// The discovery knobs. `max_dist` admits a STRUCTURE/BYTES edge at distance ≤ T;
/// `min_echo` admits an ECHO edge at gap ≥ E. `min_lines` is the noise floor
/// (a fragment shorter than this cannot anchor a family — kills the two-line
/// getter storm); `min_size` is the smallest family emitted.
pub const Params = struct {
    lens: Lens = .structure,
    max_dist: f64 = 0.25,
    min_echo: f64 = 0.15,
    min_lines: usize = 5,
    min_size: usize = 2,
};

/// One discovered family: the member fragment ids (label-ascending), each
/// channel's LOOSEST distance across the family (NaN when a channel wasn't
/// measured under this lens), the conservative consolidatable line count, and
/// the lens's confidence in [0,1]. Channels are reported side by side — never
/// collapsed — so the reader judges the relation, not a black-box score.
pub const Family = struct {
    members: []u32,
    structure: f64,
    bytes: f64,
    echo: f64,
    repeated_lines: usize,
    confidence: f64,
};

pub const Discovery = struct {
    gpa: std.mem.Allocator,
    list: []Family,
    candidates: usize, // fragments that passed the participation floor
    edges: usize,

    pub fn deinit(self: *Discovery) void {
        for (self.list) |f| self.gpa.free(f.members);
        self.gpa.free(self.list);
    }
};

/// One retrieval hit: a fragment and its structure distance to the query text.
pub const Hit = struct { frag: u32, distance: f64 };

pub const Ranked = struct {
    gpa: std.mem.Allocator,
    hits: []Hit,

    pub fn deinit(self: *Ranked) void {
        self.gpa.free(self.hits);
    }
};

/// The plain file path of a `path#Lstart` label (the generated-path check keys
/// on the file, not the line anchor) — the same split `compose/family` uses.
fn labelPath(label: []const u8) []const u8 {
    return if (std.mem.lastIndexOf(u8, label, "#L")) |at| label[0..at] else label;
}

/// The participation floor per fragment: long enough (`min_lines`), enough
/// structural mass for a trustworthy silhouette, and not from a generated file
/// (codegen twins are not consolidation opportunities). A non-participant is
/// never nominated and never joins a family. Caller frees.
pub fn participation(
    gpa: std.mem.Allocator,
    labels: []const []const u8,
    lines: []const u32,
    silhouettes: []const Silhouette,
    params: Params,
) ![]bool {
    const ok = try gpa.alloc(bool, labels.len);
    for (labels, lines, silhouettes, ok) |label, n, *sil, *o|
        o.* = n >= params.min_lines and sil.len >= min_mass and !signals.isGeneratedPath(labelPath(label));
    return ok;
}

/// The fragments a BYTES/ECHO lens must sketch: every endpoint of a nominated
/// structural candidate pair between two participants. Byte sketches are needed
/// only to VERIFY these — never the whole corpus — so the driver reads exactly
/// this set's live bytes. Returns a participant-length involvement mask; caller
/// frees.
pub fn byteTargets(
    gpa: std.mem.Allocator,
    silhouettes: []const Silhouette,
    participates: []const bool,
) ![]bool {
    const involved = try gpa.alloc(bool, silhouettes.len);
    errdefer gpa.free(involved);
    @memset(involved, false);
    const Ctx = struct {
        participates: []const bool,
        involved: []bool,
        fn visit(self: *@This(), a: u32, z: u32) error{OutOfMemory}!void {
            if (!self.participates[a] or !self.participates[z]) return;
            self.involved[a] = true;
            self.involved[z] = true;
        }
    };
    var ctx = Ctx{ .participates = participates, .involved = involved };
    try pairs.forEachCandidatePair(Silhouette, gpa, silhouettes, &ctx, Ctx.visit);
    return involved;
}

/// Group fragments into families of theoretically-similar functions. `labels`
/// (`path#Lstart`) give the deterministic order and the generated-file check;
/// `lines` the per-fragment line count; `silhouettes` the structure channel
/// (always). `sketches` is the byte channel: empty for STRUCTURE, else a
/// fragment-length array with `byteTargets` entries filled (others `.empty`).
/// `participates` is `participation(...)`, computed once by the driver. Caller
/// owns the result.
pub fn discover(
    gpa: std.mem.Allocator,
    labels: []const []const u8,
    lines: []const u32,
    silhouettes: []const Silhouette,
    sketches: []const Sketch,
    participates: []const bool,
    params: Params,
) !Discovery {
    var candidates: usize = 0;
    for (participates) |p| candidates += @intFromBool(p);

    var edges: std.ArrayList(families_mod.Edge) = .empty;
    defer edges.deinit(gpa);
    const Ctx = struct {
        gpa: std.mem.Allocator,
        participates: []const bool,
        silhouettes: []const Silhouette,
        sketches: []const Sketch,
        params: Params,
        edges: *std.ArrayList(families_mod.Edge),

        fn visit(self: *@This(), a: u32, z: u32) error{OutOfMemory}!void {
            if (!self.participates[a] or !self.participates[z]) return;
            const ds = silhouette_mod.distance(&self.silhouettes[a], &self.silhouettes[z]);
            switch (self.params.lens) {
                .structure => if (ds <= self.params.max_dist)
                    try self.edges.append(self.gpa, .{ .i = a, .j = z, .w = ds }),
                .bytes => {
                    const db = sketch.distance(&self.sketches[a], &self.sketches[z]);
                    if (db <= self.params.max_dist) try self.edges.append(self.gpa, .{ .i = a, .j = z, .w = db });
                },
                .echo => {
                    const db = sketch.distance(&self.sketches[a], &self.sketches[z]);
                    const gap = db - ds;
                    if (gap >= self.params.min_echo) try self.edges.append(self.gpa, .{ .i = a, .j = z, .w = gap });
                },
            }
        }
    };
    var ctx = Ctx{ .gpa = gpa, .participates = participates, .silhouettes = silhouettes, .sketches = sketches, .params = params, .edges = &edges };
    try pairs.forEachCandidatePair(Silhouette, gpa, silhouettes, &ctx, Ctx.visit);

    const dir: families_mod.EdgeDir = if (params.lens == .echo) .min else .max;
    const groups = try families_mod.components(gpa, labels, edges.items, dir, params.min_size);
    defer gpa.free(groups);

    const list = try gpa.alloc(Family, groups.len);
    var built: usize = 0;
    errdefer {
        for (list[0..built]) |f| gpa.free(f.members);
        gpa.free(list);
    }
    for (groups, list) |g, *f| {
        f.* = summarize(g.members, lines, silhouettes, sketches, params.lens);
        built += 1;
    }
    return .{ .gpa = gpa, .list = list, .candidates = candidates, .edges = edges.items.len };
}

/// Family-level channel stats + opportunity. Members are few (2–~6), so the
/// O(k²) loosest-distance scan is cheap and honest: it reports the WORST pair in
/// each channel, not a single edge's number. `repeated_lines` is conservative —
/// the smallest member's length is the safely-consolidatable size, times the
/// redundant copies. Confidence is the lens's own channel, clamped to [0,1].
fn summarize(members: []u32, lines: []const u32, silhouettes: []const Silhouette, sketches: []const Sketch, lens: Lens) Family {
    var min_lines: u32 = std.math.maxInt(u32);
    for (members) |m| min_lines = @min(min_lines, lines[m]);

    var worst_structure: f64 = 0.0;
    var worst_bytes: f64 = 0.0;
    var min_echo: f64 = std.math.inf(f64);
    const measure_bytes = lens != .structure;
    for (members, 0..) |a, ai| for (members[ai + 1 ..]) |b| {
        const ds = silhouette_mod.distance(&silhouettes[a], &silhouettes[b]);
        worst_structure = @max(worst_structure, ds);
        if (measure_bytes) {
            const db = sketch.distance(&sketches[a], &sketches[b]);
            worst_bytes = @max(worst_bytes, db);
            min_echo = @min(min_echo, db - ds);
        }
    };

    const nan = std.math.nan(f64);
    const confidence = switch (lens) {
        .structure => 1.0 - worst_structure,
        .bytes => 1.0 - worst_bytes,
        .echo => std.math.clamp(min_echo, 0.0, 1.0),
    };
    return .{
        .members = members,
        .structure = worst_structure,
        .bytes = if (measure_bytes) worst_bytes else nan,
        .echo = if (lens == .echo) min_echo else nan,
        .repeated_lines = @as(usize, min_lines) * (members.len - 1),
        .confidence = confidence,
    };
}

/// Rank families for `--top`: biggest safe consolidation first (repeated lines
/// desc), then channel confidence desc, then exemplar label asc — a total order
/// (families own disjoint member sets, so exemplars never tie). Sorts in place.
pub fn rank(list: []Family, labels: []const []const u8) void {
    const Cmp = struct {
        labels: []const []const u8,
        fn less(self: @This(), x: Family, y: Family) bool {
            if (x.repeated_lines != y.repeated_lines) return x.repeated_lines > y.repeated_lines;
            if (x.confidence != y.confidence) return x.confidence > y.confidence;
            return std.mem.order(u8, self.labels[x.members[0]], self.labels[y.members[0]]) == .lt;
        }
    };
    std.mem.sort(Family, list, Cmp{ .labels = labels }, Cmp.less);
}

/// Retrieve the fragments most structurally similar to `query` (built from the
/// user's TEXT), nearest first. Only participants (min_lines + mass, not
/// generated) are ranked. Ties break on label for a stable order. Caller frees.
pub fn retrieve(
    gpa: std.mem.Allocator,
    labels: []const []const u8,
    silhouettes: []const Silhouette,
    participates: []const bool,
    query: *const Silhouette,
    top: usize,
) !Ranked {
    var hits: std.ArrayList(Hit) = .empty;
    errdefer hits.deinit(gpa);
    for (silhouettes, 0..) |*sil, i| {
        if (!participates[i]) continue;
        try hits.append(gpa, .{ .frag = @intCast(i), .distance = silhouette_mod.distance(query, sil) });
    }
    const Cmp = struct {
        labels: []const []const u8,
        fn less(self: @This(), x: Hit, y: Hit) bool {
            if (x.distance != y.distance) return x.distance < y.distance;
            return std.mem.order(u8, self.labels[x.frag], self.labels[y.frag]) == .lt;
        }
    };
    std.mem.sort(Hit, hits.items, Cmp{ .labels = labels }, Cmp.less);
    if (hits.items.len > top) hits.shrinkRetainingCapacity(top);
    return .{ .gpa = gpa, .hits = try hits.toOwnedSlice(gpa) };
}

// ── tests ──────────────────────────────────────────────────────────────────

const t = std.testing;

/// Build the (labels, lines, silhouettes) arrays a test needs from inline
/// fragment bodies + labels.
const Fixture = struct {
    gpa: std.mem.Allocator,
    labels: [][]const u8,
    lines: []u32,
    silhouettes: []Silhouette,

    fn init(gpa: std.mem.Allocator, labels: []const []const u8, bodies: []const []const u8) !Fixture {
        const sils = try gpa.alloc(Silhouette, bodies.len);
        const lns = try gpa.alloc(u32, bodies.len);
        const lbls = try gpa.alloc([]const u8, labels.len);
        for (bodies, sils, lns) |b, *s, *n| {
            s.* = try silhouette_mod.build(gpa, b);
            n.* = @intCast(std.mem.count(u8, b, "\n") + 1);
        }
        @memcpy(lbls, labels);
        return .{ .gpa = gpa, .labels = lbls, .lines = lns, .silhouettes = sils };
    }
    fn deinit(self: *Fixture) void {
        self.gpa.free(self.silhouettes);
        self.gpa.free(self.lines);
        self.gpa.free(self.labels);
    }
    fn run(self: *Fixture, params: Params) !Discovery {
        const part = try participation(self.gpa, self.labels, self.lines, self.silhouettes, params);
        defer self.gpa.free(part);
        const d = try discover(self.gpa, self.labels, self.lines, self.silhouettes, &.{}, part, params);
        rank(d.list, self.labels);
        return d;
    }
};

test "concepts: renamed twins group; the genuinely distinct function stays out" {
    const gpa = t.allocator;
    // Two structurally-identical bodies under different names/vars (a renamed
    // twin), and one function that shares neither shape nor purpose.
    const bodies = [_][]const u8{
        "fn alpha(items: []Item) usize {\n  var total: usize = 0;\n  for (items) |it| total += it.size;\n  return total;\n}",
        "fn beta(rows: []Row) usize {\n  var sum: usize = 0;\n  for (rows) |r| sum += r.width;\n  return sum;\n}",
        "fn parse(text: []const u8) !Node {\n  var cur = try scanner.open(text);\n  defer cur.close();\n  return cur.build();\n}",
    };
    const labels = [_][]const u8{ "a.zig#L1", "b.zig#L1", "c.zig#L1" };
    var fx = try Fixture.init(gpa, &labels, &bodies);
    defer fx.deinit();
    var d = try fx.run(.{ .lens = .structure, .max_dist = 0.34, .min_lines = 3 });
    defer d.deinit();

    try t.expectEqual(@as(usize, 1), d.list.len);
    try t.expectEqualSlices(u32, &.{ 0, 1 }, d.list[0].members);
    // The parser (frag 2) is not a member of any family.
    try t.expect(d.list[0].members.len == 2);
}

test "concepts: the tiny-helper noise floor drops short fragments" {
    const gpa = t.allocator;
    const two = "fn get(self) i32 {\n  return self.x;\n}"; // 3 lines, trivial
    const bodies = [_][]const u8{ two, two, two };
    const labels = [_][]const u8{ "a.zig#L1", "b.zig#L1", "c.zig#L1" };
    var fx = try Fixture.init(gpa, &labels, &bodies);
    defer fx.deinit();
    // min_lines 8 excludes every fragment → no families, no crash.
    var d = try fx.run(.{ .lens = .structure, .min_lines = 8 });
    defer d.deinit();
    try t.expectEqual(@as(usize, 0), d.list.len);
    try t.expectEqual(@as(usize, 0), d.candidates);
}

test "concepts: a same-name/different-implementation pair does not group" {
    const gpa = t.allocator;
    const bodies = [_][]const u8{
        "fn run(cfg: Config) !void {\n  const db = try open(cfg.dsn);\n  defer db.close();\n  try db.migrate();\n  try db.seed();\n}",
        "fn run(sig: Signal) void {\n  while (queue.pop()) |msg| {\n    dispatch(msg);\n  }\n  flush();\n}",
    };
    const labels = [_][]const u8{ "a.zig#L1", "b.zig#L1" };
    var fx = try Fixture.init(gpa, &labels, &bodies);
    defer fx.deinit();
    var d = try fx.run(.{ .lens = .structure, .max_dist = 0.25, .min_lines = 3 });
    defer d.deinit();
    try t.expectEqual(@as(usize, 0), d.list.len);
}

test "concepts: ranking puts the bigger consolidation first" {
    const gpa = t.allocator;
    // Family A: three identical 7-line bodies (the bigger opportunity). Family
    // B: two identical 6-line bodies — both clear the noise floor, so ranking,
    // not participation, decides the order.
    const big = "fn a(xs: []T) usize {\n  var n: usize = 0;\n  for (xs) |x| {\n    n += weigh(x);\n  }\n  return n;\n}";
    const small = "fn s(a: i32, b: i32) i32 {\n  const c = a + b;\n  const d = c * c;\n  log(d);\n  return d;\n}";
    const bodies = [_][]const u8{ big, big, big, small, small };
    const labels = [_][]const u8{ "a.zig#L1", "b.zig#L1", "c.zig#L1", "d.zig#L1", "e.zig#L1" };
    var fx = try Fixture.init(gpa, &labels, &bodies);
    defer fx.deinit();
    var d = try fx.run(.{ .lens = .structure, .max_dist = 0.2, .min_lines = 5 });
    defer d.deinit();
    try t.expectEqual(@as(usize, 2), d.list.len);
    // A: repeated_lines = 7 * 2 = 14; B: 6 * 1 = 6 → A ranks first.
    try t.expect(d.list[0].repeated_lines > d.list[1].repeated_lines);
    try t.expectEqual(@as(usize, 3), d.list[0].members.len);
}
