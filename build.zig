const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core = b.addModule("core", .{
        .root_source_file = b.path("src/core/core.zig"),
        .target = target,
        .optimize = optimize,
    });

    // @embedFile is confined to the module root (src/core), so the examples the
    // tests use as fixtures are handed in as imports. Note that addEmbedPath is
    // not the tool for this: it feeds C's #embed, not Zig's.
    for ([_][2][]const u8{
        .{ "inverter_mica", "examples/inverter.mica" },
        .{ "inverter_bit", "examples/inverter.bit" },
        .{ "toggle_mica", "examples/toggle.mica" },
        .{ "toggle_bit", "examples/toggle.bit" },
        .{ "bram_dsp_mica", "examples/bram_dsp.mica" },
    }) |fixture| {
        core.addAnonymousImport(fixture[0], .{ .root_source_file = b.path(fixture[1]) });
    }

    const exe = b.addExecutable(.{
        .name = "mica",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "core", .module = core },
            },
        }),
        .use_llvm = true,
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = core,
        // `zig build test -Dtest-filter=pinCoord` runs a single test; the
        // fixtures above rule out a bare `zig test src/core/core.zig`.
        .filters = b.option(
            []const []const u8,
            "test-filter",
            "Only run tests whose name contains one of these",
        ) orelse &.{},
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
}
