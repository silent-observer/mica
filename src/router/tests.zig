//! Golden-file tests for the router. The `route {}` bodies in `examples/*.mnl`
//! are the expected output: each file is parsed, stripped of its routes, routed
//! again from scratch and emitted, which has to reproduce the file byte for
//! byte. So the fixture is still the example itself - there is no unrouted
//! second copy to keep in sync.
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

const Example = struct { name: []const u8, text: []const u8 };

const examples = [_]Example{
    .{ .name = "inverter.mnl", .text = @embedFile("inverter_mnl") },
    .{ .name = "toggle.mnl", .text = @embedFile("toggle_mnl") },
    .{ .name = "counter.mnl", .text = @embedFile("counter_mnl") },
};

/// Parses, drops every `route {}` body, and hands back a netlist the router can
/// be pointed at. The caller owns the result.
fn parseUnrouted(name: []const u8, text: []const u8) !core.NetlistParser.Result {
    const r = core.NetlistParser.parse(text, alloc);
    if (r.err) |e| {
        std.debug.print("{s}: unexpected parse error: {s}\n", .{ name, e });
        r.deinit(alloc);
        return error.NetlistParseFailed;
    }

    const nl = r.netlist.?;
    for (nl.nets.items) |*net| {
        net.route_start = 0;
        net.route_len = 0;
    }
    nl.route_edges.clearRetainingCapacity();
    return r;
}

test "golden: the router reproduces the routes the examples were written with" {
    for (examples) |example| {
        const r = try parseUnrouted(example.name, example.text);
        defer r.deinit(alloc);

        Router.route(r.netlist.?, alloc);

        const t = core.NetlistEmitter.emit(r.netlist.?, alloc);
        defer t.deinit(alloc);

        // A route naming a wire that does not exist at that coordinate is
        // exactly what the emitter warns about, so a warning is a failure here
        // even though the text might still compare equal.
        if (t.warnings.len != 0) {
            for (t.warnings) |w|
                std.debug.print("{s}: unexpected warning: {s}\n", .{ example.name, w });
            return error.RouteEmitWarned;
        }

        try std.testing.expectEqualStrings(example.text, t.text);
    }
}
