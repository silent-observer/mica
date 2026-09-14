const std = @import("std");
const Io = std.Io;

const core = @import("core");
const Router = @import("router");

/// Scratch driver: reroutes `examples/counter.mnl` from scratch and prints the
/// result. Edit freely - this is not a CLI.
pub fn main(init: std.process.Init) !void {
    const text = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        "examples/counter.mnl",
        init.gpa,
        .unlimited,
    );
    defer init.gpa.free(text);

    const r = core.NetlistParser.parse(text, init.gpa);
    defer r.deinit(init.gpa);

    if (r.err) |e| {
        std.debug.print("parse error: {s}\n", .{e});
        return;
    }
    const nl = r.netlist.?;

    for (nl.nets.items) |*net| {
        net.route_start = 0;
        net.route_len = 0;
    }
    nl.route_edges.clearRetainingCapacity();
    Router.route(nl, init.gpa);

    const emitted = core.NetlistEmitter.emit(nl, init.gpa);
    defer emitted.deinit(init.gpa);

    for (emitted.warnings) |warning|
        std.debug.print("warning: {s}\n", .{warning});

    var buf: [64 * 1024]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &buf);
    try out.interface.writeAll(emitted.text);
    try out.interface.flush();
}
