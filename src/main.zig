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
    defer r.deinit(init.gpa);

    const r2 = core.NetlistParser.parse(text, init.gpa);
    defer r2.deinit(init.gpa);

    if (r.err) |e| {
        std.debug.print("{s}\n", .{e});
        return;
    }

    const emitted = core.TextEmitter.emit(&r.c.?, init.gpa);
    defer emitted.deinit(init.gpa);

    for (emitted.warnings) |warning|
        std.debug.print("error: {s}\n", .{warning});

    std.debug.print("{s}", .{emitted.text});

    const emitted_bin = core.BinaryEmitter.emit(&r.c.?, init.gpa);
    defer init.gpa.free(emitted_bin);

    try std.Io.Dir.cwd().writeFile(init.io, .{
        .data = emitted_bin,
        .sub_path = "examples/inverter.bit",
        .flags = .{},
    });

    const parsed = core.BinaryParser.parse(emitted_bin, init.gpa);
    defer parsed.deinit(init.gpa);

    if (parsed.err) |e| {
        std.debug.print("{s}\n", .{e});
        return;
    }
    for (parsed.warnings) |w| {
        std.debug.print("{s}\n", .{w});
    }

    const emitted_bin2 = core.BinaryEmitter.emit(&parsed.c.?, init.gpa);
    defer init.gpa.free(emitted_bin2);
    std.debug.assert(std.mem.eql(u8, emitted_bin, emitted_bin2));

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
