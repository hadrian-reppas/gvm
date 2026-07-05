const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("gvm", .{
        .root_source_file = b.path("src/lib/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lib = b.addLibrary(.{
        .name = "gvm",
        .linkage = .static,
        .root_module = module,
    });
    b.installArtifact(lib);

    const cli = b.addExecutable(.{
        .name = "gvm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    cli.root_module.addImport("gvm", module);
    b.installArtifact(cli);

    const tests = b.addTest(.{ .root_module = module });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run unit tests").dependOn(&run_tests.step);

    // Coverage-guided fuzzing. Run with: `zig build fuzz --fuzz`
    //   - LLVM backend: needed for the coverage instrumentation `--fuzz` adds.
    //   - Custom test_runner.zig: works around a compile bug in Zig 0.16.0's
    //     stock runner under `-ffuzz` (see test_runner.zig for details).
    const fuzz_tests = b.addTest(.{
        .root_module = module,
        .use_llvm = true,
        .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .server },
    });
    const run_fuzz = b.addRunArtifact(fuzz_tests);
    // Pre-create the fuzzer's cache subdirs. Zig 0.16.0 writes
    // `<cache>/tmp/libfuzzer.log` without creating `tmp/` first, and on the first
    // run for a given binary its parallel workers race to create the per-binary
    // coverage file under `<cache>/v/`; if `v/` doesn't exist yet a worker can
    // panic with `failed to open coverage file ...: FileNotFound`. (The digest in
    // that filename changes whenever the instrumented code changes, so any edit
    // re-triggers the first-run race.) Ensuring both dirs exist avoids it.
    const mk_dirs = b.addSystemCommand(&.{ "mkdir", "-p", ".zig-cache/tmp", ".zig-cache/v" });
    run_fuzz.step.dependOn(&mk_dirs.step);
    b.step("fuzz", "Run fuzz tests (pass --fuzz to search)").dependOn(&run_fuzz.step);
}
