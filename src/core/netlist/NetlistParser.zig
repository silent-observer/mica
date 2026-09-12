const std = @import("std");

const common = @import("../common.zig");
const Netlist = @import("Netlist.zig");
const CommonParser = @import("../CommonParser.zig");

const parseNet = @import("parse_net.zig").parseNet;
const parseCell = @import("parse_cell.zig").parseCell;

const NetlistParser = @This();

p: CommonParser,
netlist: ?*Netlist,
arena: std.heap.ArenaAllocator,

fn init(input: []const u8, alloc: std.mem.Allocator) NetlistParser {
    return .{
        .p = .init(input, alloc),
        .netlist = null,
        .arena = .init(alloc),
    };
}

fn deinit(p: *NetlistParser) void {
    p.arena.deinit();
}

pub inline fn nl(p: *NetlistParser) *Netlist {
    return p.netlist.?;
}

const passes: std.StaticStringMap(Netlist.Pass) = .initComptime(blk: {
    var arr: [std.enums.values(Netlist.Pass).len]struct { []const u8, Netlist.Pass } = undefined;
    for (std.enums.values(Netlist.Pass), &arr) |v, *kv|
        kv.* = .{ @tagName(v), v };
    break :blk arr;
});

fn parseHeader(p: *NetlistParser) !void {
    const model = try p.p.parseFormatAndDevice();

    const design_word = try p.p.parseWord();
    if (!std.mem.eql(u8, design_word, "design"))
        try p.p.err("Expected 'design', but got '{s}'", .{design_word});
    const design_str = try p.p.parseString();
    try p.p.expect(';');

    p.netlist = p.p.alloc.create(Netlist) catch common.oom();
    p.netlist.?.* = .init(p.p.alloc, model, design_str);

    while (!p.p.checkEof()) {
        const m = p.p.mark();
        if (!std.mem.eql(u8, try p.p.parseWord(), "pass")) {
            p.p.reset(m);
            break;
        }

        const pass_word = try p.p.parseWord();
        const pass = passes.get(pass_word) orelse
            try p.p.err("Expected a pass name " ++
                "(one of 'synth', 'opt', 'techmap', 'pack', 'place', 'route'), " ++
                "but got '{s}'", .{pass_word});
        const str = try p.p.parseString();
        try p.p.expect(';');

        p.nl().setPass(pass, str);
    }
}

fn parseBlock(p: *NetlistParser) !void {
    const block = try p.p.parseWord();
    if (std.mem.eql(u8, block, "net"))
        try p.parseNet()
    else if (std.mem.eql(u8, block, "cell"))
        try p.parseCell()
    else
        try p.p.err("Unknown block '{s}'", .{block});
}

pub const Result = struct {
    netlist: ?*Netlist,
    err: ?[]const u8,

    pub fn deinit(r: Result, alloc: std.mem.Allocator) void {
        if (r.netlist) |netlist| {
            netlist.deinit();
            alloc.destroy(netlist);
        }
        if (r.err) |e|
            alloc.free(e);
    }
};

pub fn parse(input: []const u8, alloc: std.mem.Allocator) Result {
    var p = NetlistParser.init(input, alloc);
    defer p.deinit();
    // parseHeader can fail either side of creating the Netlist, so the
    // optional is passed through rather than unwrapped.
    p.parseHeader() catch return Result{
        .netlist = p.netlist,
        .err = p.p.errorText,
    };

    while (!p.p.checkEof())
        p.parseBlock() catch return Result{
            .netlist = p.netlist,
            .err = p.p.errorText,
        };

    return Result{
        .netlist = p.netlist,
        .err = p.p.errorText,
    };
}

test "net kind is fixed at first mention" {
    const header = "format 1;\ndevice \"M1/S\";\ndesign \"t\";\n";
    const cases = [_]struct { src: []const u8, want: ?[]const u8 }{
        // A kind may be restated as long as it agrees, in either order.
        .{ .src = "net a : clock;\nnet a {}\n", .want = null },
        .{ .src = "net a : clock;\nnet a : clock {}\n", .want = null },
        .{ .src = "net a;\nnet a {}\n", .want = null },
        // Contradicting an explicit kind.
        .{
            .src = "net a : clock;\nnet a : reset {}\n",
            .want = "was already defined earlier as 'clock'",
        },
        // Annotating a name that an earlier mention already pinned to .net.
        .{
            .src = "net a;\nnet a : clock {}\n",
            .want = "was already defined earlier as 'net'",
        },
    };

    for (cases) |case| {
        const src = try std.mem.concat(
            std.testing.allocator,
            u8,
            &.{ header, case.src },
        );
        defer std.testing.allocator.free(src);

        const r = parse(src, std.testing.allocator);
        defer r.deinit(std.testing.allocator);

        if (case.want) |want| {
            try std.testing.expect(r.err != null);
            try std.testing.expect(std.mem.indexOf(u8, r.err.?, want) != null);
        } else {
            if (r.err) |e|
                std.debug.print("{s}\n", .{e});
            try std.testing.expectEqual(@as(?[]const u8, null), r.err);
        }
    }
}
