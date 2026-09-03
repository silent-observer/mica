const std = @import("std");
const Io = std.Io;

const core = @import("core");

pub fn main(init: std.process.Init) !void {
    // Accessing command line arguments:
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    for (args) |arg| {
        std.log.info("arg: {s}", .{arg});
    }

    const f = core.Fabric.build(init.arena.allocator(), .mica1s);

    var buf: [16 * 1024]u8 = undefined;

    {
        const file = try std.Io.Dir.cwd().createFile(init.io, "nodes.csv", .{});
        defer file.close(init.io);
        var w = file.writer(init.io, &buf);
        try f.writeNodes(&w.interface);
        try w.flush();
    }

    {
        const file = try std.Io.Dir.cwd().createFile(init.io, "conns.csv", .{});
        defer file.close(init.io);
        var w = file.writer(init.io, &buf);
        try f.writeConnections(&w.interface);
        try w.flush();
    }
}
