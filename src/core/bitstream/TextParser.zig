const std = @import("std");

const common = @import("../common.zig");
const wire_codes = @import("../wire_codes.zig");
const Configuration = @import("../Configuration.zig");
const DeviceModel = @import("../DeviceModel.zig");
const text_tables = @import("text_tables.zig");
const CommonParser = @import("../CommonParser.zig");

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
    const format_word = try p.p.parseWord();
    if (!std.mem.eql(u8, format_word, "format"))
        try p.p.err("Expected 'format', but got '{s}'", .{format_word});

    const format_int = try p.p.parseNumber(u64);
    if (format_int != 1)
        try p.p.err("Expected 'format 1', but got 'format {}'", .{format_int});

    try p.p.expect(';');

    const device_word = try p.p.parseWord();
    if (!std.mem.eql(u8, device_word, "device"))
        try p.p.err("Expected 'device', but got '{s}'", .{device_word});

    const device_str = try p.p.parseDeviceName();
    try p.p.expect(';');

    const model: DeviceModel = for (&DeviceModel.models) |m| {
        if (std.mem.eql(u8, device_str, m.model_id))
            break m;
    } else try p.p.err("Unknown device model: '{s}'", .{device_str});

    p.config = .init(model, p.p.alloc);
}

fn parseBlock(p: *TextParser) !void {
    const block = try p.p.parseWord();
    if (std.mem.eql(u8, block, "global"))
        try p.parseGlobalBlock()
    else if (std.mem.eql(u8, block, "switch"))
        try p.parseSwitchBlock()
    else if (std.mem.eql(u8, block, "logic"))
        try p.parseLogicBlock()
    else if (std.mem.eql(u8, block, "bram"))
        try p.parseBramBlock()
    else if (std.mem.eql(u8, block, "dsp"))
        try p.parseDspBlock()
    else if (std.mem.eql(u8, block, "io"))
        try p.parseIoBlock()
    else
        try p.p.err("Unknown block '{s}'", .{block});
}

fn parseTileCoords(p: *TextParser) !common.TileCoords {
    const tile = try p.p.parseTileCoords();
    if (tile.row >= p.config.?.model.grid.rows)
        try p.p.err(
            "Model '{s}' only has {} rows, but tile ({}, {}) was used",
            .{
                p.config.?.model.model_id,
                p.config.?.model.grid.rows,
                tile.row,
                tile.col,
            },
        );
    if (tile.col >= p.config.?.model.grid.cols)
        try p.p.err(
            "Model '{s}' only has {} columns, but tile ({}, {}) was used",
            .{
                p.config.?.model.model_id,
                p.config.?.model.grid.cols,
                tile.row,
                tile.col,
            },
        );
    return tile;
}

fn parseSwitchCoords(p: *TextParser) !common.SwitchCoords {
    const sw = try p.p.parseSwitchCoords();
    if (sw.row >= p.config.?.model.grid.vertexRows())
        try p.p.err(
            "Model '{s}' only has {} switch rows, but tile ({}, {}) was used",
            .{
                p.config.?.model.model_id,
                p.config.?.model.grid.vertexRows(),
                sw.row,
                sw.col,
            },
        );
    if (sw.col >= p.config.?.model.grid.vertexCols())
        try p.p.err(
            "Model '{s}' only has {} switch columns, but tile ({}, {}) was used",
            .{
                p.config.?.model.model_id,
                p.config.?.model.grid.vertexCols(),
                sw.row,
                sw.col,
            },
        );
    return sw;
}

const cin_sources: std.StaticStringMap(Configuration.Logic.CinSource) = .initComptime(.{
    .{ "A1", .input },
    .{ "above", .above },
});

fn parseSwitchBlock(p: *TextParser) !void {
    // 'switch' already parsed
    const sw = try p.parseSwitchCoords();
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
    comptime table: anytype,
    comptime input_table: anytype,
    comptime T: type,
    comptime Input: type,
    tile: common.TileCoords,
    t: *T,
) !void {
    try p.p.expect('{');

    var bram_width: ?u16 = null;
    while (!p.p.check('}')) {
        var found = false;
        const word = try p.p.parseWord();
        if (std.mem.eql(u8, word, "in")) {
            found = true;
            const input_word = try p.p.parseWord();
            var found_input = false;
            inline for (input_table) |row| {
                const expected_input_word: []const u8 = comptime row.@"0";
                const input_width: usize = comptime row.@"1";
                const config_field: []const u8 = comptime row.@"2";
                const input_variant: []const u8 = comptime row.@"3";
                if (std.mem.eql(u8, input_word, expected_input_word)) {
                    found_input = true;
                    const index: ?u4 = if (input_width != 0) blk: { // Array
                        try p.p.expect('[');
                        const index = try p.p.parseNumber(u4);
                        try p.p.expect(']');
                        if (index >= input_width)
                            try p.p.err(
                                "Input {s} only has width {}, tried to access {s}[{}]",
                                .{ input_word, input_width, input_word, index },
                            );
                        break :blk index;
                    } else null;

                    try p.p.expect('=');

                    const in = if (@typeInfo(Input) == .@"enum")
                        @field(Input, input_variant)
                    else if (input_width != 0)
                        @unionInit(Input, input_variant, @intCast(index.?))
                    else
                        @unionInit(Input, input_variant, {});

                    const code: u5 = if (Input == common.LogicInput)
                        try p.p.parseLogicInputSrc(in)
                    else if (Input == common.BramInput)
                        try p.p.parseBramInputSrc(in)
                    else if (Input == common.DspInput)
                        try p.p.parseDspInputSrc(in)
                    else if (Input == common.IoInput) blk: {
                        const side = p.config.?.model.ioWireSide(tile);
                        break :blk try p.p.parseIoInputSrc(side, in);
                    } else @panic("Incorrect Input type");

                    if (input_width != 0) {
                        // Array
                        @field(t.*, config_field)[index.?] = @intCast(code);
                    } else if (@typeInfo(@TypeOf(@field(t.*, config_field))) == .int) {
                        // Plain code
                        @field(t.*, config_field) = @intCast(code);
                    } else {
                        // Assume EnumArray
                        const ea: *std.EnumArray(Input, u5) =
                            &@field(t.*, config_field);
                        ea.set(in, code);
                    }
                    try p.p.expect(';');
                }
            }

            if (!found_input) {
                if (T == Configuration.Global)
                    try p.p.err("There can't be inputs in global block", .{})
                else
                    try p.p.err(
                        "No such input '{s}' for {s} tile",
                        .{
                            input_word,
                            @tagName(p.config.?.model.tileType(tile)),
                        },
                    );
            }
        } else {
            inline for (table) |row| {
                const expected_word: []const u8 = row.@"0";
                const width: usize = row.@"1";
                const config_field: []const u8 = row.@"2";
                const value_kind: text_tables.ValueKind = row.@"3";
                if (std.mem.eql(u8, word, expected_word)) {
                    found = true;
                    const index: ?u4 = if (width != 0) blk: { // Array
                        try p.p.expect('[');
                        const index = try p.p.parseNumber(u4);
                        try p.p.expect(']');
                        if (index >= width)
                            try p.p.err(
                                "{s} only has width {}, tried to access {s}[{}]",
                                .{ word, width, word, index },
                            );
                        break :blk index;
                    } else null;

                    if (value_kind != .reg and value_kind != .data)
                        try p.p.expect('=');

                    switch (value_kind) {
                        .bit, .bin, .hex => {
                            const IntType = switch (value_kind) {
                                .bit => bool,
                                .bin => |X| X,
                                .hex => |X| X,
                                else => comptime unreachable,
                            };
                            const x: IntType = try p.p.parseNumber(IntType);

                            if (width != 0) {
                                // Array
                                @field(t.*, config_field)[index.?] = x;
                            } else {
                                // Plain
                                @field(t.*, config_field) = x;
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
                                @field(t.*, config_field) = x;
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
                                @field(t.*, config_field) = width_val;
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

                            @field(t.*, config_field) = cin_src;
                            try p.p.expect(';');
                        },
                        .clk => {
                            const clk_word = try p.p.parseWord();
                            if (clocks.get(clk_word)) |code|
                                @field(t.*, config_field) = code
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
                                @field(t.*, config_field) = code
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
                                text_tables.reg_table,
                                .{},
                                Configuration.Logic.Reg,
                                void,
                                tile,
                                &t.*.regs[num - 1],
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
                }
            }
            if (!found) {
                if (T == Configuration.Global)
                    try p.p.err("No such parameter '{s}' for global block", .{word})
                else
                    try p.p.err(
                        "No such parameter '{s}' for {s} tile",
                        .{
                            word,
                            @tagName(p.config.?.model.tileType(tile)),
                        },
                    );
            }
        }
    }
    try p.p.expect('}');
}

fn parseGlobalBlock(p: *TextParser) !void {
    // 'global' already parsed
    try p.parseCommands(
        text_tables.global_table,
        .{},
        Configuration.Global,
        void,
        undefined,
        &p.config.?.global,
    );
}

fn parseLogicBlock(p: *TextParser) !void {
    // 'logic' already parsed
    const tile = try p.parseTileCoords();
    if (p.config.?.model.tileType(tile) != .logic)
        try p.p.err(
            "Tile ({}, {}) is {s}, not logic",
            .{ tile.row, tile.col, @tagName(p.config.?.model.tileType(tile)) },
        );
    try p.parseCommands(
        text_tables.logic_table,
        text_tables.logic_inputs_table,
        Configuration.Logic,
        common.LogicInput,
        tile,
        p.config.?.getLogic(tile),
    );
}

fn parseBramBlock(p: *TextParser) !void {
    // 'bram' already parsed
    const tile = try p.parseTileCoords();
    if (p.config.?.model.tileType(tile) != .bram)
        try p.p.err(
            "Tile ({}, {}) is {s}, not bram",
            .{ tile.row, tile.col, @tagName(p.config.?.model.tileType(tile)) },
        );
    try p.parseCommands(
        text_tables.bram_table,
        text_tables.bram_inputs_table,
        Configuration.Bram,
        common.BramInput,
        tile,
        p.config.?.getBram(tile),
    );
}

fn parseDspBlock(p: *TextParser) !void {
    // 'dsp' already parsed
    const tile = try p.parseTileCoords();
    if (p.config.?.model.tileType(tile) != .dsp)
        try p.p.err(
            "Tile ({}, {}) is {s}, not dsp",
            .{ tile.row, tile.col, @tagName(p.config.?.model.tileType(tile)) },
        );
    try p.parseCommands(
        text_tables.dsp_table,
        text_tables.dsp_inputs_table,
        Configuration.Dsp,
        common.DspInput,
        tile,
        p.config.?.getDsp(tile),
    );
}

fn parseIoBlock(p: *TextParser) !void {
    // 'io' already parsed
    const tile = try p.parseTileCoords();
    if (p.config.?.model.tileType(tile) != .io)
        try p.p.err(
            "Tile ({}, {}) is {s}, not io",
            .{ tile.row, tile.col, @tagName(p.config.?.model.tileType(tile)) },
        );
    try p.parseCommands(
        text_tables.io_table,
        text_tables.io_inputs_table,
        Configuration.Io,
        common.IoInput,
        tile,
        p.config.?.getIo(tile),
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
