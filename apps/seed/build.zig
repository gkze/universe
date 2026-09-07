const std = @import("std");
const zlinter = @import("zlinter");
const publication = @import("publication.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = seedExecutable(b, target, optimize);
    const output = seedOutput(b, exe);
    b.getInstallStep().dependOn(&b.addInstallBinFile(output, exe.name).step);

    const check = b.step("check", "Analyze the seed executable without emitting it");
    const check_exe = b.addExecutable(.{ .name = exe.name, .root_module = exe.root_module });
    check.dependOn(&check_exe.step);

    const release = b.step("release", "Build and stage every supported release target");
    const check_artifacts = b.step("check-artifacts", "Compare release builds with the tracked binaries");
    const release_targets = [_]std.Target.Query{
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
        .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
        .{ .cpu_arch = .x86_64, .os_tag = .macos },
        .{ .cpu_arch = .aarch64, .os_tag = .macos },
    };
    const publish = Publish.create(b, release_targets.len);
    b.step("publish", "Build, validate, and atomically publish release binaries").dependOn(&publish.step);
    for (release_targets, 0..) |query, index| {
        const binary = seedExecutable(b, b.resolveTargetQuery(query), .ReleaseSmall);
        const artifact = seedOutput(b, binary);
        publish.sources[index] = artifact;
        publish.names[index] = binary.name;
        artifact.addStepDependencies(&publish.step);
        release.dependOn(&b.addInstallBinFile(artifact, binary.name).step);
        const compare = b.addSystemCommand(&.{"cmp"});
        compare.addFileArg(artifact);
        compare.addFileArg(b.path(b.fmt("../../bin/{s}", .{binary.name})));
        check_artifacts.dependOn(&compare.step);
    }

    const fmt_paths = &.{ "build.zig", "build.zig.zon", "main.zig", "publication.zig", "tests/binary.zig", "../../seed.zon" };
    b.step("fmt", "Format seed source and manifests").dependOn(&b.addFmt(.{ .paths = fmt_paths }).step);
    const fmt_check = b.addFmt(.{ .paths = fmt_paths, .check = true });
    b.step("fmt-check", "Check seed formatting").dependOn(&fmt_check.step);

    var linter = zlinter.builder(b, .{});
    linter.addPaths(.{
        .include = &.{b.path(".")},
        .exclude = &.{b.path("zig-pkg")},
    });
    linter.addRule(.{ .builtin = .no_swallow_error }, .{
        .detect_catch_unreachable = .@"error",
        .detect_empty_catch = .@"error",
        .detect_empty_else = .@"error",
        .detect_else_unreachable = .@"error",
    });
    linter.addRule(.{ .builtin = .no_deprecated }, .{ .severity = .@"error" });
    linter.addRule(.{ .builtin = .no_unused }, .{ .container_declaration = .@"error" });
    linter.addRule(.{ .builtin = .no_orelse_unreachable }, .{ .severity = .@"error" });
    linter.addRule(.{ .builtin = .require_errdefer_dealloc }, .{ .severity = .@"error" });
    const lint = linter.build();
    b.step("lint", "Lint seed source").dependOn(lint);

    const filters = b.option([]const []const u8, "test-filter", "Run tests whose names contain a filter") orelse &.{};
    const test_step = b.step("test", "Run tests with the selected target and optimization");
    test_step.dependOn(&seedTests(b, target, optimize, filters).step);
    const test_all = b.step("test-all", "Run native tests in Debug and ReleaseSafe");
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseSafe }) |mode| {
        test_all.dependOn(&seedTests(b, b.graph.host, mode, filters).step);
    }

    const publication_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("publication.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }) });
    const test_publication = b.step("test-publication", "Test release publication against disposable files");
    test_publication.dependOn(&b.addRunArtifact(publication_tests).step);
    const binary_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/binary.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }) });
    const options = b.addOptions();
    options.addOption([]const u8, "launcher", b.pathFromRoot("../../bin/seed.sh"));
    binary_tests.root_module.addOptions("options", options);
    const test_binary = b.step("test-binary", "Smoke test the committed native seed");
    test_binary.dependOn(&b.addRunArtifact(binary_tests).step);

    const quality = b.step("quality", "Check formatting, lint, executable semantics, and tests");
    quality.dependOn(&fmt_check.step);
    quality.dependOn(lint);
    quality.dependOn(check);
    quality.dependOn(test_all);
    quality.dependOn(test_publication);
    quality.dependOn(test_binary);
}

fn seedExecutable(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const name = b.fmt("universe-seed-{s}-{s}{s}", .{
        @tagName(target.result.cpu.arch),
        @tagName(target.result.os.tag),
        if (target.result.abi == .musl) "-musl" else "",
    });
    const module = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    if (optimize == .ReleaseSmall) {
        module.strip = true;
        module.unwind_tables = .none;
    }
    const exe = b.addExecutable(.{ .name = name, .root_module = module });
    exe.link_gc_sections = true;
    if (optimize == .ReleaseSmall and target.result.os.tag == .linux) exe.lto = .full;
    return exe;
}

fn seedOutput(b: *std.Build, exe: *std.Build.Step.Compile) std.Build.LazyPath {
    if (exe.root_module.optimize == .ReleaseSmall and exe.root_module.resolved_target.?.result.os.tag == .macos) {
        // LLVM strips retained Mach-O local symbols and regenerates the ARM64 signature.
        const strip = b.addSystemCommand(&.{ "llvm-strip", "--strip-all", "--keep-undefined", "-o" });
        const stripped = strip.addOutputFileArg(exe.name);
        strip.addFileArg(exe.getEmittedBin());
        return stripped;
    }
    return exe.getEmittedBin();
}

fn seedTests(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, filters: []const []const u8) *std.Build.Step.Run {
    const tests = b.addTest(.{
        .filters = filters,
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    return b.addRunArtifact(tests);
}

// LazyPath dependencies are the compilation barrier. Publication never launches
// a compiler or removes compiler-owned paths, including during cancellation.
const Publish = struct {
    step: std.Build.Step,
    sources: []std.Build.LazyPath,
    names: [][]const u8,

    fn create(b: *std.Build, count: usize) *Publish {
        const self = b.allocator.create(Publish) catch @panic("OOM");
        self.* = .{
            .step = std.Build.Step.init(.{ .id = .custom, .name = "publish release seeds", .owner = b, .makeFn = make }),
            .sources = b.allocator.alloc(std.Build.LazyPath, count) catch @panic("OOM"),
            .names = b.allocator.alloc([]const u8, count) catch @panic("OOM"),
        };
        return self;
    }

    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) !void {
        _ = options;
        const self: *Publish = @fieldParentPtr("step", step);
        const b = step.owner;
        const io = b.graph.io;
        const artifacts = try b.allocator.alloc(publication.Artifact, self.sources.len);
        defer b.allocator.free(artifacts);
        for (self.sources, self.names, artifacts) |source, name, *artifact| {
            artifact.* = .{ .source = try (try source.getPath4(b, step)).toString(b.allocator), .name = name };
        }
        const dest = try std.Io.Dir.cwd().createDirPathOpen(io, b.pathFromRoot("../../bin"), .{});
        defer dest.close(io);
        try publication.publish(b.allocator, io, .cwd(), dest, artifacts);
    }
};
