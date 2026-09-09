const std = @import("std");

const common = @import("../common.zig");
const wire_codes = @import("../wire_codes.zig");
const Configuration = @import("../Configuration.zig");
const DeviceModel = @import("../DeviceModel.zig");
const CommonParser = @import("../CommonParser.zig");
const blocks = @import("blocks.zig");

const TextParser = @This();

p: CommonParser,
config: ?Configuration,

fn init(input: []const u8, alloc: std.mem.Allocator) TextParser {
    return .{
        .p = .init(input, alloc),
        .config = null,
    };
}

fn parseHeader(p: *TextParser) !void {
    p.config = .init(try p.p.parseFormatAndDevice(), p.p.alloc);
}

fn parseBlock(p: *TextParser) !void {
    const block = try p.p.parseWord();
    if (std.mem.eql(u8, block, "global"))
        try p.parseGlobalBlock()
    else if (std.mem.eql(u8, block, "switch"))
        try p.parseSwitchBlock()
    else blk: {
        inline for (common.TileType.configurable) |t| {
            if (std.mem.eql(u8, block, @tagName(t))) {
                try p.parseTileBlock(blocks.forTile(t));
                break :blk;
            }
        }

        // If we didn't find anything, it's an error
        try p.p.err("Unknown block '{s}'", .{block});
    }
}

const cin_sources: std.StaticStringMap(Configuration.Logic.CinSource) = .initComptime(.{
    .{ "A1", .input },
    .{ "above", .above },
});

fn parseSwitchBlock(p: *TextParser) !void {
    // 'switch' already parsed
    const sw = try p.p.parseSwitchCoords(&p.config.?.model);
    try p.p.expect('{');
    while (!p.p.check('}')) {
        const sink = try p.p.parseSwitchWire() orelse
            try p.p.err("Expected a switch sink like N.L1[3]", .{});

        try p.p.expect('=');
        const source = try p.p.parseSwitchSrc(sw, &p.config.?.model);
        try p.p.expect(';');

        const code = wire_codes.encodeSwitchSink(sink, source) orelse
            try p.p.err("For switch sink {f}, source {f} is unencodable", .{ sink, source });

        const per_side = p.config.?.getSwitch(sw).sides.getPtr(sink.side);
        switch (sink.class) {
            .l1 => per_side.l1[sink.track.int()] = code,
            .l4 => per_side.l4[sink.track.int()] = code,
            .l16 => per_side.l16 = code,
        }
    }
    try p.p.expect('}');
}

fn setBits(val: *u8, x: u8, offset: u3, mask: u8) void {
    val.* = (x << offset) | ~(mask << offset) & val.*;
}

const clocks: std.StaticStringMap(u3) = .initComptime(.{
    .{ "CLK0", 0 },
    .{ "CLK1", 1 },
    .{ "CLK2", 2 },
    .{ "CLK3", 3 },
    .{ "CLK4", 4 },
    .{ "CLK5", 5 },
    .{ "CLK6", 6 },
    .{ "CLK7", 7 },
});
const resets: std.StaticStringMap(u2) = .initComptime(.{
    .{ "RST0", 0 },
    .{ "RST1", 1 },
    .{ "RST2", 2 },
    .{ "RST3", 3 },
});

fn parseCommands(
    p: *TextParser,
    comptime meta: blocks.Metadata,
    tile: common.TileCoords,
    cfg: *meta.Config,
) !void {
    try p.p.expect('{');

    var bram_width: ?u16 = null;
    outer: while (!p.p.check('}')) {
        const word = try p.p.parseWord();
        if (std.mem.eql(u8, word, "in")) {
            if (meta.tile) |t| {
                const cxt = p.config.?.model.inputCxt(t, tile);
                const in: t.Input(), const code: u5 = try p.p.parseInputCommand(t, cxt);
                Configuration.setInput(cfg, in, code);
                continue :outer;
            } else {
                try p.p.err("Block '{s}' can't have inputs!", .{word});
            }
        } else {
            inline for (meta.table) |f| {
                if (std.mem.eql(u8, word, f.word)) {
                    const index: ?u4 = if (f.width != 1) blk: { // Array
                        try p.p.expect('[');
                        const index = try p.p.parseNumber(u4);
                        try p.p.expect(']');
                        if (index >= f.width)
                            try p.p.err(
                                "{s} only has width {}, tried to access {s}[{}]",
                                .{ word, f.width, word, index },
                            );
                        break :blk index;
                    } else null;

                    if (f.kind != .reg and f.kind != .data)
                        try p.p.expect('=');

                    switch (f.kind) {
                        .bit, .bin, .hex => {
                            const IntType = switch (f.kind) {
                                .bit => bool,
                                .bin => |X| X,
                                .hex => |X| X,
                                else => comptime unreachable,
                            };
                            const x: IntType = try p.p.parseNumber(IntType);

                            if (f.width != 1) {
                                // Array
                                @field(cfg.*, f.field)[index.?] = x;
                            } else {
                                // Plain
                                @field(cfg.*, f.field) = x;
                            }
                            try p.p.expect(';');
                        },
                        .width => {
                            if (p.p.check('c')) {
                                const code_word = try p.p.parseWord();
                                if (!std.mem.eql(u8, code_word, "code"))
                                    try p.p.err("BRAM width can only be a number or 'code N'", .{});

                                const x = try p.p.parseNumber(u3);
                                bram_width = 16;
                                @field(cfg.*, f.field) = x;
                            } else {
                                const x = try p.p.parseNumber(u16);
                                const width_val: u3 = switch (x) {
                                    1 => 0,
                                    2 => 1,
                                    4 => 2,
                                    8 => 3,
                                    16 => 4,
                                    else => try p.p.err("BRAM width can only be 1, 2, 4, 8 or 16, not {}", .{x}),
                                };
                                bram_width = x;
                                @field(cfg.*, f.field) = width_val;
                            }
                            try p.p.expect(';');
                        },
                        .cin_src => {
                            const cin_src: Configuration.Logic.CinSource = if (try p.p.parseInputConstant()) |c| blk: {
                                break :blk if (c == 0) .zero else .one;
                            } else blk: {
                                const cin_src_word = try p.p.parseWord();
                                if (cin_sources.get(cin_src_word)) |cs|
                                    break :blk cs
                                else
                                    try p.p.err(
                                        "Expected one of 0, 1, above, A1, but got {s}",
                                        .{cin_src_word},
                                    );
                            };

                            @field(cfg.*, f.field) = cin_src;
                            try p.p.expect(';');
                        },
                        .clk => {
                            const clk_word = try p.p.parseWord();
                            if (clocks.get(clk_word)) |code|
                                @field(cfg.*, f.field) = code
                            else
                                try p.p.err(
                                    "Expected a clock like CLK3, but got {s}",
                                    .{clk_word},
                                );
                            try p.p.expect(';');
                        },
                        .rst => {
                            const rst_word = try p.p.parseWord();
                            if (resets.get(rst_word)) |code|
                                @field(cfg.*, f.field) = code
                            else
                                try p.p.err(
                                    "Expected a clock like RST3, but got {s}",
                                    .{rst_word},
                                );
                            try p.p.expect(';');
                        },
                        .reg => {
                            const num = try p.p.parseNumber(u8);
                            if (num != 1 and num != 2)
                                try p.p.err(
                                    "reg {} is not supported, only reg 1 and reg 2",
                                    .{num},
                                );

                            try p.parseCommands(
                                blocks.reg,
                                tile,
                                &cfg.*.regs[num - 1],
                            );
                        },
                        .data => {
                            if (bram_width == null)
                                try p.p.err("In BRAM block, WIDTH must be specified before data", .{});
                            const data_width = bram_width.?;
                            const addr_depth = 4096 / data_width;
                            try p.p.expect('{');
                            const data = p.config.?.getBramData(tile);
                            while (!p.p.check('}')) {
                                var addr = try p.p.parseHexNumber(u16);

                                try p.p.expect(':');
                                while (!p.p.check(';')) {
                                    if (addr >= addr_depth)
                                        try p.p.err(
                                            "If WIDTH={}, BRAM addresses only go up to 0x{X}, 0x{X} is outside that range",
                                            .{ data_width, addr_depth - 1, addr },
                                        );
                                    switch (data_width) {
                                        1 => data.set(u1, addr, try p.p.parseHexNumber(u1)),
                                        2 => data.set(u2, addr, try p.p.parseHexNumber(u2)),
                                        4 => data.set(u4, addr, try p.p.parseHexNumber(u4)),
                                        8 => data.set(u8, addr, try p.p.parseHexNumber(u8)),
                                        16 => data.set(u16, addr, try p.p.parseHexNumber(u16)),
                                        else => unreachable,
                                    }
                                    addr += 1;
                                }
                                try p.p.expect(';');
                            }
                            try p.p.expect('}');
                        },
                    }

                    continue :outer;
                }
            }

            try p.p.err("No such parameter '{s}' for '{s}' block", .{
                word,
                meta.name(),
            });
        }
    }
    try p.p.expect('}');
}

fn parseGlobalBlock(p: *TextParser) !void {
    // 'global' already parsed
    try p.parseCommands(
        blocks.global,
        undefined,
        &p.config.?.global,
    );
}

fn parseTileBlock(p: *TextParser, comptime meta: blocks.Metadata) !void {
    // Block tag already parsed
    const t = meta.tile.?;
    const tile = try p.p.parseTileCoords(&p.config.?.model);
    if (p.config.?.model.tileType(tile) != t)
        try p.p.err(
            "Tile ({}, {}) is {s}, not {s}",
            .{ tile.row, tile.col, @tagName(p.config.?.model.tileType(tile)), @tagName(t) },
        );
    try p.parseCommands(
        meta,
        tile,
        p.config.?.get(t, tile),
    );
}

pub const Result = struct {
    c: ?Configuration,
    err: ?[]const u8,

    pub fn deinit(r: Result, alloc: std.mem.Allocator) void {
        if (r.c) |c|
            c.deinit(alloc);
        if (r.err) |e|
            alloc.free(e);
    }
};

pub fn parse(input: []const u8, alloc: std.mem.Allocator) Result {
    var p = TextParser.init(input, alloc);
    p.parseHeader() catch return Result{
        .c = null,
        .err = p.p.errorText,
    };

    while (!p.p.checkEof())
        p.parseBlock() catch return Result{
            .c = p.config.?,
            .err = p.p.errorText,
        };

    return Result{
        .c = p.config.?,
        .err = p.p.errorText,
    };
}
