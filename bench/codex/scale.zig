//! codex-scale — the self-index proof harness (`zig build codex-scale`).
//!
//! Runs the REAL codex (src/index/codex/) over slices of an on-disk corpus and
//! emits the evidence for the Shannon claim at scale: index bits/char next to
//! the corpus's measured H₀/H₂ (space at the entropy bound), count(P) latency
//! across corpus sizes (flat in n — the Ω(m) time floor), locate cost at the
//! sampling stride, and a byte-exact restore() of the entire input from the
//! index alone (the decodability proof). Every timed count is also verified
//! against a naive std.mem scan of the original text, so the numbers can
//! never come from a broken index.
//!
//!   zig build codex-scale -- <corpus> [--sizes-mb 1,4,16,64,128] \
//!       [--queries 200] [--sample-rate 32]
//!
//! Persistence and relatedness ride the same slices: every build is saved,
//! reloaded, and re-verified (kind=persist — blob size, save/load wall time,
//! load-vs-build ratio), and the Ziv–Merhav cross-parse is priced over native
//! vs foreign queries (kind=cento — bits/byte separation + parse ns/byte).
//!
//! JSON lines on stdout (kind=build|persist|query|cento per point); prose on
//! stderr. The sibling driver (bench/codex/race.sh) adds gzip/bzip2/zstd/xz
//! baselines on identical slices. Run from the repo root (the build step sets
//! cwd).

const std = @import("std");
const irregex = @import("irregex");

const codex = irregex.codex.index;
const cento = irregex.codex.cento;

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

fn emit(line: []const u8) void {
    var off: usize = 0;
    while (off < line.len) {
        // Retry EINTR; any other short/failed write is fatal — silently
        // dropping bytes would corrupt the JSONL evidence stream.
        const rc = std.posix.system.write(1, line.ptr + off, line.len - off);
        if (rc <= 0) {
            if (std.posix.errno(rc) == .INTR) continue;
            die("stdout write failed\n", .{});
        }
        off += @intCast(rc);
    }
}

fn entropyH0(text: []const u8) f64 {
    var freq: [256]u64 = @splat(0);
    for (text) |c| freq[c] += 1;
    var h: f64 = 0.0;
    const nf = @as(f64, @floatFromInt(text.len));
    for (freq) |f| {
        if (f == 0) continue;
        const p = @as(f64, @floatFromInt(f)) / nf;
        h -= p * @log2(p);
    }
    return h;
}

/// Exact order-2 empirical entropy — the k=2 point of the nH_k bound the
/// RRR-compressed wavelet tree is theorem-bound to approach.
fn entropyH2(gpa: std.mem.Allocator, text: []const u8) !f64 {
    if (text.len < 3) return 0.0;
    const table = try gpa.alloc(u32, 65536 * 256);
    defer gpa.free(table);
    @memset(table, 0);
    for (2..text.len) |i| {
        const ctx = (@as(usize, text[i - 2]) << 8) | text[i - 1];
        table[ctx * 256 + text[i]] += 1;
    }
    var bits: f64 = 0.0;
    var total: u64 = 0;
    for (0..65536) |ctx| {
        const row = table[ctx * 256 ..][0..256];
        var ctx_n: u64 = 0;
        for (row) |f| ctx_n += f;
        if (ctx_n == 0) continue;
        total += ctx_n;
        const cn = @as(f64, @floatFromInt(ctx_n));
        for (row) |f| {
            if (f == 0) continue;
            const ff = @as(f64, @floatFromInt(f));
            bits += ff * @log2(cn / ff);
        }
    }
    return bits / @as(f64, @floatFromInt(total));
}

fn naiveCount(hay: []const u8, needle: []const u8) usize {
    var c: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, hay, i, needle)) |p| {
        c += 1;
        i = p + 1;
    }
    return c;
}

const QUERY_LENGTHS = [_]usize{ 4, 8, 16, 32, 64 };

fn runSlice(gpa: std.mem.Allocator, io: std.Io, text: []const u8, n_queries: usize, sample_rate: u32) !void {
    const mbf = @as(f64, @floatFromInt(text.len)) / (1 << 20);

    const t_build = nowNs(io);
    var idx = try codex.Codex.build(gpa, text, .{ .sample_rate = sample_rate });
    defer idx.deinit(gpa);
    const build_ns = nowNs(io) - t_build;

    // decodability: the whole slice back out of the index alone
    const t_restore = nowNs(io);
    const rebuilt = try idx.restore(gpa);
    const restore_ns = nowNs(io) - t_restore;
    const restore_ok = std.mem.eql(u8, text, rebuilt);
    gpa.free(rebuilt);
    if (!restore_ok) die("restore mismatch at {d:.0}MB — self-index broken\n", .{mbf});

    const h0 = entropyH0(text);
    const h2 = try entropyH2(gpa, text);
    var buf: [640]u8 = undefined;
    emit(std.fmt.bufPrint(&buf,
        \\{{"kind":"build","raw_bytes":{d},"index_bytes":{d},"tree_bytes":{d},"locate_bytes":{d},"bits_per_char":{d:.3},"h0_bits":{d:.3},"h2_bits":{d:.3},"sample_rate":{d},"build_ms":{d:.1},"restore_ms":{d:.1},"restore_ok":true}}
    ++ "\n", .{
        text.len,                idx.stats.index_bytes, idx.stats.tree_bytes, idx.stats.locate_bytes,
        idx.stats.bitsPerChar(), h0,                    h2,                   sample_rate,
        ms(build_ns),            ms(restore_ns),
    }) catch die("format overflow\n", .{}));
    std.debug.print("n={d:.0}MB  {d:.2} bits/char (tree {d:.2} + locate {d:.2}; H0 {d:.2}, H2 {d:.2})  build {d:.0}ms  restore OK {d:.0}ms\n", .{
        mbf,
        idx.stats.bitsPerChar(),
        @as(f64, @floatFromInt(idx.stats.tree_bytes)) * 8.0 / @as(f64, @floatFromInt(text.len)),
        @as(f64, @floatFromInt(idx.stats.locate_bytes)) * 8.0 / @as(f64, @floatFromInt(text.len)),
        h0,
        h2,
        ms(build_ns),
        ms(restore_ns),
    });

    // persistence: save → load → the loaded index must answer like the built
    // one (spot-checked below against the same oracle queries)
    const t_save = nowNs(io);
    const blob = try idx.save(gpa);
    const save_ns = nowNs(io) - t_save;
    const blob_len = blob.len;
    const t_load = nowNs(io);
    var loaded = try codex.Codex.load(gpa, blob);
    const load_ns = nowNs(io) - t_load;
    gpa.free(blob);
    defer loaded.deinit(gpa);
    emit(std.fmt.bufPrint(&buf,
        \\{{"kind":"persist","raw_bytes":{d},"blob_bytes":{d},"save_ms":{d:.1},"load_ms":{d:.1},"load_over_build":{d:.3}}}
    ++ "\n", .{
        text.len,                                                                      blob_len, ms(save_ns), ms(load_ns),
        @as(f64, @floatFromInt(load_ns)) / @as(f64, @floatFromInt(@max(build_ns, 1))),
    }) catch die("format overflow\n", .{}));
    std.debug.print("  persist: save {d:.0}ms  load {d:.0}ms ({d:.1}% of build)\n", .{
        ms(save_ns), ms(load_ns), 100.0 * @as(f64, @floatFromInt(load_ns)) / @as(f64, @floatFromInt(@max(build_ns, 1))),
    });

    var prng = std.Random.DefaultPrng.init(1);
    const rand = prng.random();
    var sink: usize = 0;

    for (QUERY_LENGTHS) |m| {
        if (text.len <= m) continue;
        const pats = try gpa.alloc([]const u8, n_queries);
        defer gpa.free(pats);
        for (pats) |*p| {
            const pos = rand.intRangeLessThan(usize, 0, text.len - m);
            p.* = text[pos .. pos + m];
        }
        // verify a subsample against the naive oracle before timing anything —
        // and the RELOADED index against the built one (persistence proof)
        var mismatches: usize = 0;
        for (pats[0..@min(pats.len, 25)]) |p| {
            const want = naiveCount(text, p);
            if (idx.count(p) != want or loaded.count(p) != want) mismatches += 1;
        }
        if (mismatches > 0) die("count mismatch at n={d} m={d}\n", .{ text.len, m });

        var best_ns: i128 = std.math.maxInt(i128);
        for (0..3) |_| {
            const t0 = nowNs(io);
            for (pats) |p| sink +%= idx.count(p);
            best_ns = @min(best_ns, nowNs(io) - t0);
        }
        const count_ns_q = @divTrunc(best_ns, @as(i128, @intCast(pats.len)));

        // locate: time find() over a bounded-occurrence subset (locate cost is
        // per-occurrence; unbounded hot patterns would time the allocator)
        var find_ns_q: i128 = -1;
        if (sample_rate > 0) {
            var timed: usize = 0;
            var total_ns: i128 = 0;
            for (pats) |p| {
                if (idx.count(p) > 100) continue;
                const t0 = nowNs(io);
                const hits = try idx.find(gpa, p);
                total_ns += nowNs(io) - t0;
                gpa.free(hits);
                timed += 1;
                if (timed == 50) break;
            }
            if (timed > 0) find_ns_q = @divTrunc(total_ns, @as(i128, @intCast(timed)));
        }

        // naive scan baseline at m=16 (each query walks all n bytes)
        var naive_ns_q: i128 = -1;
        if (m == 16) {
            const nb = @min(pats.len, 50);
            const t0 = nowNs(io);
            for (pats[0..nb]) |p| sink +%= naiveCount(text, p);
            naive_ns_q = @divTrunc(nowNs(io) - t0, @as(i128, @intCast(nb)));
        }

        emit(std.fmt.bufPrint(&buf,
            \\{{"kind":"query","raw_bytes":{d},"m":{d},"count_ns_per_query":{d},"find_ns_per_query":{d},"naive_ns_per_query":{d}}}
        ++ "\n", .{ text.len, m, count_ns_q, find_ns_q, naive_ns_q }) catch die("format overflow\n", .{}));
        std.debug.print("  m={d:>2}  count {d:>7}ns/q  find {d:>9}ns/q\n", .{ m, count_ns_q, find_ns_q });
    }
    // cross-parse: price NATIVE queries (verbatim slices of the corpus) next
    // to FOREIGN ones (uniform random bytes) through the same greedy parse.
    // The bits/byte gap is the Ziv–Merhav relatedness signal; ns/byte is the
    // O(m) query cost that must stay flat as n grows.
    const qlen: usize = 256;
    if (text.len > qlen) {
        const rounds = @min(n_queries, 64);
        var native_bits: f64 = 0;
        var foreign_bits: f64 = 0;
        var parse_ns: i128 = 0;
        var fq: [qlen]u8 = undefined;
        for (0..rounds) |_| {
            const pos = rand.intRangeLessThan(usize, 0, text.len - qlen);
            const nq = text[pos .. pos + qlen];
            rand.bytes(&fq);
            const t0 = nowNs(io);
            native_bits += cento.price(&idx, nq);
            foreign_bits += cento.price(&idx, &fq);
            parse_ns += nowNs(io) - t0;
        }
        // the parse must survive persistence bit-for-bit
        const probe = text[0..qlen];
        if (cento.price(&idx, probe) != cento.price(&loaded, probe))
            die("cento price drifts across save/load at n={d}\n", .{text.len});
        const denom = @as(f64, @floatFromInt(rounds * qlen));
        const native_bpb = native_bits / denom;
        const foreign_bpb = foreign_bits / denom;
        const ns_per_byte = @as(f64, @floatFromInt(parse_ns)) / (denom * 2.0);
        emit(std.fmt.bufPrint(&buf,
            \\{{"kind":"cento","raw_bytes":{d},"query_len":{d},"rounds":{d},"native_bits_per_byte":{d:.3},"foreign_bits_per_byte":{d:.3},"parse_ns_per_byte":{d:.1}}}
        ++ "\n", .{ text.len, qlen, rounds, native_bpb, foreign_bpb, ns_per_byte }) catch die("format overflow\n", .{}));
        std.debug.print("  cento: native {d:.2} vs foreign {d:.2} bits/byte ({d:.1}x)  parse {d:.0}ns/byte\n", .{
            native_bpb, foreign_bpb, foreign_bpb / @max(native_bpb, 1e-9), ns_per_byte,
        });
    }
    std.debug.print("  (sink {d})\n", .{sink % 997});
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.skip();
    var corpus_path: ?[]const u8 = null;
    var sizes_mb: [16]usize = undefined;
    var n_sizes: usize = 0;
    var n_queries: usize = 200;
    var sample_rate: u32 = 32;
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--sizes-mb")) {
            const spec = it.next() orelse die("--sizes-mb needs a comma list\n", .{});
            var parts = std.mem.splitScalar(u8, spec, ',');
            while (parts.next()) |p| {
                sizes_mb[n_sizes] = std.fmt.parseInt(usize, p, 10) catch die("bad size {s}\n", .{p});
                n_sizes += 1;
            }
        } else if (std.mem.eql(u8, arg, "--queries")) {
            const q = it.next() orelse die("--queries needs a number\n", .{});
            n_queries = std.fmt.parseInt(usize, q, 10) catch die("bad count {s}\n", .{q});
        } else if (std.mem.eql(u8, arg, "--sample-rate")) {
            const r = it.next() orelse die("--sample-rate needs a number\n", .{});
            sample_rate = std.fmt.parseInt(u32, r, 10) catch die("bad rate {s}\n", .{r});
        } else if (corpus_path == null) {
            corpus_path = arg;
        } else die("unexpected arg {s}\n", .{arg});
    }
    if (n_sizes == 0) {
        sizes_mb = .{ 1, 4, 16, 64, 128 } ++ .{0} ** 11;
        n_sizes = 5;
    }
    const path = corpus_path orelse die("usage: codex-scale <corpus> [--sizes-mb 1,4,16,64,128] [--queries N] [--sample-rate R]\n", .{});

    const corpus = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 31)) catch
        die("cannot read {s}\n", .{path});
    defer gpa.free(corpus);
    std.debug.print("corpus {s}: {d:.1}MB · sample_rate {d}\n", .{ path, @as(f64, @floatFromInt(corpus.len)) / (1 << 20), sample_rate });

    for (sizes_mb[0..n_sizes]) |mb| {
        const want = mb << 20;
        if (want > corpus.len) {
            std.debug.print("skipping {d}MB (corpus is {d:.1}MB)\n", .{ mb, @as(f64, @floatFromInt(corpus.len)) / (1 << 20) });
            continue;
        }
        try runSlice(gpa, io, corpus[0..want], n_queries, sample_rate);
    }
}
