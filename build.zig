const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core = b.addModule("core", .{
        .root_source_file = b.path("src/core/core.zig"),
        .target = target,
        .optimize = optimize,
    });

    const router = b.addModule("router", .{
        .root_source_file = b.path("src/router/Router.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core", .module = core },
        },
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
        .{ "inverter_mnl", "examples/inverter.mnl" },
        .{ "toggle_mnl", "examples/toggle.mnl" },
        .{ "bram_dsp_mnl", "examples/bram_dsp.mnl" },
        .{ "counter_mnl", "examples/counter.mnl" },
    }) |fixture| {
        core.addAnonymousImport(fixture[0], .{ .root_source_file = b.path(fixture[1]) });
    }

    // The router reroutes those same examples and compares against them, so it
    // needs the netlist fixtures too.
    for ([_][2][]const u8{
        .{ "inverter_mnl", "examples/inverter.mnl" },
        .{ "toggle_mnl", "examples/toggle.mnl" },
        .{ "counter_mnl", "examples/counter.mnl" },
    }) |fixture| {
        router.addAnonymousImport(fixture[0], .{ .root_source_file = b.path(fixture[1]) });
    }

    const exe = b.addExecutable(.{
        .name = "mica",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "core", .module = core },
                .{ .name = "router", .module = router },
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

    // `zig build test -Dtest-filter=pinCoord` runs a single test; the fixtures
    // above rule out a bare `zig test src/core/core.zig`. Declared once and
    // shared, since `b.option` panics if the same name is declared twice.
    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Only run tests whose name contains one of these",
    ) orelse &.{};

    const mod_tests = b.addTest(.{
        .root_module = core,
        .filters = test_filters,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    // `core` cannot import `router`, so the router's tests are a second compile
    // rather than another `_ = @import(...)` in core.zig's test block.
    const router_tests = b.addTest(.{
        .root_module = router,
        .filters = test_filters,
    });

    const run_router_tests = b.addRunArtifact(router_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_router_tests.step);
}
