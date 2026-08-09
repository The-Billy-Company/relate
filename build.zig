//! relate build graph — the compression-as-search engine and its CLI.
//!
//! Ships as a **Zig module** (`@import("relate")`) over the `irregex` library
//! and the `gist` chassis (the resident daemon + answer keep the face dials),
//! plus the `relate` binary rooted at `src/surface/face/main.zig`, and the
//! C-ABI dual artifact (`librelate` + `include/relate.h`). The C floors
//! (PCRE2, libsais) ride in with the library; this package adds none of its
//! own. `librelate` dynamically links `libirgx` for the substrate symbols
//! it does not redefine.
//!
//! Test chassis mirrors the engine's: a ReleaseSafe
//! brigade-sharded unit-test binary, `check` for the --watch/ZLS loop, and a
//! kcov `coverage` step.

const std = @import("std");
const builtin = @import("builtin");
const brigade = @import("brigade");

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
    const irgx_dep = b.dependency("irregex", engineOptions(target, optimize));
    const gist_dep = b.dependency("gist", .{ .target = target, .optimize = optimize });
    const deps = [_]std.Build.Module.Import{
        .{ .name = "irregex", .module = irgx_dep.module("irregex") },
        .{ .name = "gist", .module = gist_dep.module("gist") },
    };

    // ── the one place this package's semver lives ──
    // `build.zig.zon`'s `.version` is the single authority; `src/root.zig` reads
    // it through this option instead of restating it, so `relate --version` and
    // the `--schema` manifest answer with THIS package's number rather than the
    // engine's. Every remaining copy is a publishing manifest that cannot import
    // anything (Cargo, PyPI); those carry an `x-release-please-version` marker
    // and are moved by the release bot, with `tools/version_parity.py` failing
    // if one of them lags.
    //
    // The package name rides along so this generated file differs from the ones
    // `irregex` and `gist` generate. Zig content-addresses it, and two packages
    // whose only option was an identical version string produced the SAME file —
    // which it then refuses as the root of two modules.
    const zon = @import("build.zig.zon");
    const version = b.addOptions();
    version.addOption([:0]const u8, "version", zon.version);
    version.addOption([:0]const u8, "package", @tagName(zon.name));

    const engine = b.addModule("relate", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
        .imports = &deps,
    });
    engine.addOptions("build_options", version);

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
    const cli_engine = if (cli_optimize == optimize) engine else blk: {
        const twin = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = cli_optimize,
            .pic = true,
            .imports = &cli_deps,
        });
        twin.addOptions("build_options", version);
        break :blk twin;
    };
    // A face main is a thin exe root: real driver code is analyzed inside
    // the relate module (whose root is src/root.zig, so relative imports
    // resolve) and reached as `@import("relate").faces.*` / `.cli.*`.
    const face_imports = [_]std.Build.Module.Import{
        .{ .name = "irregex", .module = if (cli_optimize == optimize)
            irgx_dep.module("irregex")
        else
            b.dependency("irregex", engineOptions(target, cli_optimize)).module("irregex") },
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
    // against libirgx (dynamic), so librelate does not redefine them and a
    // host that also links libgist still sees one vocabulary. Rooted at the
    // export shims, NOT at `src/root.zig`, so the module dependents import
    // never carries a second copy of `relate_run`.
    const irgx_lib = irgx_dep.artifact("irgx");
    const abi = b.createModule(.{
        .root_source_file = b.path("src/surface/ffi/exports.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
        .imports = &.{.{ .name = "irregex", .module = irgx_dep.module("irregex") }},
    });
    abi.linkLibrary(irgx_lib);
    // A shipped dylib has to find its substrate beside itself. `linkLibrary`
    // records only this build tree's own output dir — a RELATIVE
    // `.zig-cache/o/<hash>` path, meaningless on a consumer's machine — so
    // `dlopen("librelate.dylib")` from anywhere else cannot resolve
    // `@rpath/libirgx.dylib` and fails at load. A loader-relative rpath makes
    // the shape we actually ship ("both libraries in one lib dir") the loadable
    // one, without naming an absolute path we do not own.
    abi.addRPathSpecial(if (target.result.os.tag == .macos) "@loader_path" else "$ORIGIN");
    const dynamic_lib = b.addLibrary(.{ .name = "relate", .linkage = .dynamic, .root_module = abi });
    dynamic_lib.installHeader(b.path("include/relate.h"), "relate.h");
    // A host that #includes <relate.h> also needs <gist.h> and <irgx.h>;
    // install them beside ours so one -I covers the stack.
    dynamic_lib.installHeader(gist_dep.path("include/gist.h"), "gist.h");
    dynamic_lib.installHeader(irgx_dep.path("include/irgx.h"), "irgx.h");
    b.installArtifact(dynamic_lib);
    if (target.result.os.tag == .macos) {
        const obj = b.addObject(.{ .name = "relate", .root_module = abi });
        const repack = b.addSystemCommand(&.{ "libtool", "-static", "-o" });
        const aligned_a = repack.addOutputFileArg("librelate.a");
        repack.addArtifactArg(obj);
        b.getInstallStep().dependOn(&b.addInstallLibFile(aligned_a, "librelate.a").step);
    } else {
        // Installed as a FILE, not an artifact. `installArtifact` publishes a
        // name into the table a dependent's `dep.artifact("relate")` searches,
        // and the dylib above already owns `relate`; a second registration
        // makes that lookup ambiguous and panics the build runner in the
        // DEPENDENT, never here — invisible on a laptop, since this is the arm
        // macOS does not take. The macOS arm is already file-shaped for its own
        // reason, so this makes both arms install `librelate.a` the same way.
        const static_lib = b.addLibrary(.{ .name = "relate", .linkage = .static, .root_module = abi });
        b.getInstallStep().dependOn(&b.addInstallLibFile(static_lib.getEmittedBin(), "librelate.a").step);
    }
    b.installArtifact(irgx_lib);
    // `librelate.a` deliberately does not fold the substrate in, so a static
    // consumer links the pair — which means this prefix has to hold the other
    // half. It is an install-file product of the irregex package rather than a
    // named artifact, so it comes across as a named lazy path, built for this
    // target rather than copied out of whatever a sibling checkout last built.
    b.getInstallStep().dependOn(
        &b.addInstallLibFile(irgx_dep.namedLazyPath("libirgx.a"), "libirgx.a").step,
    );

    // ── the measurement lab ──
    // Off the default install step, like the sibling packages': a bare
    // `zig build` pays only for the product surface. Both lanes below run at
    // the CLI's ReleaseFast posture, because both are timing tools and a
    // debug-built number is a claim about the build mode.
    const lab_step = b.step("lab", "Build + install the measurement-lab executables (relate-knn, codex-scale, multipattern) → zig-out/bin");

    for ([_]struct {
        step: []const u8,
        root: []const u8,
        blurb: []const u8,
    }{
        .{
            .step = "relate-knn",
            .root = "bench/conformance/relate/knn.zig",
            .blurb = "Run the relate engine as a k-NN classifier over a labeled manifest",
        },
        .{
            .step = "codex-scale",
            .root = "bench/bounds/codex/scale.zig",
            .blurb = "Prove the codex self-index at scale: entropy-bound space, flat-in-n count, exact restore",
        },
        .{
            .step = "multipattern",
            .root = "bench/rungs/multipattern/bench.zig",
            .blurb = "Multi-pattern race arm: per-document attribution throughput, fail-closed against N independent searches",
        },
    }) |lane| {
        const mod = b.createModule(.{
            .root_source_file = b.path(lane.root),
            .target = target,
            .optimize = cli_optimize,
            .imports = &cli_deps,
        });
        // Both lanes straddle the two packages: the FM-index and the assay floor
        // are the engine's, the kinship kernels and the cento quoter are ours.
        mod.addImport("relate", cli_engine);
        const lab_exe = b.addExecutable(.{ .name = lane.step, .root_module = mod });
        const install = &b.addInstallArtifact(lab_exe, .{}).step;
        lab_step.dependOn(install);
        const run = b.addRunArtifact(lab_exe);
        run.setCwd(b.path("."));
        if (b.args) |args| run.addArgs(args);
        const step = b.step(lane.step, lane.blurb);
        step.dependOn(&run.step);
        step.dependOn(install);
    }

    // ReleaseSafe test binary (differential suites exist to trip safety
    // checks); `-Dtest-optimize=Debug` still yields a steppable binary.
    const test_optimize = b.option(
        std.builtin.OptimizeMode,
        "test-optimize",
        "optimize mode for the unit-test binary (default ReleaseSafe)",
    ) orelse .ReleaseSafe;
    const test_module = if (test_optimize == optimize) engine else blk: {
        const twin = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = test_optimize,
            .pic = true,
            .imports = &engines(b, target, test_optimize),
        });
        twin.addOptions("build_options", version);
        break :blk twin;
    };

    const bg = brigade.init(b, .{});
    const tests = b.addTest(.{
        .root_module = test_module,
        .test_runner = bg.runner(),
    });

    const test_step = b.step("test", "Run unit tests");
    bg.shard(test_step, tests, .{});

    const debug_tests = if (test_module == engine) tests else b.addTest(.{
        .root_module = engine,
        .test_runner = bg.runner(),
    });
    b.step("check", "Compile tests without running (fast --watch -fincremental loop / ZLS)")
        .dependOn(&debug_tests.step);

    const run_cov = b.addSystemCommand(&.{ "kcov", "--clean", "--include-pattern=src/" });
    run_cov.addArg(b.pathFromRoot(".local/coverage"));
    run_cov.addArtifactArg(debug_tests);
    bg.whole(run_cov);
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
        .{ .name = "irregex", .module = b.dependency("irregex", engineOptions(target, optimize)).module("irregex") },
        .{ .name = "gist", .module = b.dependency("gist", .{ .target = target, .optimize = optimize }).module("gist") },
    };
}

/// The option set every `b.dependency("irregex", …)` in this package must pass.
///
/// Zig keys dependency dedup on the WHOLE option set, not on target/optimize,
/// and `gist` asks the engine for `lib-optimize` so its C-ABI pair matches its
/// own mode. A sibling passing two options where gist passes three therefore
/// gets a SECOND instance of `irregex/src/root.zig`, and the two collide the
/// moment one binary imports both this package and gist — "file exists in
/// modules 'irregex' and 'irregex0'". It is a link-time error from a build
/// graph that reads as if it matched, so the set lives in one function rather
/// than at three call sites that have to agree by eye.
fn engineOptions(target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    @"lib-optimize": std.builtin.OptimizeMode,
} {
    return .{ .target = target, .optimize = optimize, .@"lib-optimize" = optimize };
}
