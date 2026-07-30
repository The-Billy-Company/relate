//! relate build graph — the compression-as-search engine.
//!
//! Ships as a **Zig module** (`@import("relate")`) over the `irregex` library
//! (a sibling-path dependency in dev; url+hash in a release). No executables:
//! the `relate` binary is a face in the `gist` package (the product chassis),
//! and `blast` imports this engine the same way. The one C floor is libsais —
//! the codex FM-index's suffix-array constructor — compiled from the pinned
//! mirror under `vendor/libsais/`.
//!
//! Test chassis mirrors the library's (kernelkit's shape): a ReleaseSafe
//! brigade-sharded unit-test binary, `check` for the --watch/ZLS loop, and a
//! kcov `coverage` step.

const std = @import("std");
const builtin = @import("builtin");

// libsais compiles with no feature flags at all: LIBSAIS_OPENMP stays OFF, so
// the parallel entry points are preprocessed away and the archive needs no
// `libomp`. `-fno-sanitize=undefined` because the induced sort walks its
// suffix array with deliberately negative sentinel indices and one-past-the-
// end cursors — a codex build must fail as a Zig error, never as a sanitizer
// abort inside C. Provenance: vendor/libsais/README.md + the build.zig.zon
// `.lazy` row pinning the upstream release by URL + content hash.
const libsais_cflags = [_][]const u8{
    "-fno-sanitize=undefined",
    "-std=c99",
};

/// One libsais static archive per optimize mode, memoized (same discipline as
/// the library's PCRE2 floor: a ReleaseSafe test binary must not run a Debug
/// C library). `.pic = true` so the archive serves PIE product binaries and
/// gist's shared C-ABI object alike.
const Floor = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    built: Memo = Memo.initFill(null),

    const Memo = std.EnumArray(std.builtin.OptimizeMode, ?*std.Build.Step.Compile);

    fn under(self: *Floor, m: *std.Build.Module) void {
        m.link_libc = true;
        m.linkLibrary(self.at(m.optimize.?));
    }

    fn at(self: *Floor, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
        if (self.built.get(optimize)) |ready| return ready;
        const mod = self.b.createModule(.{ .target = self.target, .optimize = optimize, .link_libc = true, .pic = true });
        mod.addIncludePath(self.b.path("vendor/libsais/include"));
        mod.addCSourceFiles(.{ .root = self.b.path("vendor/libsais/src"), .files = &.{"libsais.c"}, .flags = &libsais_cflags });
        const lib = self.b.addLibrary(.{ .name = "libsais", .linkage = .static, .root_module = mod });
        self.built.set(optimize, lib);
        return lib;
    }
};

pub fn build(b: *std.Build) void {
    const default_target: std.Target.Query = if (builtin.target.os.tag == .macos)
        .{ .os_version_min = .{ .semver = .{ .major = 13, .minor = 0, .patch = 0 } } }
    else
        .{};
    const target = b.standardTargetOptions(.{ .default_target = default_target });
    const optimize = b.standardOptimizeOption(.{});

    var floor = Floor{ .b = b, .target = target };

    // The library beneath, at matching optimize — its module carries the
    // PCRE2 floor with it, so linking `relate` links the whole stack.
    const irregex_dep = b.dependency("irregex", .{ .target = target, .optimize = optimize });

    const engine = b.addModule("relate", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
        .imports = &.{.{ .name = "irregex", .module = irregex_dep.module("irregex") }},
    });
    floor.under(engine);

    // ReleaseSafe test binary (differential suites exist to trip safety
    // checks); `-Dtest-optimize=Debug` still yields a steppable binary.
    const test_optimize = b.option(
        std.builtin.OptimizeMode,
        "test-optimize",
        "optimize mode for the unit-test binary (default ReleaseSafe)",
    ) orelse .ReleaseSafe;
    const test_module = if (test_optimize == optimize) engine else blk: {
        const dep = b.dependency("irregex", .{ .target = target, .optimize = test_optimize });
        const twin = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = test_optimize,
            .pic = true,
            .imports = &.{.{ .name = "irregex", .module = dep.module("irregex") }},
        });
        floor.under(twin);
        break :blk twin;
    };

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
