const std = @import("std");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();
    const version = b.option([]const u8, "version", "Version to report (default: build.zig.zon's)") orelse zon.version;
    options.addOption([]const u8, "version", version);

    const exe = b.addExecutable(.{
        .name = "smith",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = if (optimize == .Debug) null else true,
            .imports = &.{
                .{ .name = "build_options", .module = options.createModule() },
            },
        }),
    });
    if (target.result.os.tag == .linux) exe.pie = true;
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run smith").dependOn(&run_cmd.step);

    const filters = b.option([]const []const u8, "test-filter", "Run only the tests whose name contains this") orelse &.{};
    const unit_tests = b.addTest(.{ .root_module = exe.root_module, .filters = filters });
    unit_tests.pie = exe.pie;
    const tests = b.addRunArtifact(unit_tests);
    b.step("test", "Run unit tests").dependOn(&tests.step);

    // kcov cannot map the self-hosted backend's debug info to the sources.
    const coverage_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .Debug,
            .imports = &.{
                .{ .name = "build_options", .module = options.createModule() },
            },
        }),
        .filters = filters,
        .use_llvm = true,
    });
    const kcov = b.addSystemCommand(&.{
        "sh",
        "-c",
        "rm -rf \"$1\" && mkdir -p \"$1\" && exec kcov \"$2\" \"$3\" \"$1\" \"$4\"",
        "coverage",
        b.pathJoin(&.{ b.install_path, "coverage" }),
        b.fmt("--include-path={s}", .{b.pathFromRoot("src")}),
        b.fmt("--exclude-path={s},{s}", .{ b.pathFromRoot("src/tests"), b.pathFromRoot("src/testing") }),
    });
    kcov.addArtifactArg(coverage_tests);
    b.step("coverage", "Run the unit tests under kcov into zig-out/coverage").dependOn(&kcov.step);
}
