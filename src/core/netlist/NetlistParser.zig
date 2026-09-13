const std = @import("std");

const common = @import("../common.zig");
const Netlist = @import("Netlist.zig");
const CommonParser = @import("../CommonParser.zig");

const parseNet = @import("parse_net.zig").parseNet;
const parseCell = @import("parse_cell.zig").parseCell;
pub const checkMetadata = @import("parse_meta.zig").checkMetadata;

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
        if (try p.checkMetadata(.file)) continue;
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
    if (try p.checkMetadata(.file)) return;

    const block = try p.p.parseWord();
    if (std.mem.eql(u8, block, "net"))
        try p.parseNet()
    else if (std.mem.eql(u8, block, "cell"))
        try p.parseCell()
    else
        try p.p.err("Unknown block '{s}'", .{block});
}

/// There is no `warnings` field: the netlist format defines no recoverable
/// malformation, so every problem is fatal.
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

const test_header = "format 1;\ndevice \"M1/S\";\ndesign \"t\";\n";

const Case = struct { src: []const u8, want: ?[]const u8 };

/// Parses `test_header ++ case.src` and checks it fails with `want` somewhere
/// in the message, or parses cleanly when `want` is null.
fn expectCases(cases: []const Case) !void {
    for (cases) |case| {
        const src = try std.mem.concat(
            std.testing.allocator,
            u8,
            &.{ test_header, case.src },
        );
        defer std.testing.allocator.free(src);

        const r = parse(src, std.testing.allocator);
        defer r.deinit(std.testing.allocator);

        if (case.want) |want| {
            if (r.err == null or std.mem.indexOf(u8, r.err.?, want) == null) {
                std.debug.print("{s}\nexpected an error containing '{s}', got '{?s}'\n", .{
                    case.src,
                    want,
                    r.err,
                });
                return error.TestUnexpectedResult;
            }
        } else {
            if (r.err) |e|
                std.debug.print("{s}\n{s}\n", .{ case.src, e });
            try std.testing.expectEqual(@as(?[]const u8, null), r.err);
        }
    }
}

test "net kind is fixed at first mention" {
    try expectCases(&.{
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
    });
}

test "data blocks are shaped by the cell's parameters" {
    try expectCases(&.{
        // WIDTH = 8 divides the tile's 4096 bits into 512 entries, so the
        // address range is 0x000..0x1FF and a value is two hex digits.
        .{ .src = "cell m : BRAM { WIDTH = 8; data { 000: 77 24 5D; } }\n", .want = null },
        .{
            .src = "cell m : BRAM { WIDTH = 8; data { 200: 77; } }\n",
            .want = "addresses only go up to 0x1FF",
        },
        .{
            .src = "cell m : BRAM { WIDTH = 8; data { 000: 1FF; } }\n",
            .want = "Memory values are 8 bits wide, '1FF' does not fit",
        },
        // A run walks the address forward, so it can also walk off the end.
        .{
            .src = "cell m : BRAM { WIDTH = 16; data { 0FE: 1 2 3; } }\n",
            .want = "addresses only go up to 0xFF",
        },
        // The shape comes from the parameters, so they have to be known first.
        .{
            .src = "cell m : BRAM { data { 000: 77; } WIDTH = 8; }\n",
            .want = "WIDTH must be specified before 'data'",
        },
        .{
            .src = "cell r : $rom { DATA_WIDTH = 8; data { 0: 77; } }\n",
            .want = "ADDR_WIDTH must be specified before 'data'",
        },
        .{ .src = "cell m : LUT4 { LUT = 0; }\n", .want = null },
        .{
            .src = "cell m : LUT4 { data { 0: 1; } }\n",
            .want = "Cell 'LUT4' cannot have initial data",
        },
        // A logical memory is not bounded by a tile, so it needs its own cap.
        .{ .src = "cell r : $rom { DATA_WIDTH = 12; ADDR_WIDTH = 4; data { 0: FFF; } }\n", .want = null },
        .{
            .src = "cell r : $rom { DATA_WIDTH = 12; ADDR_WIDTH = 4; data { 0: 1000; } }\n",
            .want = "Memory values are 12 bits wide, '1000' does not fit",
        },
        .{
            .src = "cell r : $ram { DATA_WIDTH = 8; ADDR_WIDTH = 30; data { 0: 1; } }\n",
            .want = "ADDR_WIDTH = 30, the limit is 24",
        },
        // Later blocks union in, on the same "restate freely, contradict
        // never" rule as parameters and port bindings.
        .{
            .src = "cell m : BRAM { WIDTH = 8; data { 000: 77; } }\n" ++
                "cell m { data { 000: 77; 001: 24; } }\n",
            .want = null,
        },
        .{
            .src = "cell m : BRAM { WIDTH = 8; data { 000: 77; } }\n" ++
                "cell m { data { 000: 78; } }\n",
            .want = "address 0x0 was already written before",
        },
    });
}

test "data entries are stored big-endian in fixed-size slots" {
    const src = test_header ++
        \\cell r : $rom {
        \\    DATA_WIDTH = 12;
        \\    ADDR_WIDTH = 4;
        \\    data {
        \\        0: ABC 007;
        \\        F: FFF;
        \\    }
        \\}
        \\
    ;

    const r = parse(src, std.testing.allocator);
    defer r.deinit(std.testing.allocator);
    if (r.err) |e| std.debug.print("{s}\n", .{e});
    try std.testing.expectEqual(@as(?[]const u8, null), r.err);

    const netlist = r.netlist.?;
    const data = &netlist.getCell(netlist.cell_names.find("r").?).data.?;

    try std.testing.expectEqual(@as(u16, 2), data.stride());
    try std.testing.expectEqual(@as(u32, 16), data.depth);

    // 12 bits right-aligned in two bytes: the padding nibble is the top of
    // byte 0, and the hex reads straight across the slot.
    try std.testing.expectEqualSlices(u8, &.{ 0x0A, 0xBC }, data.constSlot(0));
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x07 }, data.constSlot(1));
    try std.testing.expectEqual(@as(u16, 0xFFF), data.get(u16, 15));

    // A run advances the address; everything else is unwritten, and unwritten
    // is distinguishable from a written zero.
    try std.testing.expect(data.isSet(1));
    try std.testing.expect(!data.isSet(2));
    try std.testing.expectEqual(@as(u16, 0), data.get(u16, 2));
}
