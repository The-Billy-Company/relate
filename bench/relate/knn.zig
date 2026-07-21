//! relate — the compression-as-embedding proof harness (`zig build relate-knn`).
//!
//! The thesis (Griffin's idea): *embeddings answer "what is this LIKE?",
//! but compression answers it faster and with no model.* This harness proves
//! the cheapest rung — it runs the REAL relate engine as a k-NN text
//! classifier over a labeled corpus and reports accuracy + build/query cost,
//! so a sibling Python driver can race it head-to-head against the gzip-kNN
//! method (Jiang et al., ACL 2023) and a real static-embedding model.
//!
//! Two faithful lanes, both the production code (no re-implementation):
//!
//!   zipper  the precision engine — one suffix automaton per train doc is the
//!           "index"; each test doc is priced by an exact Ziv–Merhav cross-parse
//!           (zipper.crossParse). Distance = conditional description length /
//!           cold length ∈ (0,1]; lower = the train doc describes it more cheaply.
//!   sketch  the LZJD dictionary sketch (src/kernel/kinship/metric/sketch.zig) — the same
//!           distance `relate similar`/`dups` ride; cruder, but O(k) per pair.
//!
//! Input is a manifest the driver writes (deterministic order, so the harness
//! never walks a coworker-mutated tree): `<dataset>/manifest.tsv`, one row
//!   <split>\t<label_id>\t<relpath>
//! with split ∈ {train,test}. Every doc is pre-truncated to a uniform byte cap
//! by the driver, so ALL lanes (this one, gzip, embeddings) price identical
//! bytes. Result is one JSON object on stdout; diagnostics on stderr.

const std = @import("std");
const irregex = @import("irregex");

const zipper = irregex.relate.zipper;
const sketch = irregex.api.relate.sketch;

const Dir = std.Io.Dir;

fn die(comptime msg: []const u8, args: anytype) noreturn {
    std.debug.print(msg, args);
    std.process.exit(2);
}

fn nowNs(io: std.Io) i128 {
    return std.Io.Clock.now(.awake, io).nanoseconds;
}

fn ms(ns: i128) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

/// One labeled document, bytes arena-owned.
const Doc = struct { bytes: []const u8, label: u32 };

/// A (distance, label) candidate for the k-NN vote, sorted ascending by dist.
const Cand = struct {
    dist: f64,
    label: u32,
    fn before(_: void, a: Cand, b: Cand) bool {
        return a.dist < b.dist;
    }
};

const Method = enum { zipper, sketch, pivot };

const Dataset = struct {
    train: []Doc,
    tests: []Doc,
    n_labels: u32,
    train_bytes: u64,
    test_bytes: u64,
    arena: std.heap.ArenaAllocator,

    fn deinit(self: *Dataset) void {
        self.arena.deinit();
    }
};

/// Read `<dataset>/manifest.tsv` and every doc it names into one arena.
fn loadDataset(gpa: std.mem.Allocator, io: std.Io, dataset_dir: []const u8) !Dataset {
    var arena = std.heap.ArenaAllocator.init(gpa);
    const a = arena.allocator();

    const manifest_path = try std.fmt.allocPrint(a, "{s}/manifest.tsv", .{dataset_dir});
    const manifest = Dir.cwd().readFileAlloc(io, manifest_path, a, .limited(64 << 20)) catch
        die("cannot read manifest {s}\n", .{manifest_path});

    var train: std.ArrayList(Doc) = .empty;
    var tests: std.ArrayList(Doc) = .empty;
    var n_labels: u32 = 0;
    var train_bytes: u64 = 0;
    var test_bytes: u64 = 0;

    var lines = std.mem.splitScalar(u8, manifest, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var f = std.mem.splitScalar(u8, line, '\t');
        const split = f.next() orelse continue;
        const label_s = f.next() orelse die("manifest row missing label: {s}\n", .{line});
        const rel = f.next() orelse die("manifest row missing path: {s}\n", .{line});
        const label = std.fmt.parseInt(u32, label_s, 10) catch die("bad label {s}\n", .{label_s});
        n_labels = @max(n_labels, label + 1);

        const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ dataset_dir, rel });
        const bytes = Dir.cwd().readFileAlloc(io, path, a, .limited(4 << 20)) catch
            die("cannot read doc {s}\n", .{path});

        if (std.mem.eql(u8, split, "train")) {
            try train.append(a, .{ .bytes = bytes, .label = label });
            train_bytes += bytes.len;
        } else if (std.mem.eql(u8, split, "test")) {
            try tests.append(a, .{ .bytes = bytes, .label = label });
            test_bytes += bytes.len;
        } else die("bad split {s}\n", .{split});
    }
    return .{
        .train = train.items,
        .tests = tests.items,
        .n_labels = n_labels,
        .train_bytes = train_bytes,
        .test_bytes = test_bytes,
        .arena = arena,
    };
}

/// Plurality vote over the k nearest (scratch already sorted ascending by
/// distance). Ties break toward the nearest neighbor: the first label in
/// distance order that reaches the max count wins.
fn vote(scratch: []const Cand, k: usize, counts: []u32) u32 {
    @memset(counts, 0);
    const kk = @min(k, scratch.len);
    for (scratch[0..kk]) |c| counts[c.label] += 1;
    var max_count: u32 = 0;
    for (scratch[0..kk]) |c| max_count = @max(max_count, counts[c.label]);
    for (scratch[0..kk]) |c| {
        if (counts[c.label] == max_count) return c.label;
    }
    return scratch[0].label;
}

/// The zipper lane: build one automaton per train doc (the index), then price
/// each test doc against every train automaton by exact cross-parse.
fn runZipper(gpa: std.mem.Allocator, io: std.Io, ds: *const Dataset, k: usize) !Result {
    const build_t0 = nowNs(io);
    const autos = try gpa.alloc(zipper.Automaton, ds.train.len);
    defer {
        for (autos) |*x| x.deinit();
        gpa.free(autos);
    }
    for (ds.train, autos) |doc, *au| au.* = try zipper.Automaton.build(gpa, doc.bytes);
    const build_ns = nowNs(io) - build_t0;

    const scratch = try gpa.alloc(Cand, ds.train.len);
    defer gpa.free(scratch);
    const counts = try gpa.alloc(u32, ds.n_labels);
    defer gpa.free(counts);

    const q_t0 = nowNs(io);
    var correct: usize = 0;
    for (ds.tests) |q| {
        const cold = zipper.coldBits(q.bytes);
        for (autos, ds.train, scratch) |*au, tr, *s| {
            const cost = au.crossParse(q.bytes).bits;
            s.* = .{ .dist = if (cold > 0.0) cost / cold else 1.0, .label = tr.label };
        }
        std.mem.sort(Cand, scratch, {}, Cand.before);
        if (vote(scratch, k, counts) == q.label) correct += 1;
    }
    const query_ns = nowNs(io) - q_t0;
    return .{ .correct = correct, .build_ns = build_ns, .query_ns = query_ns };
}

/// The sketch lane: one LZJD sketch per train doc, then bottom-k Jaccard
/// distance per test doc.
fn runSketch(gpa: std.mem.Allocator, io: std.Io, ds: *const Dataset, k: usize) !Result {
    const build_t0 = nowNs(io);
    const sks = try gpa.alloc(sketch.Sketch, ds.train.len);
    defer gpa.free(sks);
    for (ds.train, sks) |doc, *sk| sk.* = try sketch.build(gpa, doc.bytes);
    const build_ns = nowNs(io) - build_t0;

    const scratch = try gpa.alloc(Cand, ds.train.len);
    defer gpa.free(scratch);
    const counts = try gpa.alloc(u32, ds.n_labels);
    defer gpa.free(counts);

    const q_t0 = nowNs(io);
    var correct: usize = 0;
    for (ds.tests) |q| {
        var qsk = try sketch.build(gpa, q.bytes);
        for (sks, ds.train, scratch) |*sk, tr, *s|
            s.* = .{ .dist = sketch.distance(&qsk, sk), .label = tr.label };
        std.mem.sort(Cand, scratch, {}, Cand.before);
        if (vote(scratch, k, counts) == q.label) correct += 1;
    }
    const query_ns = nowNs(io) - q_t0;
    return .{ .correct = correct, .build_ns = build_ns, .query_ns = query_ns };
}

/// The pivot lane — compression embeddings (FastMap/Lipschitz, Faloutsos & Lin
/// 1995). Pick P train docs as pivots; represent every doc as the P-vector of
/// its normalized cross-parse cost to each pivot. Compression distance becomes
/// a genuine vector space: build is N×P cross-parses (P≪N), then k-NN is cheap
/// Euclidean vector math — the online query embeds one doc (P cross-parses),
/// not N. This is the bridge that gives compression embedding-like query speed
/// while staying model-free and training-free.
fn embedByPivots(gpa: std.mem.Allocator, autos: []const zipper.Automaton, doc: []const u8) ![]f64 {
    const cold = zipper.coldBits(doc);
    const v = try gpa.alloc(f64, autos.len);
    for (autos, v) |*au, *coord| {
        const cost = au.crossParse(doc).bits;
        coord.* = if (cold > 0.0) cost / cold else 1.0;
    }
    return v;
}

fn euclid(a: []const f64, b: []const f64) f64 {
    var s: f64 = 0.0;
    for (a, b) |x, y| s += (x - y) * (x - y);
    return s; // monotone in true distance — no sqrt needed for k-NN ordering
}

fn runPivot(gpa: std.mem.Allocator, io: std.Io, ds: *const Dataset, k: usize, n_pivots: usize) !Result {
    const p = @min(n_pivots, ds.train.len);
    const build_t0 = nowNs(io);
    // Evenly-spaced pivots across the (shuffled) train order — a cheap spread
    // over the label mix without peeking at labels.
    const pivots = try gpa.alloc(zipper.Automaton, p);
    defer {
        for (pivots) |*x| x.deinit();
        gpa.free(pivots);
    }
    const stride = @max(ds.train.len / p, 1);
    for (pivots, 0..) |*au, i| au.* = try zipper.Automaton.build(gpa, ds.train[i * stride].bytes);

    // Embed the whole train set into pivot space (this + pivots = the index).
    const train_vecs = try gpa.alloc(f64, ds.train.len * p);
    defer gpa.free(train_vecs);
    for (ds.train, 0..) |doc, i| {
        const v = try embedByPivots(gpa, pivots, doc.bytes);
        defer gpa.free(v);
        @memcpy(train_vecs[i * p ..][0..p], v);
    }
    const build_ns = nowNs(io) - build_t0;

    const scratch = try gpa.alloc(Cand, ds.train.len);
    defer gpa.free(scratch);
    const counts = try gpa.alloc(u32, ds.n_labels);
    defer gpa.free(counts);

    const q_t0 = nowNs(io);
    var correct: usize = 0;
    for (ds.tests) |q| {
        const qv = try embedByPivots(gpa, pivots, q.bytes); // the online cost: P cross-parses
        defer gpa.free(qv);
        for (0..ds.train.len) |i|
            scratch[i] = .{ .dist = euclid(qv, train_vecs[i * p ..][0..p]), .label = ds.train[i].label };
        std.mem.sort(Cand, scratch, {}, Cand.before);
        if (vote(scratch, k, counts) == q.label) correct += 1;
    }
    const query_ns = nowNs(io) - q_t0;
    return .{ .correct = correct, .build_ns = build_ns, .query_ns = query_ns };
}

const Result = struct { correct: usize, build_ns: i128, query_ns: i128 };

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.skip(); // argv[0]

    var dataset_dir: ?[]const u8 = null;
    var method: Method = .zipper;
    var k: usize = 3;
    var n_pivots: usize = 64;
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--method")) {
            const m = it.next() orelse die("--method needs zipper|sketch|pivot\n", .{});
            method = std.meta.stringToEnum(Method, m) orelse die("--method: zipper|sketch|pivot, not {s}\n", .{m});
        } else if (std.mem.eql(u8, arg, "--k")) {
            const s = it.next() orelse die("--k needs a number\n", .{});
            k = std.fmt.parseInt(usize, s, 10) catch die("--k: bad number {s}\n", .{s});
        } else if (std.mem.eql(u8, arg, "--pivots")) {
            const s = it.next() orelse die("--pivots needs a number\n", .{});
            n_pivots = std.fmt.parseInt(usize, s, 10) catch die("--pivots: bad number {s}\n", .{s});
        } else if (dataset_dir == null) {
            dataset_dir = arg;
        } else die("unexpected arg {s}\n", .{arg});
    }
    const dir = dataset_dir orelse die("usage: relate-knn <dataset_dir> [--method zipper|sketch|pivot] [--k N] [--pivots P]\n", .{});

    var ds = try loadDataset(gpa, io, dir);
    defer ds.deinit();
    if (ds.train.len == 0 or ds.tests.len == 0) die("empty train/test set\n", .{});

    const r = switch (method) {
        .zipper => try runZipper(gpa, io, &ds, k),
        .sketch => try runSketch(gpa, io, &ds, k),
        .pivot => try runPivot(gpa, io, &ds, k, n_pivots),
    };

    const acc = @as(f64, @floatFromInt(r.correct)) / @as(f64, @floatFromInt(ds.tests.len));
    const per_us = ms(r.query_ns) * 1000.0 / @as(f64, @floatFromInt(ds.tests.len));
    const report_pivots: usize = if (method == .pivot) @min(n_pivots, ds.train.len) else 0;
    var buf: [1024]u8 = undefined;
    const json = std.fmt.bufPrint(&buf,
        \\{{"lane":"relate-{s}","k":{d},"pivots":{d},"n_train":{d},"n_test":{d},"n_labels":{d},"accuracy":{d:.4},"build_ms":{d:.1},"query_ms":{d:.1},"per_query_us":{d:.1},"train_bytes":{d},"test_bytes":{d}}}
    ++ "\n", .{
        @tagName(method), k,             report_pivots,  ds.train.len,   ds.tests.len,
        ds.n_labels,      acc,           ms(r.build_ns), ms(r.query_ns), per_us,
        ds.train_bytes,   ds.test_bytes,
    }) catch die("format overflow\n", .{});

    var off: usize = 0;
    while (off < json.len) {
        const n = std.posix.system.write(1, json.ptr + off, json.len - off);
        if (n <= 0) break;
        off += @intCast(n);
    }
    std.debug.print("relate-knn {s} k={d}: acc {d:.4} · build {d:.0}ms · query {d:.0}ms ({d:.1}µs/doc) · {d} train / {d} test\n", .{
        @tagName(method), k, acc, ms(r.build_ns), ms(r.query_ns), per_us, ds.train.len, ds.tests.len,
    });
}
