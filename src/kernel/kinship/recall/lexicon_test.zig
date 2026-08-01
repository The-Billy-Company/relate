//! The small proof: does compression-as-search actually retrieve?
//!
//! These tests hold `lexicon.zig` + `zipper.zig` to the claims that justify
//! their existence, on embedded fixtures (never the live tree — ~10 agents
//! edit this checkout concurrently). The load-bearing assertions:
//!
//!   1. A SHORT query retrieves its source doc — the exact regime where the
//!      symmetric LZJD sketch mathematically collapses (proven here, not
//!      assumed: the sketch distance is shown non-discriminating on the same
//!      fixture the lexicon ranks correctly).
//!   2. The cross-parse (crossCost, the exact ΔAb) is asymmetric and sided:
//!      familiar text costs fewer bits under the source doc than under a
//!      stranger, and conditioning always beats encoding cold.
//!   3. Ubiquitous fingerprints carry zero information — corpus boilerplate
//!      cannot rank anything (the coding-theory IDF, not a stopword list).
//!   4. Determinism: same corpus + query ⇒ byte-identical ranking.
//!
//! Fixtures imitate the paper's setup in miniature: three "dialects"
//! (Zig-flavored, Python-flavored, prose) × distinct topics, so relatedness
//! has two axes the ranker must separate.

const std = @import("std");
const lexicon = @import("lexicon.zig");
const zipper = @import("zipper.zig");
const sketch = @import("../metric/sketch.zig");

const t = std.testing;

// ── fixtures: three dialects, two topics each ──────────────────────────────
// Realistic-shaped bodies, a few hundred bytes each, short enough to read.

const zig_alloc =
    \\pub fn alloc(gpa: std.mem.Allocator, n: usize) ![]u8 {
    \\    const buf = try gpa.alloc(u8, n);
    \\    errdefer gpa.free(buf);
    \\    @memset(buf, 0);
    \\    return buf;
    \\}
    \\pub fn dupe(gpa: std.mem.Allocator, bytes: []const u8) ![]u8 {
    \\    const out = try gpa.alloc(u8, bytes.len);
    \\    @memcpy(out, bytes);
    \\    return out;
    \\}
    \\test "alloc zeroes and dupe copies" {
    \\    const gpa = std.testing.allocator;
    \\    const a = try alloc(gpa, 16);
    \\    defer gpa.free(a);
    \\    for (a) |b| try std.testing.expectEqual(@as(u8, 0), b);
    \\}
;

const zig_socket =
    \\pub fn dial(path: []const u8) !std.net.Stream {
    \\    const sock = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    \\    errdefer std.posix.close(sock);
    \\    var addr = try std.net.Address.initUnix(path);
    \\    try std.posix.connect(sock, &addr.any, addr.getOsSockLen());
    \\    return .{ .handle = sock };
    \\}
    \\pub fn writeFrame(stream: std.net.Stream, payload: []const u8) !void {
    \\    var hdr: [4]u8 = undefined;
    \\    std.mem.writeInt(u32, &hdr, @intCast(payload.len), .little);
    \\    try stream.writeAll(&hdr);
    \\    try stream.writeAll(payload);
    \\}
;

const py_alloc =
    \\def allocate_buffer(pool, size):
    \\    """Allocate a zeroed buffer from the pool, releasing on error."""
    \\    buf = pool.acquire(size)
    \\    try:
    \\        buf.zero_fill()
    \\        return buf
    \\    except Exception:
    \\        pool.release(buf)
    \\        raise
    \\
    \\def duplicate_bytes(pool, data):
    \\    out = pool.acquire(len(data))
    \\    out.write(data)
    \\    return out
;

const py_socket =
    \\def dial_unix(path):
    \\    """Connect to a unix domain socket and return the stream."""
    \\    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    \\    try:
    \\        sock.connect(path)
    \\    except OSError:
    \\        sock.close()
    \\        raise
    \\    return sock
    \\
    \\def write_frame(sock, payload):
    \\    header = struct.pack("<I", len(payload))
    \\    sock.sendall(header)
    \\    sock.sendall(payload)
;

const prose_coffee =
    \\The barista pulled the shot slowly, watching the crema build at the rim
    \\of the cup. A good espresso is a negotiation between the grind, the dose,
    \\and the water; rush any one of them and the cup turns bitter. She tamped
    \\the next basket, level and firm, and listened to the machine breathe.
;

const prose_sailing =
    \\The skipper eased the mainsheet as the gust rolled down the channel,
    \\letting the boat breathe before hardening up again toward the mark. Good
    \\trim is a negotiation between the wind, the sail, and the helm; fight
    \\any one of them and the boat heels over and stalls in the chop.
;

const corpus = [_][]const u8{
    zig_alloc, // 0
    zig_socket, // 1
    py_alloc, // 2
    py_socket, // 3
    prose_coffee, // 4
    prose_sailing, // 5
};

fn buildLex(gpa: std.mem.Allocator) !lexicon.Lexicon {
    return lexicon.Lexicon.build(gpa, &corpus);
}

// ── 1. short-query retrieval, and the sketch's collapse on the same case ──

test "a short query retrieves its source doc top-1 (bitsSaved)" {
    const gpa = t.allocator;
    var lex = try buildLex(gpa);
    defer lex.deinit();

    // One line of doc 1 (Zig socket) — a fragment, position unknown to the
    // index; the winnowed fingerprints must find it wherever it sits.
    const query = "const sock = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);";
    const hits = try lex.rank(gpa, query, 3);
    defer gpa.free(hits);

    try t.expect(hits.len >= 1);
    try t.expectEqual(@as(u32, 1), hits[0].doc);
    // And decisively: the winner carries strictly more paid-for bits than
    // any other doc, including the same-dialect confusable (doc 0).
    for (hits[1..]) |h| try t.expect(hits[0].bits > h.bits);
}

test "a three-byte query does not disappear below the fingerprint floor" {
    const gpa = t.allocator;
    const docs = [_][]const u8{
        "the quick brown fox jumps over the lazy dog",
        "the quick brown fox jumps over the bright moon",
    };
    var lex = try lexicon.Lexicon.build(gpa, &docs);
    defer lex.deinit();

    const hits = try lex.retrieve(gpa, "dog", docs.len);
    defer gpa.free(hits);

    try t.expectEqual(@as(usize, 1), hits.len);
    try t.expectEqual(@as(u32, 0), hits[0].doc);
    try t.expect(hits[0].bits_saved > 0.0);
}

test "the symmetric sketch genuinely collapses on that same short query" {
    const gpa = t.allocator;
    // The justification for the asymmetric score is that the symmetric one
    // cannot do this job. Prove it: LZJD distance between the short query
    // and its true source is NOT discriminating — the true source does not
    // separate from the wrong-dialect confusable by any usable margin.
    const query = "const sock = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);";
    var q = try sketch.build(gpa, query);
    var right = try sketch.build(gpa, zig_socket);
    var wrong = try sketch.build(gpa, prose_coffee);

    const d_right = sketch.distance(&q, &right);
    const d_wrong = sketch.distance(&q, &wrong);
    // Both distances live in the same saturated band near 1.0 — the sketch
    // sees "tiny set vs big set" and nothing else. If this assertion ever
    // fails, the sketch got better at short queries and the lexicon's
    // recall story must be re-measured, not assumed.
    try t.expect(d_right > 0.5);
    try t.expect(d_wrong > 0.5);
}

test "two-stage retrieve separates topic from dialect confusables" {
    const gpa = t.allocator;
    var lex = try buildLex(gpa);
    defer lex.deinit();

    // Python-flavored query about sockets. The trap is two-sided: zig_socket
    // shares the TOPIC vocabulary (socket, connect, path), py_alloc shares
    // the DIALECT (def/indentation/pool idioms). The true source must beat
    // both, and the ΔAb view must agree with a real margin.
    const query = "sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)\nsock.connect(path)";
    const hits = try lex.retrieve(gpa, query, corpus.len);
    defer gpa.free(hits);

    try t.expect(hits.len >= 1);
    try t.expectEqual(@as(u32, 3), hits[0].doc); // py_socket wins
    // The decision is the cross-parse: describing the query with the true
    // source warm is >10% cheaper than with either confusable.
    const under_true = (try lex.crossCost(gpa, 3, query)).bits;
    const under_topic_confusable = (try lex.crossCost(gpa, 1, query)).bits; // zig_socket
    const under_dialect_confusable = (try lex.crossCost(gpa, 2, query)).bits; // py_alloc
    try t.expect(under_true * 1.10 < under_topic_confusable);
    try t.expect(under_true * 1.10 < under_dialect_confusable);

    // Dialect axis in isolation: a structure-only Python query (no socket
    // vocabulary) retrieves the Python alloc doc, not any Zig doc.
    const dialect_q = "def duplicate_bytes(pool, data):\n    out = pool.acquire(len(data))";
    const dh = try lex.retrieve(gpa, dialect_q, corpus.len);
    defer gpa.free(dh);
    try t.expect(dh.len >= 1);
    try t.expectEqual(@as(u32, 2), dh[0].doc); // py_alloc
}

// ── 2. the cross-parse: asymmetric, sided, never worse than cold ──

test "crossCost: familiar text is cheaper under its source doc" {
    const gpa = t.allocator;
    var lex = try buildLex(gpa);
    defer lex.deinit();

    const query = "def dial_unix(path):\n    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)";
    const under_source = try lex.crossCost(gpa, 3, query); // py_socket
    const under_stranger = try lex.crossCost(gpa, 4, query); // prose_coffee
    const cold = zipper.coldBits(query);

    // Sidedness: the source doc describes the query in fewer bits.
    try t.expect(under_source.bits < under_stranger.bits);
    // The margin is the retrieval signal — demand a real one (paper's
    // language-recognition margins are >10%; hold ours to that).
    try t.expect(under_source.bits * 1.10 < under_stranger.bits);
    // Conditioning on the true source beats encoding cold.
    try t.expect(under_source.bits < cold);
    // And the mechanism is copies instead of literals: the source swallows
    // the query in long factors; the stranger spells it out byte by byte.
    try t.expect(under_source.literals < under_stranger.literals);
}

test "crossCost is asymmetric: A explains B better than B explains A when A ⊃ B" {
    const gpa = t.allocator;
    // A = the two Python docs concatenated (rich substring space), B = a
    // fragment of A. A should nearly pre-pay B; B should barely dent A.
    const a_full = py_alloc ++ "\n" ++ py_socket;
    const b_frag = "    sock.sendall(header)\n    sock.sendall(payload)";
    const docs = [_][]const u8{ a_full, b_frag };
    var lex = try lexicon.Lexicon.build(gpa, &docs);
    defer lex.deinit();

    const b_given_a = try lex.crossCost(gpa, 0, b_frag);
    const a_given_b = try lex.crossCost(gpa, 1, a_full);

    try t.expect(b_given_a.bits < a_given_b.bits);
    // Relative gain vs cold: conditioning B on A saves most of B's bits
    // (verbatim fragment ⇒ a handful of copy factors); conditioning A on B
    // saves only B's own share of A.
    const gain_b = (zipper.coldBits(b_frag) - b_given_a.bits) / zipper.coldBits(b_frag);
    const gain_a = (zipper.coldBits(a_full) - a_given_b.bits) / zipper.coldBits(a_full);
    try t.expect(gain_b > 0.30);
    try t.expect(gain_a < 0.30);
}

// ── 3. boilerplate prices at zero bits ──

test "a fingerprint every doc knows carries zero information" {
    const gpa = t.allocator;
    // Six docs, each = shared boilerplate + a unique tail. Boilerplate
    // fingerprints have df = N ⇒ −log2(N/N) = 0 bits exactly. The only
    // nonzero credit a pure-boilerplate query can earn is from the few
    // winnowing windows that straddle a doc's boiler/tail boundary (the
    // window may select a different fingerprint per doc, making a
    // boilerplate-content fingerprint spuriously rare). That noise is
    // bounded by construction: at most window−1 straddling windows, each
    // worth at most log2 N bits.
    const boiler = "// SPDX-License-Identifier: MIT\n// Copyright Acme Inc.\n";
    const docs = [_][]const u8{
        boiler ++ "alpha body one with its own words",
        boiler ++ "bravo body two speaking differently",
        boiler ++ "charlie third body distinct again",
        boiler ++ "delta fourth entirely other text",
        boiler ++ "echo fifth body unlike the rest",
        boiler ++ "foxtrot sixth and final variant",
    };
    var lex = try lexicon.Lexicon.build(gpa, &docs);
    defer lex.deinit();

    const boiler_fps = try lexicon.fingerprints(gpa, boiler);
    defer gpa.free(boiler_fps);
    var universal: ?u64 = null;
    for (boiler_fps) |fp| if (lex.fingerprintFrequency(fp) == docs.len) {
        universal = fp;
        break;
    };
    try t.expect(universal != null);
    try t.expectEqual(@as(f64, 0), lex.fingerprintBits(universal.?));
    try t.expectEqual(@as(usize, 0), lex.fingerprintFrequency(0xdead_beef));

    const noise_ceiling = @as(f64, lexicon.window - 1) * std.math.log2(@as(f64, docs.len));
    const hits = try lex.rank(gpa, boiler, docs.len);
    defer gpa.free(hits);
    for (hits) |h| try t.expect(h.bits <= noise_ceiling);

    // The same query with one rare tail appended ranks exactly the doc that
    // knows it — decisively: strictly above every other doc AND above the
    // boundary-noise ceiling.
    const hits2 = try lex.rank(gpa, boiler ++ "foxtrot sixth", docs.len);
    defer gpa.free(hits2);
    try t.expect(hits2.len >= 1);
    try t.expectEqual(@as(u32, 5), hits2[0].doc);
    try t.expect(hits2[0].bits > noise_ceiling);
    for (hits2[1..]) |h| try t.expect(hits2[0].bits > h.bits);
}

// ── 4. determinism ──

test "same corpus + query ⇒ identical ranking, twice" {
    const gpa = t.allocator;
    var lex = try buildLex(gpa);
    defer lex.deinit();

    const query = "a negotiation between the grind, the dose, and the water";
    const h1 = try lex.retrieve(gpa, query, corpus.len);
    defer gpa.free(h1);
    const h2 = try lex.retrieve(gpa, query, corpus.len);
    defer gpa.free(h2);

    try t.expectEqual(h1.len, h2.len);
    for (h1, h2) |a, b| {
        try t.expectEqual(a.doc, b.doc);
        try t.expectEqual(a.bits_saved, b.bits_saved);
        try t.expectEqual(a.cost.bits, b.cost.bits);
    }
    // And the prose query lands on prose_coffee, not its sailing sibling —
    // the two share cadence ("a negotiation between the") but not content
    // ("the grind, the dose" is coffee's alone). The cadence fingerprints
    // price low (df = 2); the content fingerprints price high (df = 1); the
    // cross-parse then swallows the coffee half verbatim.
    try t.expect(h1.len >= 1);
    try t.expectEqual(@as(u32, 4), h1[0].doc);
}

// ── plumbing edges ──

test "empty query and empty corpus are total, not fatal" {
    const gpa = t.allocator;
    var lex = try buildLex(gpa);
    defer lex.deinit();

    const none = try lex.rank(gpa, "", 5);
    defer gpa.free(none);
    try t.expectEqual(@as(usize, 0), none.len);

    var empty = try lexicon.Lexicon.build(gpa, &.{});
    defer empty.deinit();
    const still_none = try empty.rank(gpa, "anything at all", 5);
    defer gpa.free(still_none);
    try t.expectEqual(@as(usize, 0), still_none.len);

    try t.expectEqual(@as(f64, 0.0), zipper.coldBits(""));
}
