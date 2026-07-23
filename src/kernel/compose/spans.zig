//! Language-aware function-span geometry — the syntactic half of region lifting.
//!
//! Given source bytes (and, for a single hit, a position), this module carves
//! comparison-sized spans: the enclosing function of a hit, a bounded context
//! window, or every recognized function in a file. It knows string/comment
//! lexing (via `lexspan`), brace matching, and Python indentation blocks, but
//! nothing about exact matching — the statistical selection in `regions.zig`
//! rides on top of it. Language is chosen by suffix only, never a content
//! parse, the same covenant the silhouette scanner keeps.

const std = @import("std");
const lexspan = @import("lexspan.zig");

pub const Range = struct { start: usize, end: usize };

pub const Region = struct {
    doc: u32,
    start: usize,
    end: usize,
    match_start: usize,
    line_start: u32,
    line_end: u32,
};

const Lex = lexspan.Lex;
const lexByte = lexspan.lexByte;
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

/// The enclosing function of a hit: Python indentation block first, then a
/// brace span. Language is not gated here — `select` windows a hit by trying
/// both, so a Python line inside a brace file (or vice versa) still resolves.
pub fn enclosing(gpa: std.mem.Allocator, bytes: []const u8, hit: usize) ?Range {
    return pythonFunction(bytes, hit) orelse braceFunction(gpa, bytes, hit);
}

/// Every recognized function in `doc` as a comparison region, language-selected
/// by `path`. No exact filter gates the walk — this is the exhaustive unit the
/// concept engine sketches. Methods inside a struct/class surface; closures
/// nested inside a function body do NOT (the enclosing function already carries
/// them). Overlaps never double-emit.
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

/// A `Range` promoted to a `Region`, resolving its 1-based line bounds.
pub fn region(doc: u32, bytes: []const u8, r: Range, match_start: usize) Region {
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

/// The hit's own line(s) grown by `radius` lines on each side.
pub fn contextRange(bytes: []const u8, hit_start: usize, hit_end: usize, radius: usize) Range {
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
