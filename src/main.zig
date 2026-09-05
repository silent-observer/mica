const std = @import("std");
const Io = std.Io;

const core = @import("core");

pub fn main(init: std.process.Init) !void {
    const text = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        "examples/inverter.mica",
        init.gpa,
        .unlimited,
    );
    defer init.gpa.free(text);

    const r = core.TextParser.parse(text, init.gpa);
    defer if (r.c) |c| c.deinit(init.gpa);
    defer if (r.err) |e| init.gpa.free(e);

    if (r.err) |e| {
        std.debug.print("{s}\n", .{e});
        return;
    }

    const emitted = core.TextEmitter.emit(&r.c.?, init.gpa);
    defer init.gpa.free(emitted);

    std.debug.print("{s}", .{emitted});

    // var f = core.Fabric.build(init.gpa, .mica1s);
    // defer f.deinit();

    // var buf: [16 * 1024]u8 = undefined;

    // {
    //     const file = try std.Io.Dir.cwd().createFile(init.io, "nodes.csv", .{});
    //     defer file.close(init.io);
    //     var w = file.writer(init.io, &buf);
    //     try f.writeNodes(&w.interface);
    //     try w.flush();
    // }

    // {
    //     const file = try std.Io.Dir.cwd().createFile(init.io, "conns.csv", .{});
    //     defer file.close(init.io);
    //     var w = file.writer(init.io, &buf);
    //     try f.writeConnections(&w.interface);
    //     try w.flush();
    // }
}
