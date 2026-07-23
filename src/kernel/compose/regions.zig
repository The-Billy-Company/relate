// MONOLITHIC: exact-to-region lifting — exact match selection first, then region-sized comparison units for kinship; the selection and windowing state co-maintain one statistical unit
//! Exact matches lifted into comparison-sized regions.
//!
//! File-level kinship hides a small implementation inside unrelated bytes.
//! This module keeps exact selection first, but changes the statistical unit:
//! every matching line becomes either a bounded match window or its enclosing
//! function. Multiple hits in one function collapse to one region.

const std = @import("std");
const patterns = @import("../batch/patterns.zig");
const lexspan = @import("lexspan.zig");

pub const Unit = enum { file, function, match };

pub const Region = struct {
    doc: u32,
    start: usize,
    end: usize,
    match_start: usize,
    line_start: u32,
    line_end: u32,
};

pub const Set = struct {
    gpa: std.mem.Allocator,
    items: []Region,

    pub fn deinit(self: *Set) void {
        self.gpa.free(self.items);
    }
};

const Range = struct { start: usize, end: usize };
const Lex = lexspan.Lex;

/// Select every exact-hit region. `context` bounds `match`; function mode emits
/// only a recognized enclosing function. Overlapping hits collapse to one unit.
pub fn select(
    gpa: std.mem.Allocator,
    docs: []const []const u8,
    set: *const patterns.PatternSet,
    unit: Unit,
    context: usize,
) !Set {
    var scratch = try set.scratch(gpa);
    defer scratch.deinit(gpa);
    const mask = try gpa.alloc(u64, patterns.maskWords(set.len()));
    defer gpa.free(mask);

    var out: std.ArrayList(Region) = .empty;
    errdefer out.deinit(gpa);
    var hits: std.ArrayList(u32) = .empty;
    defer hits.deinit(gpa);

    for (docs, 0..) |doc, d| {
        if (unit == .file) {
            if (set.docMask(doc, &scratch, mask))
                try appendRegion(&out, gpa, region(@intCast(d), doc, .{ .start = 0, .end = doc.len }, 0), false);
            continue;
        }

        var line_start: usize = 0;
        while (line_start < doc.len) {
            const nl = std.mem.indexOfScalarPos(u8, doc, line_start, '\n');
            const line_end = nl orelse doc.len;
            if (commentOnly(doc[line_start..line_end])) {
                if (nl == null) break;
                line_start = line_end + 1;
                continue;
            }
            hits.clearRetainingCapacity();
            try set.lineHits(doc[line_start..line_end], &scratch, gpa, &hits);
            if (hits.items.len > 0) {
                const fallback = contextRange(doc, line_start, line_end, context);
                const selected = if (unit == .function)
                    pythonFunction(doc, line_start) orelse braceFunction(gpa, doc, line_start)
                else
                    fallback;
                if (selected) |r| try appendRegion(&out, gpa, region(@intCast(d), doc, r, line_start), unit != .file);
            }
            if (nl == null) break;
            line_start = line_end + 1;
        }
    }
    return .{ .gpa = gpa, .items = try out.toOwnedSlice(gpa) };
}

const commentOnly = lexspan.commentOnly;

/// Which extraction strategy `path`'s extension selects. Brace languages find
/// header+`{…}` spans; Python finds `def`/`async def` blocks by indentation;
/// anything else yields no fragments (an unrecognized file is silence, never a
/// false region). Language is chosen by suffix only — no content parse, the
/// same covenant the silhouette scanner keeps.
pub const Lang = enum { brace, python, none };

const brace_exts = std.StaticStringMap(void).initComptime(.{
    .{"zig"}, .{"c"},   .{"h"},     .{"cc"},   .{"cpp"}, .{"cxx"}, .{"hpp"},
    .{"hh"},  .{"rs"},  .{"go"},    .{"ts"},   .{"tsx"}, .{"js"},  .{"jsx"},
    .{"mjs"}, .{"cjs"}, .{"swift"}, .{"java"}, .{"kt"},  .{"m"},   .{"mm"},
    .{"gd"},  .{"cs"},  .{"scala"}, .{"php"},
});
const python_exts = std.StaticStringMap(void).initComptime(.{
    .{"py"}, .{"pyx"}, .{"pyi"},
});

pub fn languageOf(path: []const u8) Lang {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return .none;
    const ext = path[dot + 1 ..];
    if (brace_exts.has(ext)) return .brace;
    if (python_exts.has(ext)) return .python;
    return .none;
}

/// Every recognized function in `doc` as a comparison region, language-selected
/// by `path`. Unlike `select`, no exact filter gates the walk — this is the
/// exhaustive unit the concept engine sketches. Methods inside a struct/class
/// surface; closures nested inside a function body do NOT (the enclosing
/// function already carries them). Overlaps never double-emit.
pub fn extractAll(gpa: std.mem.Allocator, path: []const u8, doc: []const u8, doc_id: u32, out: *std.ArrayList(Region)) !void {
    switch (languageOf(path)) {
        .brace => try extractBrace(gpa, doc, doc_id, out),
        .python => try extractPython(gpa, doc, doc_id, out),
        .none => {},
    }
}

/// Brace-language walk: every `{` whose header reads as a function opens a
/// region spanning header→matching brace; the walk then resumes AFTER that
/// brace, so nested closures stay inside their parent. A non-function `{`
/// (struct/enum/namespace/block) is descended into, so its methods surface.
fn extractBrace(gpa: std.mem.Allocator, doc: []const u8, doc_id: u32, out: *std.ArrayList(Region)) !void {
    var state: Lex = .code;
    var escaped = false;
    var i: usize = 0;
    while (i < doc.len) : (i += 1) {
        if (!lexByte(doc, &i, &state, &escaped)) continue;
        if (doc[i] != '{') continue;
        const open = i;
        const start = headerStart(doc, open);
        if (!functionHeader(doc[start..open])) continue; // descend into non-function braces
        const close = matchingBrace(doc, open) orelse continue;
        try out.append(gpa, region(doc_id, doc, .{ .start = start, .end = lineEnd(doc, close) }, start));
        i = close; // the loop's `+= 1` resumes just past the closing brace
        state = .code;
        escaped = false;
    }
}

/// Python walk: each `def`/`async def` line opens a region covering its
/// decorators and indentation-delimited body (the same extent `pythonFunction`
/// computes); the walk resumes at the body end, so a nested closure inside the
/// body is not re-emitted while a sibling method still is.
fn extractPython(gpa: std.mem.Allocator, doc: []const u8, doc_id: u32, out: *std.ArrayList(Region)) !void {
    var line_start: usize = 0;
    while (line_start < doc.len) {
        const end = lineEnd(doc, line_start);
        const trimmed = std.mem.trim(u8, doc[line_start..end], " \t\r\n");
        if (isPythonDef(trimmed)) {
            if (pythonFunction(doc, line_start)) |r| {
                try out.append(gpa, region(doc_id, doc, r, line_start));
                line_start = if (r.end > end) r.end else end;
                continue;
            }
        }
        if (end <= line_start) break;
        line_start = end;
    }
}

fn appendRegion(out: *std.ArrayList(Region), gpa: std.mem.Allocator, item: Region, merge_overlap: bool) !void {
    for (out.items) |*seen| {
        if (seen.doc != item.doc) continue;
        if (seen.start == item.start and seen.end == item.end) return;
        if (merge_overlap and item.start < seen.end and seen.start < item.end) {
            seen.start = @min(seen.start, item.start);
            seen.end = @max(seen.end, item.end);
            seen.line_start = @min(seen.line_start, item.line_start);
            seen.line_end = @max(seen.line_end, item.line_end);
            return;
        }
    }
    try out.append(gpa, item);
}

fn region(doc: u32, bytes: []const u8, r: Range, match_start: usize) Region {
    return .{
        .doc = doc,
        .start = r.start,
        .end = r.end,
        .match_start = match_start,
        .line_start = lineAt(bytes, r.start),
        .line_end = lineAt(bytes, if (r.end > r.start) r.end - 1 else r.end),
    };
}

fn lineAt(bytes: []const u8, at: usize) u32 {
    var n: u32 = 1;
    for (bytes[0..@min(at, bytes.len)]) |c| n += @intFromBool(c == '\n');
    return n;
}

fn lineStart(bytes: []const u8, at: usize) usize {
    return if (std.mem.lastIndexOfScalar(u8, bytes[0..@min(at, bytes.len)], '\n')) |p| p + 1 else 0;
}

fn lineEnd(bytes: []const u8, at: usize) usize {
    return if (std.mem.indexOfScalarPos(u8, bytes, @min(at, bytes.len), '\n')) |p| p + 1 else bytes.len;
}

fn contextRange(bytes: []const u8, hit_start: usize, hit_end: usize, radius: usize) Range {
    var start = lineStart(bytes, hit_start);
    var end = lineEnd(bytes, hit_end);
    for (0..radius) |_| {
        if (start > 0) start = lineStart(bytes, start - 1);
        if (end < bytes.len) end = lineEnd(bytes, end);
    }
    return .{ .start = start, .end = end };
}

fn indentation(line: []const u8) usize {
    var n: usize = 0;
    while (n < line.len and (line[n] == ' ' or line[n] == '\t')) n += 1;
    return n;
}

fn isPythonDef(trimmed: []const u8) bool {
    return std.mem.startsWith(u8, trimmed, "def ") or std.mem.startsWith(u8, trimmed, "async def ");
}

fn pythonFunction(bytes: []const u8, hit: usize) ?Range {
    const hit_line = lineStart(bytes, hit);
    const hit_indent = indentation(bytes[hit_line..lineEnd(bytes, hit_line)]);
    var cursor = hit_line;
    while (true) {
        const start = lineStart(bytes, cursor);
        const end = lineEnd(bytes, start);
        const raw = bytes[start..end];
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        const indent = indentation(raw);
        if (isPythonDef(trimmed) and indent <= hit_indent) {
            var finish = end;
            while (finish < bytes.len) {
                const next_end = lineEnd(bytes, finish);
                const next = bytes[finish..next_end];
                const next_trimmed = std.mem.trim(u8, next, " \t\r\n");
                if (next_trimmed.len > 0 and indentation(next) <= indent) break;
                finish = next_end;
            }
            while (finish > end) {
                const prev = lineStart(bytes, finish - 1);
                if (std.mem.trim(u8, bytes[prev..finish], " \t\r\n").len > 0) break;
                finish = prev;
            }
            var begin = start;
            while (begin > 0) {
                const prev_start = lineStart(bytes, begin - 1);
                const prev = std.mem.trim(u8, bytes[prev_start..begin], " \t\r\n");
                if (!std.mem.startsWith(u8, prev, "@") or indentation(bytes[prev_start..begin]) != indent) break;
                begin = prev_start;
            }
            return .{ .start = begin, .end = finish };
        }
        if (start == 0) break;
        cursor = start - 1;
    }
    return null;
}

fn braceFunction(gpa: std.mem.Allocator, bytes: []const u8, hit: usize) ?Range {
    var opens: std.ArrayList(usize) = .empty;
    defer opens.deinit(gpa);
    var state: Lex = .code;
    var escaped = false;
    var i: usize = 0;
    while (i < lineEnd(bytes, hit)) : (i += 1) {
        if (!lexByte(bytes, &i, &state, &escaped)) continue;
        if (bytes[i] == '{') {
            opens.append(gpa, i) catch return null;
        } else if (bytes[i] == '}' and opens.items.len > 0) {
            _ = opens.pop();
        }
    }

    var k = opens.items.len;
    while (k > 0) {
        k -= 1;
        const open = opens.items[k];
        const start = headerStart(bytes, open);
        if (!functionHeader(bytes[start..open])) continue;
        const close = matchingBrace(bytes, open) orelse continue;
        if (close < hit) continue;
        return .{ .start = start, .end = lineEnd(bytes, close) };
    }
    return null;
}

fn headerStart(bytes: []const u8, open: usize) usize {
    var start = lineStart(bytes, open);
    var lines: usize = 0;
    // A wrapped signature (one parameter per line) can push the `fn`/`func`/
    // `def` keyword well above the brace, so the climb spans more than a couple
    // of lines. The statement/block terminators below still fence it — the cap
    // only guards against an unterminated run — so it can be generous.
    while (start > 0 and lines < 16) : (lines += 1) {
        const prev = lineStart(bytes, start - 1);
        const trimmed = std.mem.trim(u8, bytes[prev..start], " \t\r\n");
        // A previous line ending in `;`, `}`, or `{` closed a statement or
        // opened an enclosing block — the header cannot climb across it.
        if (trimmed.len == 0 or commentOnly(trimmed) or std.mem.endsWith(u8, trimmed, ";") or
            std.mem.endsWith(u8, trimmed, "}") or std.mem.endsWith(u8, trimmed, "{")) break;
        start = prev;
    }
    return start;
}

fn functionHeader(raw: []const u8) bool {
    const h = std.mem.trim(u8, raw, " \t\r\n");
    if (h.len == 0) return false;
    const controls = [_][]const u8{ "if ", "if(", "for ", "for(", "while ", "while(", "switch ", "switch(", "match ", "catch ", "else", "do ", "defer " };
    for (controls) |control| if (std.mem.startsWith(u8, h, control)) return false;
    if (std.mem.indexOf(u8, h, " fn ") != null or std.mem.startsWith(u8, h, "fn ") or
        std.mem.indexOf(u8, h, "func ") != null or std.mem.indexOf(u8, h, "function ") != null or
        std.mem.indexOf(u8, h, "=>") != null) return true;
    const lparen = std.mem.indexOfScalar(u8, h, '(') orelse return false;
    return lparen > 0 and std.mem.indexOfScalarPos(u8, h, lparen + 1, ')') != null;
}

fn matchingBrace(bytes: []const u8, open: usize) ?usize {
    var state: Lex = .code;
    var escaped = false;
    var depth: usize = 0;
    var i = open;
    while (i < bytes.len) : (i += 1) {
        if (!lexByte(bytes, &i, &state, &escaped)) continue;
        if (bytes[i] == '{') depth += 1 else if (bytes[i] == '}') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

const lexByte = lexspan.lexByte;

test "function regions collapse repeated hits and separate same-file implementations" {
    const gpa = std.testing.allocator;
    const docs = [_][]const u8{
        \\fn alpha() {
        \\    target();
        \\    target();
        \\}
        \\fn beta() {
        \\    target();
        \\}
    };
    const specs = [_]patterns.Spec{.{ .pattern = "target", .fixed = true }};
    var compiled = try patterns.PatternSet.compile(gpa, &specs);
    defer compiled.deinit(gpa);
    var found = try select(gpa, &docs, &compiled, .function, 2);
    defer found.deinit();

    try std.testing.expectEqual(@as(usize, 2), found.items.len);
    try std.testing.expectEqual(@as(u32, 1), found.items[0].line_start);
    try std.testing.expectEqual(@as(u32, 5), found.items[1].line_start);
}

test "python function region ignores a nested control block" {
    const gpa = std.testing.allocator;
    const docs = [_][]const u8{
        \\def alpha(value):
        \\    if value:
        \\        target(value)
        \\    return value
        \\
        \\def beta():
        \\    return 2
    };
    const specs = [_]patterns.Spec{.{ .pattern = "target", .fixed = true }};
    var compiled = try patterns.PatternSet.compile(gpa, &specs);
    defer compiled.deinit(gpa);
    var found = try select(gpa, &docs, &compiled, .function, 2);
    defer found.deinit();

    try std.testing.expectEqual(@as(usize, 1), found.items.len);
    try std.testing.expectEqual(@as(u32, 1), found.items[0].line_start);
    try std.testing.expectEqual(@as(u32, 4), found.items[0].line_end);
}

test "function unit excludes top-level documentation and data literals" {
    const gpa = std.testing.allocator;
    const docs = [_][]const u8{
        \\//! target() is documented here.
        \\const manifest =
        \\    \\{"call":"target()"}
        \\;
        \\
        \\fn real() {
        \\    target();
        \\}
    };
    const specs = [_]patterns.Spec{.{ .pattern = "target", .fixed = true }};
    var compiled = try patterns.PatternSet.compile(gpa, &specs);
    defer compiled.deinit(gpa);
    var found = try select(gpa, &docs, &compiled, .function, 2);
    defer found.deinit();

    try std.testing.expectEqual(@as(usize, 1), found.items.len);
    try std.testing.expectEqual(@as(u32, 6), found.items[0].line_start);
}

test "match unit merges overlapping windows from adjacent hits" {
    const gpa = std.testing.allocator;
    const docs = [_][]const u8{
        \\before
        \\target()
        \\target_word()
        \\after
    };
    const specs = [_]patterns.Spec{.{ .pattern = "target", .fixed = true }};
    var compiled = try patterns.PatternSet.compile(gpa, &specs);
    defer compiled.deinit(gpa);
    var found = try select(gpa, &docs, &compiled, .match, 1);
    defer found.deinit();

    try std.testing.expectEqual(@as(usize, 1), found.items.len);
    try std.testing.expectEqual(@as(u32, 1), found.items[0].line_start);
    try std.testing.expectEqual(@as(u32, 4), found.items[0].line_end);
}

test "overlapping function discoveries collapse to the widest region" {
    const gpa = std.testing.allocator;
    var found: std.ArrayList(Region) = .empty;
    defer found.deinit(gpa);
    try appendRegion(&found, gpa, .{ .doc = 0, .start = 10, .end = 20, .match_start = 12, .line_start = 2, .line_end = 4 }, true);
    try appendRegion(&found, gpa, .{ .doc = 0, .start = 10, .end = 30, .match_start = 24, .line_start = 2, .line_end = 6 }, true);
    try std.testing.expectEqual(@as(usize, 1), found.items.len);
    try std.testing.expectEqual(@as(usize, 30), found.items[0].end);
    try std.testing.expectEqual(@as(u32, 6), found.items[0].line_end);
}

test "extractAll: brace methods surface, nested closures stay inside their function" {
    const gpa = std.testing.allocator;
    const doc =
        \\const Handler = struct {
        \\    fn serve(self: *Handler) void {
        \\        const inner = struct {
        \\            fn helper() void {}
        \\        };
        \\        inner.helper();
        \\    }
        \\    fn close(self: *Handler) void {
        \\        self.done = true;
        \\    }
        \\};
        \\fn free_standing() void {
        \\    work();
        \\}
    ;
    var out: std.ArrayList(Region) = .empty;
    defer out.deinit(gpa);
    try extractAll(gpa, "handler.zig", doc, 0, &out);
    // serve (with its nested closure folded in), close, and free_standing —
    // three functions, never the inner closure as its own region.
    try std.testing.expectEqual(@as(usize, 3), out.items.len);
    try std.testing.expectEqual(@as(u32, 2), out.items[0].line_start); // serve
    try std.testing.expectEqual(@as(u32, 7), out.items[0].line_end);
    try std.testing.expectEqual(@as(u32, 8), out.items[1].line_start); // close
    try std.testing.expectEqual(@as(u32, 12), out.items[2].line_start); // free_standing
}

test "extractAll: python methods and top-level defs, decorators included" {
    const gpa = std.testing.allocator;
    const doc =
        \\class Service:
        \\    @property
        \\    def alpha(self):
        \\        def closure():
        \\            return 1
        \\        return closure()
        \\    def beta(self):
        \\        return 2
        \\
        \\def top_level():
        \\    return 3
    ;
    var out: std.ArrayList(Region) = .empty;
    defer out.deinit(gpa);
    try extractAll(gpa, "service.py", doc, 0, &out);
    // alpha (decorator + body + its closure), beta, top_level — the closure is
    // folded into alpha, never emitted alone.
    try std.testing.expectEqual(@as(usize, 3), out.items.len);
    try std.testing.expectEqual(@as(u32, 2), out.items[0].line_start); // @property above alpha
    try std.testing.expectEqual(@as(u32, 7), out.items[1].line_start); // beta
    try std.testing.expectEqual(@as(u32, 10), out.items[2].line_start); // top_level
}

test "extractAll: unrecognized extension yields no fragments" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(Region) = .empty;
    defer out.deinit(gpa);
    try extractAll(gpa, "notes.md", "fn looks_like_code() {}\n", 0, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}
