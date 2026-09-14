//! Golden-file tests for the router. Each pair is an unrouted `examples/*.mnl`
//! and the `examples/*.routed.mnl` beside it: routing the first has to produce
//! the second byte for byte, which is the same thing `mica route` does, so the
//! fixtures are literally the tool's own input and output.
//!
//! That makes these tests sensitive to *which* of several equivalent wires the
//! search settles on, not just to whether the result is legal. That is the
//! point: a change in the tie-break shows up here as a diff to eyeball rather
//! than passing silently.

const std = @import("std");
const core = @import("core");

const Router = @import("Router.zig");
const Netlist = core.Netlist;

const alloc = std.testing.allocator;

const Example = struct {
    name: []const u8,
    placed: []const u8,
    routed: []const u8,
};

const examples = [_]Example{
    .{
        .name = "inverter",
        .placed = @embedFile("inverter_mnl"),
        .routed = @embedFile("inverter_routed_mnl"),
    },
    .{
        .name = "toggle",
        .placed = @embedFile("toggle_mnl"),
        .routed = @embedFile("toggle_routed_mnl"),
    },
    .{
        .name = "counter",
        .placed = @embedFile("counter_mnl"),
        .routed = @embedFile("counter_routed_mnl"),
    },
};

fn parse(name: []const u8, text: []const u8) !core.NetlistParser.Result {
    const r = core.NetlistParser.parse(text, alloc);
    if (r.err) |e| {
        std.debug.print("{s}: unexpected parse error: {s}\n", .{ name, e });
        r.deinit(alloc);
        return error.NetlistParseFailed;
    }
    return r;
}

/// Routes `placed` and returns the emitted text, which the caller frees.
fn routeToText(name: []const u8, input: []const u8) ![]const u8 {
    const r = try parse(name, input);
    defer r.deinit(alloc);

    Router.route(r.netlist.?, alloc);

    const t = core.NetlistEmitter.emit(r.netlist.?, alloc);
    defer t.deinit(alloc);

    // A route naming a wire that does not exist at that coordinate is exactly
    // what the emitter warns about, so a warning is a failure here even though
    // the text might still compare equal.
    if (t.warnings.len != 0) {
        for (t.warnings) |w|
            std.debug.print("{s}: unexpected warning: {s}\n", .{ name, w });
        return error.RouteEmitWarned;
    }

    return alloc.dupe(u8, t.text);
}

test "golden: routing a placed example produces the .routed.mnl beside it" {
    for (examples) |example| {
        const text = try routeToText(example.name, example.placed);
        defer alloc.free(text);

        try std.testing.expectEqualStrings(example.routed, text);
    }
}

test "routing is idempotent: rerouting a routed netlist reproduces it" {
    // `Router.route` discards the routing it is handed rather than adding to
    // it, and replaces the `pass route` stamp rather than appending a second
    // one, so the routed example is a fixed point of the whole command.
    for (examples) |example| {
        const text = try routeToText(example.name, example.routed);
        defer alloc.free(text);

        try std.testing.expectEqualStrings(example.routed, text);
    }
}
