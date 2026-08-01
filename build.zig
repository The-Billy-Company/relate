//! relate build graph — the compression-as-search engine and its CLI.
//!
//! Ships as a **Zig module** (`@import("relate")`) over the `irregex` library
//! and the `gist` chassis (the resident daemon + answer keep the face dials),
//! plus the `relate` binary rooted at `src/surface/face/main.zig`, and the
//! C-ABI dual artifact (`librelate` + `include/relate.h`). The C floors
//! (PCRE2, libsais) ride in with the library; this package adds none of its
//! own. `librelate` dynamically links `libirregex` for the substrate symbols
//! it does not redefine.
//!
//! Test chassis mirrors the library's (kernelkit's shape): a ReleaseSafe
//! brigade-sharded unit-test binary, `check` for the --watch/ZLS loop, and a
//! kcov `coverage` step.

const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const default_target: std.Target.Query = if (builtin.target.os.tag == .macos)
        .{ .os_version_min = .{ .semver = .{ .major = 13, .minor = 0, .patch = 0 } } }
    else
        .{};
    const target = b.standardTargetOptions(.{ .default_target = default_target });
    const optimize = b.standardOptimizeOption(.{});

    // The library and the product chassis beneath, at matching optimize —
    // irregex carries PCRE2 + libsais; gist carries the daemon the answer keep
    // dials. Linking `relate` links the whole stack.
    const irregex_dep = b.dependency("irregex", .{ .target = target, .optimize = optimize });
    const gist_dep = b.dependency("gist", .{ .target = target, .optimize = optimize });
    const deps = [_]std.Build.Module.Import{
        .{ .name = "irregex", .module = irregex_dep.module("irregex") },
        .{ .name = "gist", .module = gist_dep.module("gist") },
    };

    const engine = b.addModule("relate", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
        .imports = &deps,
    });

    // ── the product binary ──
    // Same ReleaseFast product posture as gist's face: a bare `zig build` must
    // never install a slow debug `relate`. `-Dcli-optimize=Debug` still yields
    // a debug CLI; tests keep the standard (safety-checked) default.
    const cli_optimize = b.option(
        std.builtin.OptimizeMode,
        "cli-optimize",
        "optimize mode for the installed relate CLI (default ReleaseFast — the product surface's whole point is speed)",
    ) orelse .ReleaseFast;
    const cli_deps = if (cli_optimize == optimize) deps else engines(b, target, cli_optimize);
    const cli_engine = if (cli_optimize == optimize) engine else b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = cli_optimize,
        .pic = true,
        .imports = &cli_deps,
    });
    // A face main is a thin exe root: real driver code is analyzed inside
    // the relate module (whose root is src/root.zig, so relative imports
    // resolve) and reached as `@import("relate").faces.*` / `.cli.*`.
    const face_imports = [_]std.Build.Module.Import{
        .{ .name = "irregex", .module = if (cli_optimize == optimize)
            irregex_dep.module("irregex")
        else
            b.dependency("irregex", .{ .target = target, .optimize = cli_optimize }).module("irregex") },
        .{ .name = "relate", .module = cli_engine },
    };
    const exe = b.addExecutable(.{
        .name = "relate",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/surface/face/main.zig"),
            .target = target,
            .optimize = cli_optimize,
            .imports = &face_imports,
        }),
    });
    b.installArtifact(exe);

    // ── the C-ABI dual artifact ──
    // Dynamic lib owns the header install. Named `relate` — its symbols and
    // header are this product's. Substrate symbols resolve through a link
    // against libirregex (dynamic), so librelate does not redefine them and a
    // host that also links libgist still sees one vocabulary. Rooted at the
    // export shims, NOT at `src/root.zig`, so the module dependents import
    // never carries a second copy of `relate_run`.
    const irregex_lib = irregex_dep.artifact("irregex");
    const abi = b.createModule(.{
        .root_source_file = b.path("src/surface/ffi/exports.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
        .imports = &.{.{ .name = "irregex", .module = irregex_dep.module("irregex") }},
    });
    abi.linkLibrary(irregex_lib);
    // A shipped dylib has to find its substrate beside itself. `linkLibrary`
    // records only this build tree's own output dir — a RELATIVE
    // `.zig-cache/o/<hash>` path, meaningless on a consumer's machine — so
    // `dlopen("librelate.dylib")` from anywhere else cannot resolve
    // `@rpath/libirregex.dylib` and fails at load. A loader-relative rpath makes
    // the shape we actually ship ("both libraries in one lib dir") the loadable
    // one, without naming an absolute path we do not own.
    abi.addRPathSpecial(if (target.result.os.tag == .macos) "@loader_path" else "$ORIGIN");
    const dynamic_lib = b.addLibrary(.{ .name = "relate", .linkage = .dynamic, .root_module = abi });
    dynamic_lib.installHeader(b.path("include/relate.h"), "relate.h");
    // A host that #includes <relate.h> also needs <gist.h> and <irregex.h>;
    // install them beside ours so one -I covers the stack.
    dynamic_lib.installHeader(gist_dep.path("include/gist.h"), "gist.h");
    dynamic_lib.installHeader(irregex_dep.path("include/irregex.h"), "irregex.h");
    b.installArtifact(dynamic_lib);
    if (target.result.os.tag == .macos) {
        const obj = b.addObject(.{ .name = "relate", .root_module = abi });
        const repack = b.addSystemCommand(&.{ "libtool", "-static", "-o" });
        const aligned_a = repack.addOutputFileArg("librelate.a");
        repack.addArtifactArg(obj);
        b.getInstallStep().dependOn(&b.addInstallLibFile(aligned_a, "librelate.a").step);
    } else {
        const static_lib = b.addLibrary(.{ .name = "relate", .linkage = .static, .root_module = abi });
        b.installArtifact(static_lib);
    }
    b.installArtifact(irregex_lib);

    // ReleaseSafe test binary (differential suites exist to trip safety
    // checks); `-Dtest-optimize=Debug` still yields a steppable binary.
    const test_optimize = b.option(
        std.builtin.OptimizeMode,
        "test-optimize",
        "optimize mode for the unit-test binary (default ReleaseSafe)",
    ) orelse .ReleaseSafe;
    const test_module = if (test_optimize == optimize) engine else b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = test_optimize,
        .pic = true,
        .imports = &engines(b, target, test_optimize),
    });

    const shards = b.option(
        usize,
        "test-shards",
        "how many parallel processes `zig build test` splits the unit-test binary across (default: 2x CPU count; 1 restores a single-process run)",
    ) orelse @min(@max(std.Thread.getCpuCount() catch 1, 1) * 2, 64);
    const brigade = b.dependency("kernelkit", .{}).path("brigade.zig");
    const tests = b.addTest(.{
        .root_module = test_module,
        .test_runner = .{ .path = brigade, .mode = .simple },
    });
    const test_filter = b.option(
        []const u8,
        "test-filter",
        "run only unit tests whose name contains one of these comma-separated substrings",
    );
    const test_skip = b.option(
        []const u8,
        "test-skip",
        "skip unit tests whose name contains one of these comma-separated substrings",
    );

    const test_step = b.step("test", "Run unit tests");
    addShards(b, tests, test_step, shards, test_filter, test_skip);

    const debug_tests = if (test_module == engine) tests else b.addTest(.{
        .root_module = engine,
        .test_runner = .{ .path = brigade, .mode = .simple },
    });
    b.step("check", "Compile tests without running (fast --watch -fincremental loop / ZLS)")
        .dependOn(&debug_tests.step);

    const run_cov = b.addSystemCommand(&.{ "kcov", "--clean", "--include-pattern=src/" });
    run_cov.addArg(b.pathFromRoot(".local/coverage"));
    run_cov.addArtifactArg(debug_tests);
    run_cov.setEnvironmentVariable("BRIGADE_SHARD", "0/1");
    b.step("coverage", "Run unit tests under kcov → .local/coverage/ (Cobertura XML)")
        .dependOn(&run_cov.step);
}

/// The module imports at a given optimize, in the order every module here
/// declares them.
fn engines(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) [2]std.Build.Module.Import {
    return .{
        .{ .name = "irregex", .module = b.dependency("irregex", .{ .target = target, .optimize = optimize }).module("irregex") },
        .{ .name = "gist", .module = b.dependency("gist", .{ .target = target, .optimize = optimize }).module("gist") },
    };
}

/// kernelkit's shard fan-out, restated because this build declares no C-ABI
/// kernel (see _buildkit/build.zig `addShards`).
fn addShards(
    b: *std.Build,
    tests: *std.Build.Step.Compile,
    step: *std.Build.Step,
    shards: usize,
    filter: ?[]const u8,
    skip: ?[]const u8,
) void {
    for (0..shards) |i| {
        const run_shard = b.addRunArtifact(tests);
        run_shard.setEnvironmentVariable("BRIGADE_SHARD", b.fmt("{d}/{d}", .{ i, shards }));
        if (filter) |f| run_shard.setEnvironmentVariable("BRIGADE_FILTER", f);
        if (skip) |s| run_shard.setEnvironmentVariable("BRIGADE_SKIP", s);
        run_shard.expectExitCode(0);
        run_shard.setName(b.fmt("{s} shard {d}/{d}", .{ step.name, i, shards }));
        step.dependOn(&run_shard.step);
    }
}
