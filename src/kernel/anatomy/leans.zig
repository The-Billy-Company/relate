//! leans — what a function borrows from the world outside itself.
//!
//! `blast`'s dependency tier asks: of every identifier inside a function's
//! body, which ones does the function actually LEAN ON, and where do they
//! live? Resolving every word against the whole corpus answers mostly noise —
//! a parameter named `gpa` "resolves" to an unrelated `gpa` in another
//! library, `std.mem.Allocator` resolves three ways at once, and the genuine
//! sibling call the tier exists to surface is buried under them. This module
//! is the discipline that makes the tier precise, in three parser-free
//! readings of the same scrubbed body:
//!
//!   • **binds** — the names the body introduces itself: parameters, `const`/
//!     `var`/`let` locals, `:=` short declarations, capture bars, loop and
//!     `as` bindings. A function never *depends* on its own bindings.
//!   • **borrows** — every other code identifier, carrying the single dotted
//!     head it hangs off (`sweep` for `sweep.run`). A member of a deeper chain
//!     (`std.mem.Allocator`), of a call result, or of an enum literal names
//!     nothing the corpus holds, so it is dropped rather than guessed at.
//!   • **homes** — a free name resolves within the seed's own package (the
//!     nearest ancestor holding a build manifest), nearest-first, so the
//!     seed's file answers before its directory and its directory before the
//!     rest of the package. How *many* files of that package declare the name
//!     is the verdict: one or a few names a specific symbol, a packageful names
//!     an ambient word — a language builtin, an import convention, a markup
//!     tag, a noun out of prose — and no single site can honestly stand for it,
//!     so it drops. A member never searches at large: it searches the one file
//!     its head names — the module it imported, so `sweep.run` lands on `run`
//!     in `sweep.zig`, or the seed's own file when the head is a local value or
//!     receiver, so `self.markDirty` lands on the sibling method. A name bound
//!     to a module the corpus does not contain (`@import("std")`) is external,
//!     and drops out entirely.
//!
//! Nothing here is a per-language table of builtins, types, or tags: every rule
//! is a geometry read or a count the corpus itself supplies, so a language the
//! kernel has never heard of behaves like the ones it has. (The one stoplist is
//! the cross-language control-flow and declaration vocabulary — words no corpus
//! declares.) A false drop costs one tangential edge, while a false resolution
//! costs the reader's trust in the whole section. Pure kernel — no I/O, no argv;
//! every allocation lands in the caller's arena.

const std = @import("std");
const lexspan = @import("lexspan.zig");
const spans = @import("spans.zig");
const patterns = @import("../slate/patterns.zig");
const signals = @import("../rank/signals.zig");

/// An identifier the seed's body leans on, resolved to its own definition
/// site. `symbol` keeps the qualifier when the lean was reached through an
/// in-corpus module (`sweep.run`), so a row reads as the source does.
pub const Dependency = struct { symbol: []const u8, doc: u32, line: u32 };

/// The resolved leans plus the pre-cap total the caller reports as stats.
pub const Resolved = struct { items: []const Dependency, total: usize };

/// Distinct free identifiers taken to the batched resolver — the `PatternSet`
/// gate is one `u64` wide, and a body leaning on more than 64 outside names is
/// already past the point where more rows help.
const max_free = 64;

/// Ceiling on the leans collected from one body, so a pathological region
/// cannot make the pass quadratic in its own vocabulary.
const max_leans = 256;

/// Identifiers that are never a dependency worth resolving — control-flow,
/// declaration, and binding-modifier keywords across the languages the corpus
/// spans. A stoplist, not a grammar.
const keywords = std.StaticStringMap(void).initComptime(.{
    .{"if"},         .{"else"},     .{"for"},       .{"while"},     .{"return"},   .{"const"},
    .{"var"},        .{"let"},      .{"fn"},        .{"func"},      .{"function"}, .{"def"},
    .{"class"},      .{"struct"},   .{"enum"},      .{"union"},     .{"switch"},   .{"case"},
    .{"break"},      .{"continue"}, .{"import"},    .{"from"},      .{"pub"},      .{"try"},
    .{"catch"},      .{"defer"},    .{"async"},     .{"await"},     .{"and"},      .{"or"},
    .{"not"},        .{"true"},     .{"false"},     .{"null"},      .{"nil"},      .{"None"},
    .{"self"},       .{"this"},     .{"type"},      .{"void"},      .{"int"},      .{"bool"},
    .{"in"},         .{"is"},       .{"as"},        .{"with"},      .{"match"},    .{"where"},
    .{"comptime"},   .{"errdefer"}, .{"inline"},    .{"static"},    .{"final"},    .{"mut"},
    .{"noalias"},    .{"export"},   .{"extern"},    .{"unsafe"},    .{"yield"},    .{"lambda"},
    .{"new"},        .{"delete"},   .{"throw"},     .{"raise"},     .{"pass"},     .{"elif"},
    .{"then"},       .{"end"},      .{"do"},        .{"loop"},      .{"impl"},     .{"trait"},
    .{"interface"},  .{"public"},   .{"private"},   .{"protected"}, .{"abstract"}, .{"override"},
    .{"readonly"},   .{"declare"},  .{"namespace"}, .{"package"},   .{"using"},    .{"extends"},
    .{"implements"}, .{"default"},  .{"unsigned"},  .{"signed"},    .{"typedef"},  .{"template"},
    .{"typename"},   .{"throws"},   .{"finally"},   .{"defmodule"}, .{"defp"},     .{"val"},
});

/// How many files of the seed's own package may declare a name before it stops
/// being a specific dependency. This is what replaces a per-language builtin
/// table: nothing here knows that `len` is a Python builtin, `std` a Zig import
/// convention, or `div` an HTML tag — the corpus says so, because a genuine
/// helper is declared once while an ambient word is declared all over the
/// package. A declaration in the seed's OWN file is exempt: same-file
/// resolution is unambiguous by construction.
const max_homes = 3;

/// Build manifests that mark a directory as a package root — the boundary
/// resolution refuses to cross. Recognized by basename in the corpus itself,
/// so no filesystem probe is needed.
const manifests = std.StaticStringMap(void).initComptime(.{
    .{"build.zig"},     .{"build.zig.zon"},  .{"Cargo.toml"}, .{"go.mod"},
    .{"package.json"},  .{"pyproject.toml"}, .{"setup.py"},   .{"mix.exs"},
    .{"Package.swift"}, .{"CMakeLists.txt"}, .{"pom.xml"},    .{"Gemfile"},
});

/// Modifiers that precede a parameter's name rather than being it, so
/// `comptime T: type`, `mut x: u32`, and `final name` all bind the right word.
/// Deliberately smaller than `keywords`: `self` IS a parameter name.
const modifiers = std.StaticStringMap(void).initComptime(.{
    .{"comptime"}, .{"const"},  .{"var"},    .{"let"}, .{"mut"},
    .{"final"},    .{"static"}, .{"inline"}, .{"pub"}, .{"ref"},
    .{"noalias"},  .{"unsafe"},
});

/// Words that may stand between the start of a statement and the name it
/// introduces. Not a grammar and not per-language: the list is open-ended by
/// design, because a declaration word missing here costs one row while a
/// control word wrongly added would cost a false one.
const declarators = std.StaticStringMap(void).initComptime(.{
    .{"pub"},       .{"fn"},       .{"func"},      .{"function"}, .{"def"},         .{"defp"},
    .{"defn"},      .{"define"},   .{"class"},     .{"struct"},   .{"enum"},        .{"union"},
    .{"interface"}, .{"trait"},    .{"impl"},      .{"type"},     .{"typedef"},     .{"const"},
    .{"var"},       .{"let"},      .{"val"},       .{"mut"},      .{"static"},      .{"final"},
    .{"comptime"},  .{"inline"},   .{"extern"},    .{"export"},   .{"default"},     .{"async"},
    .{"public"},    .{"private"},  .{"protected"}, .{"internal"}, .{"abstract"},    .{"override"},
    .{"readonly"},  .{"declare"},  .{"namespace"}, .{"module"},   .{"defmodule"},   .{"package"},
    .{"template"},  .{"typename"}, .{"unsafe"},    .{"noalias"},  .{"threadlocal"}, .{"import"},
    .{"require"},   .{"use"},      .{"using"},     .{"local"},    .{"global"},      .{"create"},
    .{"table"},     .{"view"},     .{"unsigned"},  .{"signed"},
});

/// Names that always denote the enclosing instance, bound or not — `this` is
/// never a parameter in TypeScript or Swift, but it is still a receiver.
const receivers = std.StaticStringMap(void).initComptime(.{
    .{"self"}, .{"this"}, .{"cls"}, .{"me"},
});

/// Where a lean may be resolved — the whole precision story in one field.
/// A `free` name searches the seed's package nearest-first; a `module` member
/// searches only the file its qualifier imported; a `receiver` member
/// (`self.markDirty`) searches only the seed's own file, since a method of a
/// local value lives with the type that declares it.
const Reach = enum { free, module, receiver };

/// One borrowed identifier: `name`, plus the single dotted head it hangs off
/// (`""` when it stands free) and the reach that head grants it.
const Lean = struct { name: []const u8, qual: []const u8, reach: Reach };

/// The symbols `body` (one function region, living at doc `home`) leans on,
/// resolved to their definition sites. `own` is the seed's own name, `max` the
/// row cap; `docs` may carry blanked ("") entries for files the caller has
/// already ruled out as non-source.
pub fn resolve(
    a: std.mem.Allocator,
    docs: []const []const u8,
    paths: []const []const u8,
    home: u32,
    body: []const u8,
    own: []const u8,
    max: usize,
) !Resolved {
    // The neighborhood shares the seed's extension, so one look at the seed's
    // path decides for the whole pass whether tags open text regions.
    const woven = weaves(paths[home]);
    const code = try scrub(a, body, woven);
    var bound: std.StringHashMapUnmanaged(void) = .empty;
    try bindings(a, &bound, code);

    const leaned = try borrowed(a, code, own, &bound);
    if (leaned.len == 0) return .{ .items = &.{}, .total = 0 };

    const sites = try a.alloc(?Dependency, leaned.len);
    @memset(sites, null);
    var alias: std.StringHashMapUnmanaged(u32) = .empty;

    var scrubber = Scrubber{ .a = a, .weaves = woven };
    const near = try neighborhood(a, docs, paths, home);
    try resolveFree(a, docs, paths, home, near, leaned, sites, &alias, &scrubber);
    try resolveMembers(a, docs, home, leaned, sites, &alias, &scrubber);

    var out: std.ArrayList(Dependency) = .empty;
    var total: usize = 0;
    for (sites) |maybe| if (maybe) |dep| {
        total += 1;
        if (out.items.len < max) try out.append(a, dep);
    };
    return .{ .items = try out.toOwnedSlice(a), .total = total };
}

// ── reading the body ─────────────────────────────────────────────────────────

/// `body` with every comment and string byte replaced by a space (newlines
/// kept), so all downstream reads are plain byte geometry on identical offsets
/// — no mask to thread, and no `def` inside a docstring to mistake for code.
fn scrub(a: std.mem.Allocator, body: []const u8, woven: bool) ![]const u8 {
    return scrubInto(try a.alloc(u8, body.len), body, woven);
}

/// One growable buffer that scrubs whole documents in turn. Resolution reads
/// many files looking for declarations, and a `def foo` quoted in a docstring
/// is not one — but each doc's scrub is consumed before the next begins, so
/// they can all share a single allocation.
const Scrubber = struct {
    a: std.mem.Allocator,
    weaves: bool,
    buf: []u8 = &.{},

    /// `doc` with its comments and strings blanked. Byte offsets and line
    /// numbers are unchanged, so a caller may index the raw doc with them.
    fn code(self: *Scrubber, doc: []const u8) ![]const u8 {
        if (self.buf.len < doc.len) self.buf = try self.a.alloc(u8, doc.len);
        return scrubInto(self.buf, doc, self.weaves);
    }
};

/// `scrub` into a caller-owned buffer (`out.len >= body.len`), so a pass that
/// scrubs many documents reuses one allocation.
fn scrubInto(out: []u8, body: []const u8, woven: bool) []const u8 {
    var state: lexspan.Lex = .code;
    var escaped = false;
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        const at = i;
        if (lexspan.lexByte(body, &i, &state, &escaped)) {
            out[at] = body[at];
            continue;
        }
        // lexByte may have consumed a second byte (`//`, `/*`, `*/`).
        for (out[at .. i + 1], body[at .. i + 1]) |*o, b| o.* = if (b == '\n') '\n' else ' ';
    }
    if (woven) blankContent(out[0..body.len], body);
    return out[0..body.len];
}

/// Extensions whose files weave markup through the code stream. A file-shape
/// read, not a language table: what it decides is whether `<p>` can open a text
/// region, never what any name means.
const weavers = std.StaticStringMap(void).initComptime(.{
    .{"tsx"},  .{"jsx"}, .{"vue"}, .{"svelte"}, .{"astro"},
    .{"html"}, .{"htm"}, .{"php"}, .{"erb"},    .{"heex"},
    .{"eex"},  .{"hbs"}, .{"ejs"}, .{"twig"},   .{"blade"},
});

/// Does this path name a file that weaves markup through its code? The shared
/// extension read carries the dot (`.tsx`), which the table above does not.
fn weaves(path: []const u8) bool {
    const ext = spans.extensionOf(path);
    return ext.len > 1 and weavers.has(ext[1..]);
}

/// Blank everything a markup file weaves around its code. A component's copy
/// lives in the code stream — `<code>vector(256)</code> column. The HNSW index
/// is picked automatically` — and its attribute names sit there too
/// (`aria-label`, `width=`); every word of both reads like an identifier. So
/// tag content and attribute names are blanked the way a string literal is,
/// while the tag's own name (a component the file really does depend on) and
/// every `{…}` container (the code the markup carries) survive untouched.
///
/// Structure is read from `raw`, not from the scrub: a `${…}` interpolation
/// leaves its braces behind when the string around it is blanked, and a
/// container that never closes would swallow the tag it belongs to.
fn blankContent(out: []u8, raw: []const u8) void {
    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        if (out[i] != '<') continue;
        const tag = tagEnd(raw, i) orelse continue;
        _ = blankRegion(out, raw, nameEnd(raw, i), tag); // attribute names
        i = blankRegion(out, raw, tag + 1, out.len) - 1; // content, to the next tag
    }
}

/// Blank `out[from..to]`, keeping newlines and the contents of `{…}` containers.
/// Stops early at a `<` outside a container: that byte opens the next tag.
fn blankRegion(out: []u8, raw: []const u8, from: usize, to: usize) usize {
    var depth: usize = 0;
    var k = from;
    while (k < to) : (k += 1) {
        const c = raw[k];
        if (c == '<' and depth == 0) break;
        if (c == '{') {
            depth += 1;
        } else if (c == '}') {
            depth -|= 1;
        } else if (depth == 0 and c != '\n') out[k] = ' ';
    }
    return k;
}

/// Where the tag name that starts at `at` ends — the component or element the
/// markup names, which the file genuinely depends on.
fn nameEnd(out: []const u8, at: usize) usize {
    var i = at + 1;
    if (i < out.len and out[i] == '/') i += 1;
    while (i < out.len and (isIdentByte(out[i]) or out[i] == '.')) i += 1;
    return i;
}

/// Where the `<` at `at` closes as a TAG, rather than as a comparison or a
/// generic. An identifier must follow the `<` immediately (`< b` is arithmetic)
/// and may not precede it (`Vec<u8>` is a generic). Between there and the `>`,
/// only what an attribute list can hold may appear — names, `=`, `/`, `-`, `:`,
/// `.`, and `{…}` containers — so one operator (`r.rank <keep && r.score >
/// floor`) is enough to say this was arithmetic all along.
fn tagEnd(raw: []const u8, at: usize) ?usize {
    if (at > 0 and isIdentByte(raw[at - 1])) return null;
    var i = at + 1;
    if (i < raw.len and raw[i] == '/') i += 1;
    if (i >= raw.len or !isIdentStart(raw[i])) return null;
    var depth: usize = 0;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (c == '"' or c == '\'' or c == '`') {
            i = literalEnd(raw, i) orelse return null; // a value holds anything
            continue;
        }
        if (depth > 0) {
            switch (c) {
                '{' => depth += 1,
                '}' => depth -= 1,
                else => {},
            }
            continue;
        }
        switch (c) {
            '>' => return i,
            '{' => depth += 1,
            '=', '/', '-', ':', '.', ' ', '\t', '\r', '\n' => {},
            else => if (!isIdentByte(c)) return null,
        }
    }
    return null;
}

/// The closing quote of the literal opening at `at`, honoring backslash escapes.
fn literalEnd(raw: []const u8, at: usize) ?usize {
    const quote = raw[at];
    var i = at + 1;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '\\') {
            i += 1;
        } else if (raw[i] == quote) return i;
    }
    return null;
}

/// Every name the region introduces: header parameters, then the per-line
/// binding forms. Erring toward binding is deliberate — a false bind omits one
/// tangential edge, while a missed bind resolves a local against the corpus.
fn bindings(a: std.mem.Allocator, set: *std.StringHashMapUnmanaged(void), code: []const u8) !void {
    try bindParams(a, set, code);
    var lines = std.mem.splitScalar(u8, code, '\n');
    while (lines.next()) |line| try bindLine(a, set, line);
}

/// Parameters of the region's own header. The `(` must open on the header line
/// (the first code line that is not a decorator or attribute), so a `test "…"`
/// block or a paren-less header contributes nothing rather than mistaking a
/// call's arguments deep in the body for a parameter list.
fn bindParams(a: std.mem.Allocator, set: *std.StringHashMapUnmanaged(void), code: []const u8) !void {
    const head = headerLine(code) orelse return;
    const open = (std.mem.indexOfScalar(u8, code[head.start..head.end], '(') orelse return) + head.start;
    var depth: usize = 0;
    var item = open + 1;
    for (code[open..], open..) |c, i| {
        switch (c) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => {
                depth -= 1;
                if (depth == 0) return bindLeading(a, set, code[item..i]);
            },
            ',' => if (depth == 1) {
                try bindLeading(a, set, code[item..i]);
                item = i + 1;
            },
            else => {},
        }
    }
}

/// The region's header line: the first non-blank code line that is not a
/// decorator (`@…`) or attribute (`#[…]`), as `[start, end)` byte offsets.
fn headerLine(code: []const u8) ?struct { start: usize, end: usize } {
    var start: usize = 0;
    while (start < code.len) {
        const end = std.mem.indexOfScalarPos(u8, code, start, '\n') orelse code.len;
        const text = std.mem.trim(u8, code[start..end], " \t\r");
        const decoration = text.len == 0 or text[0] == '@' or std.mem.startsWith(u8, text, "#[");
        if (!decoration) return .{ .start = start, .end = end };
        if (end >= code.len) break;
        start = end + 1;
    }
    return null;
}

/// One parameter item → the name it introduces: the first identifier past any
/// modifier, so `comptime T: type`, `&self`, and `mut buf: []u8` all bind the
/// right word.
fn bindLeading(a: std.mem.Allocator, set: *std.StringHashMapUnmanaged(void), item: []const u8) !void {
    var i: usize = 0;
    while (nextIdent(item, &i)) |word| {
        if (modifiers.has(word)) continue;
        try set.put(a, word, {});
        return;
    }
}

/// The binding forms one line can carry. Each is a geometry read on scrubbed
/// bytes: `:=` short declarations, a `const`/`var`/`let` name list, a bare
/// assignment with a plain left side, `for … in …`, `… as name`, and Zig-style
/// `) |capture|` bars.
fn bindLine(a: std.mem.Allocator, set: *std.StringHashMapUnmanaged(void), line: []const u8) !void {
    if (std.mem.indexOf(u8, line, ":=")) |p| {
        try bindAll(a, set, line[0..p]);
    } else if (afterKeyword(line, "const") orelse afterKeyword(line, "var") orelse afterKeyword(line, "let")) |rest| {
        try bindAll(a, set, upToAny(rest, "=:;"));
    } else if (assignAt(line)) |p| {
        if (plainNames(line[0..p])) try bindAll(a, set, line[0..p]);
    }
    if (afterKeyword(line, "for")) |rest| {
        if (afterKeyword(rest, "in")) |_| try bindAll(a, set, upToKeyword(rest, "in"));
    }
    if (afterKeyword(line, "as")) |rest| try bindLeading(a, set, rest);
    try bindCaptures(a, set, line);
}

/// Zig/Rust-style capture bars — `) |item|`, `catch |err|`, `else |err|`. A
/// bare `a | b` never qualifies, so bitwise-or is not mistaken for a binding.
fn bindCaptures(a: std.mem.Allocator, set: *std.StringHashMapUnmanaged(void), line: []const u8) !void {
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, line, i, '|')) |open| {
        const close = std.mem.indexOfScalarPos(u8, line, open + 1, '|') orelse return;
        const before = std.mem.trimEnd(u8, line[0..open], " \t");
        if (before.len > 0 and (before[before.len - 1] == ')' or
            endsWithKeyword(before, "catch") or endsWithKeyword(before, "else")))
            try bindAll(a, set, line[open + 1 .. close]);
        i = close + 1;
    }
}

fn bindAll(a: std.mem.Allocator, set: *std.StringHashMapUnmanaged(void), text: []const u8) !void {
    var i: usize = 0;
    while (nextIdent(text, &i)) |word| {
        if (!keywords.has(word)) try set.put(a, word, {});
    }
}

/// A maximal run of identifiers separated by nothing but whitespace, and how
/// many of them are plain (not keywords). Code punctuates its operands, so a
/// run of three plain words in a row is prose — JSX text between tags, a shell
/// command line, a sentence — and none of its words name a corpus symbol.
fn wordRun(code: []const u8, from: usize) struct { end: usize, plain: usize } {
    var i = from;
    var plain: usize = 0;
    while (i < code.len and isIdentStart(code[i])) {
        const word = i;
        while (i < code.len and isIdentByte(code[i])) i += 1;
        if (!keywords.has(code[word..i])) plain += 1;
        const gap = i;
        while (i < code.len and (code[i] == ' ' or code[i] == '\t' or code[i] == '\n' or code[i] == '\r')) i += 1;
        if (i == gap) break; // punctuation, not whitespace: the run ends here
    }
    return .{ .end = i, .plain = plain };
}

/// Every code identifier the body borrows from outside itself, in first-use
/// order, deduped by (name, qualifier).
fn borrowed(
    a: std.mem.Allocator,
    code: []const u8,
    own: []const u8,
    bound: *const std.StringHashMapUnmanaged(void),
) ![]const Lean {
    var out: std.ArrayList(Lean) = .empty;
    var i: usize = 0;
    while (i < code.len) {
        if (!isIdentStart(code[i])) {
            i += 1;
            continue;
        }
        const run = wordRun(code, i);
        if (run.plain >= 3) {
            i = run.end; // prose, not code — JSX text, a command line, a sentence
            continue;
        }
        const start = i;
        while (i < code.len and isIdentByte(code[i])) i += 1;
        const name = code[start..i];

        // `title=` / `width={…}` / `silent_404=True`: an unspaced `=` marks an
        // attribute or keyword-argument label. Every formatter in the corpus
        // spaces a real assignment, so the tight form names a field, not a symbol.
        if (i < code.len and code[i] == '=' and (i + 1 >= code.len or code[i + 1] != '=')) continue;

        var qual: []const u8 = "";
        if (start > 0) switch (code[start - 1]) {
            // A language builtin (`@import`, `@intCast`) — never a corpus symbol.
            '@' => continue,
            // A markup tag the runtime provides: `<div>`, `</section>`. Only
            // lowercase — `<Crosshair …>` names a component the seed borrows.
            '<' => if (std.ascii.isLower(name[0])) continue,
            '/' => if (start > 1 and code[start - 2] == '<' and std.ascii.isLower(name[0])) continue,
            '.' => {
                // Only a one-level `head.member` is resolvable: an enum literal
                // (`.file`), a struct-literal field, a member off a call result,
                // and anything deeper in a chain name nothing the corpus holds.
                if (start < 2 or !isIdentByte(code[start - 2])) continue;
                var q = start - 1;
                while (q > 0 and isIdentByte(code[q - 1])) q -= 1;
                if (q > 0 and code[q - 1] == '.') continue;
                qual = code[q .. start - 1];
            },
            else => {},
        };

        if (name.len < 3 or std.mem.eql(u8, name, own) or keywords.has(name)) continue;

        const reach: Reach = if (qual.len == 0) reach: {
            if (bound.contains(name)) continue; // the body's own binding
            break :reach .free;
        } else if (bound.contains(qual) or receivers.has(qual))
            .receiver
        else if (keywords.has(qual))
            continue // a member of the language itself
        else
            .module;

        if (seen(out.items, name, qual)) continue;
        try out.append(a, .{ .name = name, .qual = qual, .reach = reach });
        if (out.items.len >= max_leans) break;
    }
    return out.toOwnedSlice(a);
}

// ── finding their homes ──────────────────────────────────────────────────────

/// The docs resolution may consider, nearest first: same package as the seed,
/// same language, ordered by how much of the seed's path they share (so the
/// seed's own file answers first, then its directory, then the package).
fn neighborhood(a: std.mem.Allocator, docs: []const []const u8, paths: []const []const u8, home: u32) ![]const u32 {
    const seed = paths[home];
    const ext = spans.extensionOf(seed);
    const root = packageRoot(paths, seed);

    var ids: std.ArrayList(u32) = .empty;
    for (docs, paths, 0..) |doc, path, d| {
        if (doc.len == 0) continue; // blanked by the caller: not source
        if (!std.mem.startsWith(u8, path, root)) continue;
        if (ext.len > 0 and !std.mem.endsWith(u8, path, ext)) continue;
        try ids.append(a, @intCast(d));
    }
    const order = Nearness{ .paths = paths, .seed = seed };
    std.mem.sort(u32, ids.items, order, Nearness.closer);
    return ids.toOwnedSlice(a);
}

const Nearness = struct {
    paths: []const []const u8,
    seed: []const u8,

    /// The seed's own file first; then production code before fixtures and
    /// codegen (a test's local stub of `connect_call` is not what the seed
    /// leans on); then by how much of the seed's path a candidate shares.
    fn closer(self: Nearness, x: u32, y: u32) bool {
        const px = self.paths[x];
        const py = self.paths[y];
        if (std.mem.eql(u8, px, self.seed) != std.mem.eql(u8, py, self.seed))
            return std.mem.eql(u8, px, self.seed);
        const sx = sidelined(px);
        const sy = sidelined(py);
        if (sx != sy) return !sx;
        const cx = sharedPrefix(px, self.seed);
        const cy = sharedPrefix(py, self.seed);
        return if (cx == cy) x < y else cx > cy;
    }
};

/// Directory and filename words that mark a file as a stand-in for the real
/// thing. Whole words only: `latest.py` and `contest.go` are production.
const sidelines = std.StaticStringMap(void).initComptime(.{
    .{"test"},    .{"tests"},    .{"testdata"}, .{"spec"},  .{"specs"},
    .{"mock"},    .{"mocks"},    .{"fake"},     .{"fakes"}, .{"stub"},
    .{"stubs"},   .{"fixture"},  .{"fixtures"}, .{"bench"}, .{"benches"},
    .{"example"}, .{"examples"}, .{"stories"},  .{"story"},
});

/// Is this file's declaration of a name the one production code means? Tests,
/// fixtures, benchmarks, and codegen all declare names that shadow the real
/// ones; they still resolve, but only after every candidate that doesn't.
fn sidelined(path: []const u8) bool {
    if (signals.isGeneratedPath(path)) return true;
    var word = std.mem.tokenizeAny(u8, path, "/._-");
    while (word.next()) |w| if (sidelines.has(w)) return true;
    return false;
}

/// The seed's package: the deepest ancestor directory of `seed` that holds a
/// build manifest in the corpus, or "" (the whole corpus) when none does.
fn packageRoot(paths: []const []const u8, seed: []const u8) []const u8 {
    var best: []const u8 = "";
    for (paths) |path| {
        const cut = if (std.mem.lastIndexOfScalar(u8, path, '/')) |s| s + 1 else 0;
        if (!manifests.has(path[cut..])) continue;
        const dir = path[0..cut];
        if (dir.len <= best.len or !std.mem.startsWith(u8, seed, dir)) continue;
        best = dir;
    }
    return best;
}

/// One candidate declaration site, kept with the raw (unscrubbed) line so
/// `admit` can still read an import literal out of it.
const Site = struct { doc: u32, line: u32, text: []const u8 };

/// Resolve the free (unqualified) leans against the neighborhood. The nearest
/// declaration wins, but only after the pass has weighed how many files of the
/// package declare the same name: one or a few means a specific symbol, a
/// packageful means an ambient word (a builtin, an import convention, a markup
/// tag, a prose noun) that no single site can honestly stand for. One batched
/// `PatternSet` names the candidates on a line; the shared confidence signal
/// confirms which of them the line declares.
fn resolveFree(
    a: std.mem.Allocator,
    docs: []const []const u8,
    paths: []const []const u8,
    home: u32,
    near: []const u32,
    leaned: []const Lean,
    sites: []?Dependency,
    alias: *std.StringHashMapUnmanaged(u32),
    scrubber: *Scrubber,
) !void {
    var names: std.ArrayList([]const u8) = .empty;
    var owner: std.ArrayList(usize) = .empty;
    for (leaned, 0..) |lean, k| {
        if (lean.reach != .free or names.items.len >= max_free) continue;
        try names.append(a, lean.name);
        try owner.append(a, k);
    }
    if (names.items.len == 0) return;

    var wset = try patterns.wordSet(a, names.items);
    defer wset.deinit(a);
    var scratch = try wset.scratch(a);
    defer scratch.deinit(a);

    // The seed's own file may name some of these symbols on an import line.
    // That is stronger evidence than any count — it says which file the symbol
    // comes from — so a hinted name skips the ambience test, and the path words
    // of the hint rank its candidate sites.
    const hint = try a.alloc(?[]const u8, names.items.len);
    @memset(hint, null);
    imports(docs[home], names.items, hint);

    const nearest = try a.alloc(?Site, names.items.len);
    @memset(nearest, null);
    const score = try a.alloc(u16, names.items.len);
    @memset(score, 0);
    const homes = try a.alloc(u16, names.items.len);
    @memset(homes, 0);
    // A name is settled once no further evidence can change its verdict: the
    // seed's own file declared it, or the package already declares it too often.
    const settled = try a.alloc(bool, names.items.len);
    @memset(settled, false);
    const here = try a.alloc(bool, names.items.len);
    var open = names.items.len;
    var hits: std.ArrayList(u32) = .empty;

    scan: for (near) |d| {
        const doc = docs[d];
        if (!wset.anyMatch(doc, &scratch)) continue;
        const code = try scrubber.code(doc);
        @memset(here, false);
        var pos: usize = 0;
        var lineno: u32 = 1;
        while (pos < code.len) {
            const nl = std.mem.indexOfScalarPos(u8, code, pos, '\n') orelse code.len;
            const line = code[pos..nl];
            hits.clearRetainingCapacity();
            try wset.lineHits(line, &scratch, a, &hits);
            for (hits.items) |hi| {
                if (settled[hi] or here[hi]) continue;
                if (!declares(line, names.items[hi])) continue;
                here[hi] = true;
                homes[hi] += 1;
                const near_score = if (hint[hi]) |h| shared(paths[d], h) else 0;
                if (nearest[hi] == null or near_score > score[hi]) {
                    nearest[hi] = .{ .doc = d, .line = lineno, .text = doc[pos..nl] };
                    score[hi] = near_score;
                }
                if (d == home or (hint[hi] == null and homes[hi] > max_homes)) {
                    settled[hi] = true;
                    open -= 1;
                    if (open == 0) break :scan;
                }
            }
            if (nl >= code.len) break;
            pos = nl + 1;
            lineno += 1;
        }
    }

    for (nearest, homes, hint, owner.items, names.items) |maybe, seen_in, hinted, k, name| {
        const site = maybe orelse continue;
        const ambient = seen_in > max_homes and site.doc != home and hinted == null;
        if (ambient) continue;
        try admit(a, paths, alias, sites, k, name, site.doc, site.line, site.text);
    }
}

/// Import verbs that open a statement naming symbols from another file. A
/// hint line has to START with one, so a sentence about importing something
/// cannot pose as evidence.
const importers = std.StaticStringMap(void).initComptime(.{
    .{"import"}, .{"from"},    .{"require"}, .{"use"},
    .{"using"},  .{"include"}, .{"open"},    .{"with"},
});

/// Record, for each name the seed's file imports by name, the import line that
/// brought it in. The line is read raw: the module path lives inside a string
/// literal that the scrub blanks, and those path words are the whole point.
fn imports(doc: []const u8, names: []const []const u8, hint: []?[]const u8) void {
    var pos: usize = 0;
    while (pos < doc.len) {
        const nl = std.mem.indexOfScalarPos(u8, doc, pos, '\n') orelse doc.len;
        const line = std.mem.trim(u8, doc[pos..nl], " \t");
        pos = nl + 1;
        var word = std.mem.tokenizeAny(u8, line, " \t({");
        const verb = word.next() orelse continue;
        if (!importers.has(verb)) continue;
        for (names, hint) |name, *slot| {
            if (slot.* == null and wholeWord(line, name) != null) slot.* = line;
        }
        if (nl >= doc.len) break;
    }
}

/// How much of an import line's module path a candidate's own path repeats —
/// `'./store'` prefers `taskboard/store.ts`, `core.foundation.telemetry.log`
/// prefers `core/foundation/telemetry/log.py`. Separators differ per language;
/// the words between them are the same words, so splitting on both reads any
/// module path without knowing whose it is.
fn shared(path: []const u8, line: []const u8) u16 {
    const seps = "/.,'\"`{}()[]<>=*;: \t";
    var count: u16 = 0;
    var word = std.mem.tokenizeAny(u8, line, seps);
    while (word.next()) |w| {
        if (w.len < 3 or importers.has(w) or declarators.has(w)) continue;
        var have = std.mem.tokenizeAny(u8, path, seps ++ "-");
        while (have.next()) |h| if (std.mem.eql(u8, h, w)) {
            count += 1;
            break;
        };
    }
    return count;
}

/// Record — or refuse — one resolved free identifier. A name bound to a module
/// literal the corpus does not contain is external: the seed leans on the
/// language or a vendored package, not on anything an edit here can move, so
/// the row is dropped. A name bound to a module the corpus DOES contain
/// becomes the scope its members resolve inside.
fn admit(
    a: std.mem.Allocator,
    paths: []const []const u8,
    alias: *std.StringHashMapUnmanaged(u32),
    sites: []?Dependency,
    k: usize,
    name: []const u8,
    doc: u32,
    line: u32,
    text: []const u8,
) !void {
    if (importTarget(text)) |target| {
        const to = moduleDoc(paths, paths[doc], target) orelse return;
        try alias.put(a, name, to);
    }
    sites[k] = .{ .symbol = name, .doc = doc, .line = line };
}

/// Resolve `head.member` leans inside the one file their head names — the
/// module it imported, or the seed's own file when the head is a local value
/// or a receiver. A member whose head names neither stays unresolved: far
/// better than the nearest same-named declaration in the tree.
fn resolveMembers(
    a: std.mem.Allocator,
    docs: []const []const u8,
    home: u32,
    leaned: []const Lean,
    sites: []?Dependency,
    alias: *const std.StringHashMapUnmanaged(u32),
    scrubber: *Scrubber,
) !void {
    for (leaned, 0..) |lean, k| {
        const d = switch (lean.reach) {
            .free => continue,
            .receiver => home,
            .module => alias.get(lean.qual) orelse continue,
        };
        const line = declarationLine(try scrubber.code(docs[d]), lean.name) orelse continue;
        sites[k] = .{
            .symbol = try std.fmt.allocPrint(a, "{s}.{s}", .{ lean.qual, lean.name }),
            .doc = d,
            .line = line,
        };
    }
}

/// The 1-based line on which scrubbed `code` declares `name`, or null.
fn declarationLine(code: []const u8, name: []const u8) ?u32 {
    var pos: usize = 0;
    var lineno: u32 = 1;
    while (pos < code.len) : (lineno += 1) {
        const nl = std.mem.indexOfScalarPos(u8, code, pos, '\n') orelse code.len;
        if (declares(code[pos..nl], name)) return lineno;
        if (nl >= code.len) break;
        pos = nl + 1;
    }
    return null;
}

/// Does `line` read as the HEAD of a declaration of `name`, or merely as a line
/// that uses it? The shared geometry signal answers the suffix side; this reads
/// the prefix, where every word between the statement start and the name must be
/// a declaration word. So `pub fn walkFresh(` and `export const K =` are heads,
/// while `if not isinstance(r.value, dict):` and `return handlers[name](req)`
/// are uses that happen to wear a declaration's punctuation. A group that CLOSES
/// before the name is a receiver or parameter shape rather than prefix words, so
/// Go's `func (s *Service) Charge(` still reads as a head; a group still open at
/// the name means the name is an element of it (`("idle", False, True,`), whose
/// neighbors are prefix words like any other.
fn declares(line: []const u8, name: []const u8) bool {
    if (signals.declarationConfidence(line, name) == 0) return false;
    const cut = wholeWord(line, name) orelse return false;
    var said: usize = 0;
    var i: usize = 0;
    while (i < cut) {
        const c = line[i];
        if (c == '(' or c == '[' or c == '{') {
            i = closes(line, i, cut) orelse i + 1;
            continue;
        }
        if (std.ascii.isDigit(c)) return false; // a literal: the name is an element
        if (isIdentStart(c)) {
            const word = i;
            while (i < cut and isIdentByte(line[i])) i += 1;
            if (!declarators.has(line[word..i])) return false;
            said += 1;
            continue;
        }
        i += 1;
    }
    // With no declaration word in front of it, the line must still SAY it binds:
    // a top-level `=` or `:` after the name (`_log = get(…)`, `vector_add:`,
    // `field: u32 = 0,`). A bare call — `dict(payload or {}),` — is an argument.
    return said > 0 or binds(line[cut + name.len ..]);
}

/// Does what follows the name bind it, at the statement's own bracket level?
fn binds(rest: []const u8) bool {
    var depth: usize = 0;
    for (rest) |c| switch (c) {
        '(', '[', '{' => depth += 1,
        ')', ']', '}' => depth -|= 1,
        '=', ':' => if (depth == 0) return true,
        else => {},
    };
    return false;
}

/// Where the group opening at `at` closes, if it closes before `cut`.
fn closes(line: []const u8, at: usize, cut: usize) ?usize {
    var depth: usize = 0;
    var i = at;
    while (i < cut) : (i += 1) {
        switch (line[i]) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => {
                depth -= 1;
                if (depth == 0) return i + 1;
            },
            else => {},
        }
    }
    return null;
}

/// Where `name` first appears in `line` as a whole word.
fn wholeWord(line: []const u8, name: []const u8) ?usize {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, line, from, name)) |at| : (from = at + 1) {
        const before_ok = at == 0 or !isIdentByte(line[at - 1]);
        const end = at + name.len;
        if (before_ok and (end >= line.len or !isIdentByte(line[end]))) return at;
    }
    return null;
}

/// The module literal an import-shaped declaration names, or null when the
/// line binds a value rather than a module. Shape, not a language table: the
/// line must carry an import verb AND a quoted literal, so `const std =
/// @import("std")` reads as a module while `const tag = "widget"` does not.
fn importTarget(line: []const u8) ?[]const u8 {
    const verbs = [_][]const u8{ "import", "require", "include", "use" };
    var verbed = false;
    for (verbs) |v| verbed = verbed or hasKeyword(line, v);
    if (!verbed) return null;
    for (line, 0..) |c, i| {
        if (c != '"' and c != '\'') continue;
        const end = std.mem.indexOfScalarPos(u8, line, i + 1, c) orelse return null;
        return line[i + 1 .. end];
    }
    return null;
}

/// The corpus doc an import literal names — resolved relative to the importing
/// file first, then as a corpus-rooted path — or null when the target lives
/// outside the corpus (a standard library, a vendored package, a bare name).
fn moduleDoc(paths: []const []const u8, from: []const u8, target: []const u8) ?u32 {
    var buf: [1024]u8 = undefined;
    const dir = if (std.mem.lastIndexOfScalar(u8, from, '/')) |s| from[0 .. s + 1] else "";
    if (joinNormal(&buf, dir, target)) |joined| {
        if (docAt(paths, joined)) |d| return d;
    }
    return docAt(paths, target);
}

/// `dir` + `rel` with `.` and `..` segments folded, or null when the result
/// would escape the corpus root or overflow the buffer.
fn joinNormal(buf: []u8, dir: []const u8, rel: []const u8) ?[]const u8 {
    if (dir.len > buf.len) return null;
    @memcpy(buf[0..dir.len], dir);
    var n = dir.len;
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (n == 0) return null;
            n = if (std.mem.lastIndexOfScalar(u8, buf[0 .. n - 1], '/')) |s| s + 1 else 0;
            continue;
        }
        if (n + seg.len + 1 > buf.len) return null;
        @memcpy(buf[n..][0..seg.len], seg);
        n += seg.len;
        buf[n] = '/';
        n += 1;
    }
    return if (n == 0) null else buf[0 .. n - 1];
}

fn docAt(paths: []const []const u8, want: []const u8) ?u32 {
    for (paths, 0..) |path, d| if (std.mem.eql(u8, path, want)) return @intCast(d);
    return null;
}

// ── byte helpers ─────────────────────────────────────────────────────────────

// The identifier vocabulary is `anatomy/token.zig` — shared with kinship's
// structure fingerprints so token boundaries cannot drift between planes.
const token = @import("token.zig");
const isIdentStart = token.isIdentStart;
const isIdentByte = token.isIdentByte;
const nextIdent = token.nextIdent;

fn seen(items: []const Lean, name: []const u8, qual: []const u8) bool {
    for (items) |x| if (std.mem.eql(u8, x.name, name) and std.mem.eql(u8, x.qual, qual)) return true;
    return false;
}

fn sharedPrefix(x: []const u8, y: []const u8) usize {
    const n = @min(x.len, y.len);
    var i: usize = 0;
    while (i < n and x[i] == y[i]) i += 1;
    return i;
}

/// Is `word` present in `text` as a whole word?
fn hasKeyword(text: []const u8, word: []const u8) bool {
    return keywordAt(text, word) != null;
}

/// `text` after its first whole-word occurrence of `word`, or null.
fn afterKeyword(text: []const u8, word: []const u8) ?[]const u8 {
    const at = keywordAt(text, word) orelse return null;
    return text[at + word.len ..];
}

/// `text` up to its first whole-word occurrence of `word`.
fn upToKeyword(text: []const u8, word: []const u8) []const u8 {
    return text[0..(keywordAt(text, word) orelse text.len)];
}

fn keywordAt(text: []const u8, word: []const u8) ?usize {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, word)) |p| : (i = p + 1) {
        const before_ok = p == 0 or !isIdentByte(text[p - 1]);
        const after = p + word.len;
        if (before_ok and (after >= text.len or !isIdentByte(text[after]))) return p;
    }
    return null;
}

fn endsWithKeyword(text: []const u8, word: []const u8) bool {
    if (!std.mem.endsWith(u8, text, word)) return false;
    const at = text.len - word.len;
    return at == 0 or !isIdentByte(text[at - 1]);
}

fn upToAny(text: []const u8, stops: []const u8) []const u8 {
    return text[0 .. std.mem.indexOfAny(u8, text, stops) orelse text.len];
}

/// The offset of a plain assignment `=` at nesting depth zero — never `==`,
/// `!=`, `<=`, `>=`, or `=>`.
fn assignAt(line: []const u8) ?usize {
    var depth: i32 = 0;
    for (line, 0..) |c, i| {
        switch (c) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => depth -= 1,
            '=' => {
                if (depth != 0) continue;
                const prev: u8 = if (i == 0) ' ' else line[i - 1];
                const next: u8 = if (i + 1 >= line.len) ' ' else line[i + 1];
                if (prev == '=' or prev == '!' or prev == '<' or prev == '>' or
                    next == '=' or next == '>') continue;
                return i;
            },
            else => {},
        }
    }
    return null;
}

/// Is this assignment's left side a plain name list (`a`, `a, b`) rather than
/// a field, index, or call target? Only a plain list introduces names.
fn plainNames(lhs: []const u8) bool {
    if (std.mem.indexOfNone(u8, lhs, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_, \t") != null) return false;
    return std.mem.indexOfNone(u8, lhs, " \t,") != null;
}

// ── tests ────────────────────────────────────────────────────────────────────

const t = std.testing;

/// Resolve over a two-file corpus, returning the rendered `symbol@path:line`
/// rows so a test can assert on exactly what an agent would read.
fn rowsOf(a: std.mem.Allocator, docs: []const []const u8, paths: []const []const u8, home: u32, body: []const u8, own: []const u8) ![]const Dependency {
    const r = try resolve(a, docs, paths, home, body, own, 64);
    return r.items;
}

fn hasSymbol(rows: []const Dependency, symbol: []const u8) bool {
    for (rows) |row| if (std.mem.eql(u8, row.symbol, symbol)) return true;
    return false;
}

test "a function's own parameters and locals are never dependencies" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `gpa`, `roots`, and `out` are parameters; `start` is a local. Each also
    // exists as an unrelated declaration in a sibling file — the exact shape
    // that used to produce a confident, wrong row.
    const docs = [_][]const u8{
        \\const std = @import("std");
        \\fn walk(gpa: std.mem.Allocator, roots: []const []const u8, out: *std.ArrayList(u8)) void {
        \\    const start = out.items.len;
        \\    sweepAll(gpa, roots, out, start);
        \\}
        \\fn sweepAll(gpa: std.mem.Allocator, roots: []const []const u8, out: *std.ArrayList(u8), from: usize) void {
        \\    _ = .{ gpa, roots, out, from };
        \\}
        ,
        \\pub fn unrelated() void {
        \\    const gpa = 1;
        \\    const roots = 2;
        \\    const out = 3;
        \\    const start = 4;
        \\    _ = .{ gpa, roots, out, start };
        \\}
    };
    const paths = [_][]const u8{ "pkg/walk.zig", "pkg/other.zig" };
    const body = docs[0][std.mem.indexOf(u8, docs[0], "fn walk(").?..std.mem.indexOf(u8, docs[0], "fn sweepAll").?];

    const rows = try rowsOf(a, &docs, &paths, 0, body, "walk");
    for ([_][]const u8{ "gpa", "roots", "out", "start", "items", "len", "Allocator" }) |noise|
        try t.expect(!hasSymbol(rows, noise));
    try t.expect(hasSymbol(rows, "sweepAll")); // the one genuine edge survives
}

test "a member of an in-corpus module resolves inside that module" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const docs = [_][]const u8{
        \\const std = @import("std");
        \\const sweep = @import("sweep.zig");
        \\fn walk() void {
        \\    sweep.run();
        \\}
        ,
        \\pub fn run() void {}
        ,
        \\pub fn run() void {} // a decoy `run` nearer the front of the corpus
    };
    const paths = [_][]const u8{ "pkg/walk.zig", "pkg/sweep.zig", "pkg/aaa.zig" };
    const body = docs[0][std.mem.indexOf(u8, docs[0], "fn walk()").?..];

    const rows = try rowsOf(a, &docs, &paths, 0, body, "walk");
    // `sweep.run` lands in sweep.zig, not on the decoy; `std` is external.
    try t.expect(!hasSymbol(rows, "std"));
    for (rows) |row| if (std.mem.eql(u8, row.symbol, "sweep.run")) {
        try t.expectEqual(@as(u32, 1), row.doc);
        return;
    };
    try t.expect(false);
}

test "a method on the receiver resolves in the seed's own file" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const docs = [_][]const u8{
        \\pub const Seqlock = struct {
        \\    pub fn markDirty(self: *Seqlock) void {
        \\        _ = self;
        \\    }
        \\    pub fn markDoubtForever(self: *Seqlock) void {
        \\        self.markDirty();
        \\    }
        \\};
        ,
        "pub fn markDirty() void {} // a decoy in a sibling file",
    };
    const paths = [_][]const u8{ "pkg/seqlock.zig", "pkg/decoy.zig" };
    const body = docs[0][std.mem.indexOf(u8, docs[0], "    pub fn markDoubtForever").?..];

    const rows = try rowsOf(a, &docs, &paths, 0, body, "markDoubtForever");
    for (rows) |row| if (std.mem.eql(u8, row.symbol, "self.markDirty")) {
        try t.expectEqual(@as(u32, 0), row.doc); // the sibling method, not the decoy
        try t.expectEqual(@as(u32, 2), row.line);
        return;
    };
    try t.expect(false);
}

test "resolution never crosses a package boundary" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const docs = [_][]const u8{
        "// build manifest",
        \\fn walk() void {
        \\    helperName();
        \\}
        ,
        "// other package manifest",
        "pub fn helperName() void {}",
    };
    const paths = [_][]const u8{ "mine/build.zig", "mine/walk.zig", "theirs/build.zig", "theirs/help.zig" };
    const body = docs[1];

    const rows = try rowsOf(a, &docs, &paths, 1, body, "walk");
    try t.expect(!hasSymbol(rows, "helperName")); // lives in another package
}

test "packageRoot picks the deepest manifest above the seed" {
    const paths = [_][]const u8{
        "pyproject.toml",
        "libs/kernels/irregex/build.zig",
        "libs/kernels/other/build.zig",
        "libs/kernels/irregex/src/deep/file.zig",
    };
    try t.expectEqualStrings("libs/kernels/irregex/", packageRoot(&paths, paths[3]));
    try t.expectEqualStrings("", packageRoot(&paths, "README.md"));
}

test "joinNormal folds relative segments" {
    var buf: [256]u8 = undefined;
    try t.expectEqualStrings("a/b/c.zig", joinNormal(&buf, "a/b/", "c.zig").?);
    try t.expectEqualStrings("a/c.zig", joinNormal(&buf, "a/b/", "../c.zig").?);
    try t.expectEqualStrings("c.zig", joinNormal(&buf, "a/b/", "../../c.zig").?);
    try t.expectEqual(@as(?[]const u8, null), joinNormal(&buf, "a/", "../../c.zig"));
}

test "importTarget reads module literals, not string values" {
    try t.expectEqualStrings("sweep.zig", importTarget("const sweep = @import(\"sweep.zig\");").?);
    try t.expectEqualStrings("./util", importTarget("const util = require('./util');").?);
    try t.expect(importTarget("const tag = \"widget\";") == null); // a value, not a module
    try t.expect(importTarget("const used = other.used;") == null); // `used` is not `use`
    try t.expect(importTarget("import os") == null); // no literal to judge — fail open
}

test "capture bars bind, bitwise-or does not" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var set: std.StringHashMapUnmanaged(void) = .empty;
    try bindCaptures(a, &set, "    for (paths) |candidate| {");
    try bindCaptures(a, &set, "    const flags = alpha | bravo;");
    try t.expect(set.contains("candidate"));
    try t.expect(!set.contains("alpha"));
    try t.expect(!set.contains("bravo"));
}

test "scrub blanks comments and strings but keeps line geometry" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const src = "fn f() void { // callSecret()\n    const s = \"alsoSecret\";\n}";
    const code = try scrub(arena.allocator(), src, false);
    try t.expectEqual(src.len, code.len);
    try t.expect(std.mem.indexOf(u8, code, "callSecret") == null);
    try t.expect(std.mem.indexOf(u8, code, "alsoSecret") == null);
    try t.expect(std.mem.indexOf(u8, code, "const s =") != null);
    try t.expectEqual(std.mem.count(u8, src, "\n"), std.mem.count(u8, code, "\n"));
}

test "a markup scrub keeps components and containers, drops copy and attributes" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const src =
        \\return (
        \\  <Panel aria-label="x" width={320}>
        \\    every table that carries a <code>vector(256)</code> column is picked
        \\    {rows.map(render)}
        \\  </Panel>
        \\)
    ;
    const code = try scrub(arena.allocator(), src, true);
    try t.expectEqual(src.len, code.len);
    try t.expect(std.mem.indexOf(u8, code, "Panel") != null); // the component is a dependency
    try t.expect(std.mem.indexOf(u8, code, "rows.map(render)") != null); // so is its code
    try t.expect(std.mem.indexOf(u8, code, "320") != null);
    try t.expect(std.mem.indexOf(u8, code, "aria") == null); // an attribute name is not
    try t.expect(std.mem.indexOf(u8, code, "vector") == null); // nor is the copy
    try t.expect(std.mem.indexOf(u8, code, "picked") == null);
    try t.expect(std.mem.indexOf(u8, code, "column") == null);
    try t.expectEqual(std.mem.count(u8, src, "\n"), std.mem.count(u8, code, "\n"));
}

test "a markup scrub survives a template literal in an attribute" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const src =
        \\  <button
        \\    aria-label={title ? `About ${title}` : 'More info'}
        \\    className={`inline-flex ${className ?? ''}`}
        \\    type="button"
        \\  >
        \\    <Info strokeWidth={1.6} />
    ;
    const code = try scrub(arena.allocator(), src, true);
    // Blanking the interpolated string must not unbalance the container and
    // swallow the tag: the attribute names still go, the code still stays.
    try t.expect(std.mem.indexOf(u8, code, "aria") == null);
    try t.expect(std.mem.indexOf(u8, code, "className") == null);
    try t.expect(std.mem.indexOf(u8, code, "strokeWidth") == null);
    try t.expect(std.mem.indexOf(u8, code, "title ?") != null); // container code
    try t.expect(std.mem.indexOf(u8, code, "Info") != null); // the component
    try t.expect(std.mem.indexOf(u8, code, "1.6") != null);
}

test "only markup-weaving extensions open text regions" {
    try t.expect(weaves("clients/web/surfaces/admin/src/components/HelpTip.tsx"));
    try t.expect(weaves("a/b/page.vue"));
    try t.expect(!weaves("clients/web/surfaces/atrium/src/lib/taskboard/store.ts"));
    try t.expect(!weaves("libs/kernels/irregex/src/kernel/compose/leans.zig"));
}

test "a markup scrub leaves comparisons and generics alone" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const src = "const items: Array<Row> = all.filter(r => r.rank <keep && r.score > floor)";
    const code = try scrub(arena.allocator(), src, true);
    try t.expectEqualStrings(src, code);
}

test "declares reads the prefix, not just the punctuation" {
    try t.expect(declares("pub fn walkFresh(gpa: Allocator) !void {", "walkFresh"));
    try t.expect(declares("export function useTaskboard(): Snapshot {", "useTaskboard"));
    try t.expect(declares("func (s *Service) Charge(cents int64) error {", "Charge"));
    try t.expect(declares("_log = get(\"agent.context\")", "_log"));
    try t.expect(declares("    field: u32 = 0,", "field"));
    // Uses wearing a declaration's punctuation.
    try t.expect(!declares("    if not r.ok or not isinstance(r.value, dict):", "isinstance"));
    try t.expect(!declares("        dict(payload or {}),", "dict"));
    try t.expect(!declares("    (3, \"Apollo\", \"active\", True, \"2026-01-03\"),", "True"));
}
