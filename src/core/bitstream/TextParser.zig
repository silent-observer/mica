const std = @import("std");

const common = @import("../common.zig");
const wire_codes = @import("../wire_codes.zig");
const Configuration = @import("../Configuration.zig");
const DeviceModel = @import("../DeviceModel.zig");
const text_tables = @import("text_tables.zig");

const TextParser = @This();

alloc: std.mem.Allocator,
input: []const u8,
pos: usize,
config: ?Configuration,
errorText: ?[]const u8,

fn init(input: []const u8, alloc: std.mem.Allocator) TextParser {
    return .{
        .alloc = alloc,
        .input = input,
        .pos = 0,
        .config = null,
        .errorText = null,
    };
}

fn peek(p: *const TextParser, i: usize) ?u8 {
    return if (p.pos + i < p.input.len)
        p.input[p.pos]
    else
        null;
}

fn eof(p: *const TextParser) bool {
    return p.pos >= p.input.len;
}

fn err(p: *TextParser, comptime fmt: []const u8, args: anytype) !noreturn {
    const line = 1 + std.mem.countScalar(u8, p.input[0..p.pos], '\n');
    const last_line = std.mem.findScalarLast(u8, p.input[0..p.pos], '\n');
    const col = if (last_line) |ll| p.pos - ll + 1 else p.pos;
    p.errorText = std.fmt.allocPrint(
        p.alloc,
        "{}:{}: " ++ fmt,
        .{ line, col } ++ args,
    ) catch common.oom();
    return error.ParsingError;
}

fn skipWhitespace(p: *TextParser) void {
    while (p.peek(0)) |c| {
        switch (c) {
            ' ', '\t', '\r', '\n' => p.pos += 1,
            '/' => if (p.peek(1) == '/') { // Comment
                p.pos += 2;
                while (p.peek(0)) |c2| {
                    if (c2 == '\n') break;
                    p.pos += 1;
                }
            } else return,
            else => return,
        }
    }
}

fn check(p: *TextParser, expected: u8) bool {
    p.skipWhitespace();
    return p.peek(0) == expected;
}

fn expect(p: *TextParser, expected: u8) !void {
    p.skipWhitespace();
    const c = p.peek(0) orelse try p.err("Expected '{c}', but got end of file", .{expected});
    if (c != expected) return try p.err("Expected '{c}', but got '{c}'", .{ expected, c });
    p.pos += 1;
}

fn checkEof(p: *TextParser) bool {
    p.skipWhitespace();
    return p.eof();
}

fn parseWord(p: *TextParser) ![]const u8 {
    p.skipWhitespace();
    if (p.eof())
        try p.err("Expected a word, but got end of file", .{});
    if (!std.ascii.isAlphabetic(p.peek(0).?))
        try p.err("Expected a word, but got '{c}'", .{p.peek(0).?});
    const start = p.pos;
    while (p.peek(0)) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') break;
        p.pos += 1;
    }
    const end = p.pos;
    return p.input[start..end];
}

fn parseNumber(p: *TextParser, comptime T: type) !T {
    if (T == bool)
        return try p.parseNumber(u1) > 0;

    comptime std.debug.assert(@typeInfo(T) == .int);
    comptime std.debug.assert(@typeInfo(T).int.signedness == .unsigned);
    p.skipWhitespace();
    if (p.eof())
        try p.err("Expected a number, but got end of file", .{});
    if (!std.ascii.isDigit(p.peek(0).?))
        try p.err("Expected a number, but got '{c}'", .{p.peek(0).?});
    const start = p.pos;
    while (p.peek(0)) |c| {
        if (std.mem.countScalar(u8, "0123456789ABCDEFabcdef_xb", c) == 0) break;
        p.pos += 1;
    }
    const end = p.pos;
    const x = std.fmt.parseInt(u64, p.input[start..end], 0) catch
        try p.err("Expected a number, but got '{s}'", .{p.input[start..end]});
    const actual_bits: usize = if (x == 0) 1 else std.math.log2_int(u64, x) + 1;
    if (actual_bits > @typeInfo(T).int.bits)
        try p.err(
            "Expected a {}-bit number, but got '{}', which needs {} bits",
            .{ @typeInfo(T).int.bits, x, actual_bits },
        );
    return @intCast(x);
}

fn parseDeviceName(p: *TextParser) ![]const u8 {
    p.skipWhitespace();
    if (p.peek(6) == null)
        try p.err("Expected a 4 character device name like \"M1/S\", but got end of file", .{});

    const device_name = p.input[p.pos .. p.pos + 6];
    if (device_name[0] != '"' or device_name[5] != '"')
        try p.err("Expected a 4 character device name like \"M1/S\", but got '{s}'", .{device_name});
    for (device_name[1..5]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '/' and c != '_')
            try p.err("Only alphanumeric characters, '/' and '_' are allowed in device names" ++
                ", but got '{s}'", .{device_name});
    }
    p.pos += 6;
    return device_name[1..5];
}

fn parseHeader(p: *TextParser) !void {
    const format_word = try p.parseWord();
    if (!std.mem.eql(u8, format_word, "format"))
        try p.err("Expected 'format', but got '{s}'", .{format_word});

    const format_int = try p.parseNumber(u64);
    if (format_int != 1)
        try p.err("Expected 'format 1', but got 'format {}'", .{format_int});

    try p.expect(';');

    const device_word = try p.parseWord();
    if (!std.mem.eql(u8, device_word, "device"))
        try p.err("Expected 'device', but got '{s}'", .{device_word});

    const device_str = try p.parseDeviceName();
    try p.expect(';');

    const model: DeviceModel = for (&DeviceModel.models) |m| {
        if (std.mem.eql(u8, device_str, m.model_id))
            break m;
    } else try p.err("Unknown device model: '{s}'", .{device_str});

    p.config = .init(model, p.alloc);
}

fn parseBlock(p: *TextParser) !void {
    const block = try p.parseWord();
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
        try p.err("Unknown block '{s}'", .{block});
}

fn parseTileCoords(p: *TextParser) !common.TileCoords {
    try p.expect('(');
    const row = try p.parseNumber(u32);
    try p.expect(',');
    const col = try p.parseNumber(u32);
    try p.expect(')');
    if (row >= p.config.?.model.grid.rows)
        try p.err(
            "Model '{s}' only has {} rows, but tile ({}, {}) was used",
            .{
                p.config.?.model.model_id,
                p.config.?.model.grid.rows,
                row,
                col,
            },
        );
    if (col >= p.config.?.model.grid.cols)
        try p.err(
            "Model '{s}' only has {} columns, but tile ({}, {}) was used",
            .{
                p.config.?.model.model_id,
                p.config.?.model.grid.cols,
                row,
                col,
            },
        );
    return .{ .row = row, .col = col };
}

fn parseSwitchCoords(p: *TextParser) !common.SwitchCoords {
    try p.expect('(');
    const row = try p.parseNumber(u32);
    try p.expect(',');
    const col = try p.parseNumber(u32);
    try p.expect(')');
    if (row >= p.config.?.model.grid.vertexRows())
        try p.err(
            "Model '{s}' only has {} switch rows, but tile ({}, {}) was used",
            .{
                p.config.?.model.model_id,
                p.config.?.model.grid.vertexRows(),
                row,
                col,
            },
        );
    if (col >= p.config.?.model.grid.vertexCols())
        try p.err(
            "Model '{s}' only has {} switch columns, but tile ({}, {}) was used",
            .{
                p.config.?.model.model_id,
                p.config.?.model.grid.vertexCols(),
                row,
                col,
            },
        );
    return .{ .row = row, .col = col };
}

const sides: std.StaticStringMap(common.Side) = .initComptime(.{
    .{ "N", .n },
    .{ "E", .e },
    .{ "S", .s },
    .{ "W", .w },
});
const dirs: std.StaticStringMap(common.Direction) = .initComptime(.{
    .{ "U", .up },
    .{ "R", .right },
    .{ "D", .down },
    .{ "L", .left },
});
const corners: std.StaticStringMap(common.Corner) = .initComptime(.{
    .{ "NW", .nw },
    .{ "NE", .ne },
    .{ "SE", .se },
    .{ "SW", .sw },
});
const big_edges: std.StaticStringMap(common.BigEdge) = .initComptime(.{
    .{ "H0", .h0 },
    .{ "H1", .h1 },
    .{ "H2", .h2 },
    .{ "H3", .h3 },
    .{ "H4", .h4 },
    .{ "W0", .w0 },
    .{ "W1", .w1 },
    .{ "W2", .w2 },
    .{ "W3", .w3 },
    .{ "E0", .e0 },
    .{ "E1", .e1 },
    .{ "E2", .e2 },
    .{ "E3", .e3 },
});
const classes: std.StaticStringMap(common.WireClass) = .initComptime(.{
    .{ "L1", .l1 },
    .{ "L4", .l4 },
    .{ "L16", .l16 },
});
const logic_outputs: std.StaticStringMap(wire_codes.LogicOutput) = .initComptime(.{
    .{ "O1A", .o1a },
    .{ "O1B", .o1b },
    .{ "O2A", .o2a },
    .{ "O2B", .o2b },
});
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

const cin_sources: std.StaticStringMap(Configuration.Logic.CinSource) = .initComptime(.{
    .{ "A1", .input },
    .{ "above", .above },
});

fn parseSwitchBlock(p: *TextParser) !void {
    // 'switch' already parsed
    const sw = try p.parseSwitchCoords();
    try p.expect('{');
    while (!p.check('}')) {
        const sink_side_word = try p.parseWord();
        const sink_side = sides.get(sink_side_word) orelse
            try p.err(
                "Expected a sink wire like N.L1[3], but got '{s}'",
                .{sink_side_word},
            );
        try p.expect('.');
        const sink_class_word = try p.parseWord();
        const sink_class = classes.get(sink_class_word) orelse
            try p.err(
                "Expected a sink wire like N.L1[3], but got '{s}.{s}'",
                .{ sink_side_word, sink_class_word },
            );
        try p.expect('[');
        const sink_track = try p.parseNumber(u3);
        try p.expect(']');

        switch (sink_class) {
            .l1 => if (sink_track >= 6)
                try p.err(
                    "L1 wires only have 6 tracks, tried to access L1[{}]",
                    .{sink_track},
                ),
            .l4 => if (sink_track >= 2)
                try p.err(
                    "L4 wires only have 2 tracks per switch, tried to access L4[{}]",
                    .{sink_track},
                ),
            .l16 => if (sink_track != 0)
                try p.err(
                    "L16 wires only have 1 track per switch, tried to access L4[{}]",
                    .{sink_track},
                ),
        }

        const sink = wire_codes.DirectionalWire1x1{
            .class = sink_class,
            .side = sink_side,
            .dir = sink_side.outDir(),
            .local_track = sink_track,
        };

        try p.expect('=');

        const source_word = try p.parseWord();
        const source = if (sides.get(source_word)) |source_side| blk: {
            try p.expect('.');
            const source_class_word = try p.parseWord();
            const source_class = classes.get(source_class_word) orelse
                try p.err(
                    "Expected a source wire like N.L1[3], but got '{s}.{s}'",
                    .{ sink_side_word, source_class_word },
                );
            try p.expect('[');
            const source_track = try p.parseNumber(u3);
            try p.expect(']');
            try p.expect(';');
            break :blk wire_codes.SwitchSinkSrc{ .wire = .{
                .side = source_side,
                .class = source_class,
                .dir = source_side.inDir(),
                .local_track = source_track,
            } };
        } else if (corners.get(source_word)) |source_corner| blk: {
            try p.expect('.');
            const source_output_word = try p.parseWord();
            const tile = sw.tile(source_corner);
            const tile_type = p.config.?.model.tileType(tile);
            if (logic_outputs.get(source_output_word)) |lo| {
                // Logic
                try p.expect(';');
                if (tile_type != .logic)
                    try p.err(
                        "Trying to access output {s}, but tile ({},{}).{s} is {s}, not logic",
                        .{ source_output_word, sw.row, sw.col, source_word, @tagName(tile_type) },
                    );
                break :blk wire_codes.SwitchSinkSrc{ .out = .{
                    .corner = source_corner,
                    .index = @intFromEnum(lo),
                } };
            } else if (std.mem.eql(u8, source_output_word, "I")) {
                // IO
                try p.expect(';');
                if (tile_type != .io)
                    try p.err(
                        "Trying to access output I, but tile ({},{}).{s} is {s}, not io",
                        .{ sw.row, sw.col, source_word, @tagName(tile_type) },
                    );
                break :blk wire_codes.SwitchSinkSrc{ .out = .{
                    .corner = source_corner,
                    .index = 0,
                    .any = true,
                } };
            } else if (std.mem.eql(u8, source_output_word, "DO")) {
                // BRAM
                try p.expect('[');
                const index = try p.parseNumber(u4);
                try p.expect(']');
                try p.expect(';');
                if (tile_type != .bram)
                    try p.err(
                        "Trying to access output DO[{}], but tile ({},{}).{s} is {s}, not bram",
                        .{ index, sw.row, sw.col, source_word, @tagName(tile_type) },
                    );
                const tile_idx = (sw.tile(source_corner).row - 1) % 4;
                if (index / 4 != tile_idx)
                    try p.err(
                        "Trying to access output DO[{}] at tile ({},{}).{s}, " ++
                            "but it is cell #{} in Block RAM, which only has outputs DO[{}...{}]",
                        .{
                            index,
                            sw.row,
                            sw.col,
                            source_word,
                            tile_idx,
                            tile_idx * 4,
                            tile_idx * 4 + 3,
                        },
                    );

                break :blk wire_codes.SwitchSinkSrc{ .out = .{
                    .corner = source_corner,
                    .index = @intCast(index % 4),
                } };
            } else if (std.mem.eql(u8, source_output_word, "O")) {
                // DSP
                try p.expect('[');
                const index = try p.parseNumber(u4);
                try p.expect(']');
                try p.expect(';');
                if (tile_type != .dsp)
                    try p.err(
                        "Trying to access output O[{}], but tile ({},{}).{s} is {s}, not dsp",
                        .{ index, sw.row, sw.col, source_word, @tagName(tile_type) },
                    );
                const tile_idx = (sw.tile(source_corner).row - 1) % 4;
                if (index / 4 != tile_idx)
                    try p.err(
                        "Trying to access output O[{}] at tile ({},{}).{s}, " ++
                            "but it is cell #{} in DSP, which only has outputs O[{}...{}]",
                        .{
                            index,
                            sw.row,
                            sw.col,
                            source_word,
                            tile_idx,
                            tile_idx * 4,
                            tile_idx * 4 + 3,
                        },
                    );

                break :blk wire_codes.SwitchSinkSrc{ .out = .{
                    .corner = source_corner,
                    .index = @intCast(index % 4),
                } };
            } else if (std.mem.eql(u8, source_output_word, "ZERO")) {
                try p.expect(';');
                if (tile_type != .inert)
                    try p.err(
                        "Trying to access output ZERO, but tile ({},{}).{s} is {s}, not inert",
                        .{ sw.row, sw.col, source_word, @tagName(tile_type) },
                    );
                break :blk wire_codes.SwitchSinkSrc{ .out = .{
                    .corner = source_corner,
                    .index = 0,
                    .any = true,
                } };
            } else try p.err(
                "Trying to access unknown output '{s}'",
                .{source_word},
            );
        } else try p.err(
            "Invalid switch sink: '{s}'",
            .{source_word},
        );

        const code = wire_codes.encodeSwitchSink(sink, source) orelse
            @panic("Couldn't find code for switch sink!");

        const per_side = p.config.?.getSwitch(sw).sides.getPtr(sink_side);
        switch (sink_class) {
            .l1 => per_side.l1[sink_track] = code,
            .l4 => per_side.l4[sink_track] = code,
            .l16 => per_side.l16 = code,
        }
    }
    try p.expect('}');
}

fn parseInputConstant(p: *TextParser) !?u1 {
    p.skipWhitespace();
    return if (p.peek(0) == '0' or p.peek(0) == '1')
        try p.parseNumber(u1)
    else
        null;
}

fn parseDirectionalWire1x1(p: *TextParser, side_word: []const u8) !wire_codes.DirectionalWire1x1 {
    const side = sides.get(side_word) orelse
        try p.err(
            "Expected a wire like N[R].L1[3], but got '{s}'",
            .{side_word},
        );

    try p.expect('[');
    const dir_word = try p.parseWord();
    try p.expect(']');
    const dir = dirs.get(dir_word) orelse
        try p.err(
            "Expected a wire like N[R].L1[3], but got '{s}[{s}]'",
            .{ side_word, dir_word },
        );
    if (dir != side.turnDir(.cw) and dir != side.turnDir(.ccw)) {
        try p.err(
            "Wrong direction {s}[{s}], for the side {s} only {s} and {s} are possible",
            .{
                side_word,
                dir_word,
                side_word,
                @tagName(side.turnDir(.cw)),
                @tagName(side.turnDir(.ccw)),
            },
        );
    }

    try p.expect('.');
    const class_word = try p.parseWord();
    const class = classes.get(class_word) orelse
        try p.err(
            "Expected a wire like N[R].L1[3], but got '{s}[{s}].{s}'",
            .{ side_word, dir_word, class_word },
        );
    try p.expect('[');
    const track = try p.parseNumber(u3);
    try p.expect(']');

    switch (class) {
        .l1 => if (track >= 6)
            try p.err(
                "L1 wires only have 6 tracks, tried to access L1[{}]",
                .{track},
            ),
        .l4 => {},
        .l16 => if (track >= 4)
            try p.err(
                "L16 wires only have 4 tracks, tried to access L4[{}]",
                .{track},
            ),
    }

    return wire_codes.DirectionalWire1x1{
        .class = class,
        .side = side,
        .dir = dir,
        .local_track = track,
    };
}

fn parseDirectionalWire4x1(p: *TextParser, side_word: []const u8) !wire_codes.DirectionalWire4x1 {
    const side = big_edges.get(side_word) orelse
        try p.err(
            "Expected a wire like H2[R].L1[3], but got '{s}'",
            .{side_word},
        );

    try p.expect('[');
    const dir_word = try p.parseWord();
    try p.expect(']');
    const dir = dirs.get(dir_word) orelse
        try p.err(
            "Expected a wire like H2[R].L1[3], but got '{s}[{s}]'",
            .{ side_word, dir_word },
        );
    const o = side.orientation();
    if (dir != o.dirDesc() and dir != o.dirAsc()) {
        try p.err(
            "Wrong direction {s}[{s}], for the side {s} only {s} and {s} are possible",
            .{
                side_word,
                dir_word,
                side_word,
                @tagName(o.dirDesc()),
                @tagName(o.dirAsc()),
            },
        );
    }

    try p.expect('.');
    const class_word = try p.parseWord();
    const class = classes.get(class_word) orelse
        try p.err(
            "Expected a wire like H2[R].L1[3], but got '{s}[{s}].{s}'",
            .{ side_word, dir_word, class_word },
        );
    try p.expect('[');
    const track = try p.parseNumber(u3);
    try p.expect(']');

    switch (class) {
        .l1 => if (track >= 6)
            try p.err(
                "L1 wires only have 6 tracks, tried to access L1[{}]",
                .{track},
            ),
        .l4 => {},
        .l16 => if (track >= 4)
            try p.err(
                "L16 wires only have 4 tracks, tried to access L4[{}]",
                .{track},
            ),
    }

    return wire_codes.DirectionalWire4x1{
        .class = class,
        .side = side,
        .dir = dir,
        .local_track = track,
    };
}

fn parseLogicInputSrc(p: *TextParser, _: common.TileCoords, in: common.LogicInput) !u5 {
    if (try p.parseInputConstant()) |c|
        return wire_codes.encodeLogicInput(in, if (c == 0) .zero else .one).?;

    const word = try p.parseWord();
    if (std.mem.eql(u8, word, "code"))
        return try p.parseNumber(u5);

    if (logic_outputs.get(word)) |lo|
        return wire_codes.encodeLogicInput(in, .{ .local = lo }).?;

    const wire = try p.parseDirectionalWire1x1(word);
    return wire_codes.encodeLogicInput(in, .{ .wire = wire }) orelse
        try p.err("For input {f}, wire {f} is not accessible", .{ in, wire });
}

fn parseBramInputSrc(p: *TextParser, _: common.TileCoords, in: common.BramInput) !u5 {
    if (try p.parseInputConstant()) |c|
        return wire_codes.encodeBramInput(in, if (c == 0) .zero else .one).?;

    const word = try p.parseWord();
    if (std.mem.eql(u8, word, "code")) {
        return switch (in) {
            .a1, .a2, .di => try p.parseNumber(u4),
            .we1, .we2 => try p.parseNumber(u5),
        };
    }

    const wire = try p.parseDirectionalWire4x1(word);
    return wire_codes.encodeBramInput(in, .{ .wire = wire }) orelse
        try p.err("For input {f}, wire {f} is not accessible", .{ in, wire });
}

fn parseDspInputSrc(p: *TextParser, _: common.TileCoords, in: common.DspInput) !u5 {
    if (try p.parseInputConstant()) |c|
        return wire_codes.encodeDspInput(in, if (c == 0) .zero else .one).?;

    const word = try p.parseWord();
    if (std.mem.eql(u8, word, "code"))
        return try p.parseNumber(u5);

    const wire = try p.parseDirectionalWire4x1(word);
    return wire_codes.encodeDspInput(in, .{ .wire = wire }) orelse
        try p.err("For input {f}, wire {f} is not accessible", .{ in, wire });
}

fn parseIoInputSrc(p: *TextParser, tile: common.TileCoords, in: common.IoInput) !u5 {
    const side = p.config.?.model.ioWireSide(tile);
    if (try p.parseInputConstant()) |c|
        return wire_codes.encodeIoInput(in, side, if (c == 0) .zero else .one).?;

    const word = try p.parseWord();
    if (std.mem.eql(u8, word, "code"))
        return try p.parseNumber(u5);

    const wire = try p.parseDirectionalWire1x1(word);
    return wire_codes.encodeIoInput(in, side, .{ .wire = wire }) orelse
        try p.err("For input {f}, wire {f} is not accessible", .{ in, wire });
}

fn setBits(val: *u8, x: u8, offset: u3, mask: u8) void {
    val.* = (x << offset) | ~(mask << offset) & val.*;
}

fn parseCommands(
    p: *TextParser,
    comptime table: anytype,
    comptime input_table: anytype,
    comptime T: type,
    comptime Input: type,
    comptime parse_input: fn (p: *TextParser, tile: common.TileCoords, in: Input) error{ParsingError}!u5,
    tile: common.TileCoords,
    t: *T,
) !void {
    try p.expect('{');

    while (!p.check('}')) {
        const word = try p.parseWord();
        if (std.mem.eql(u8, word, "in")) {
            const input_word = try p.parseWord();
            inline for (input_table) |row| {
                const expected_input_word: []const u8 = comptime row.@"0";
                const input_width: usize = comptime row.@"1";
                const config_field: []const u8 = comptime row.@"2";
                const input_variant: []const u8 = comptime row.@"3";
                if (std.mem.eql(u8, input_word, expected_input_word)) {
                    const index: ?u4 = if (input_width != 0) blk: { // Array
                        try p.expect('[');
                        const index = try p.parseNumber(u4);
                        try p.expect(']');
                        if (index >= input_width)
                            try p.err(
                                "Input {s} only has width {}, tried to access {s}[{}]",
                                .{ input_word, input_width, input_word, index },
                            );
                        break :blk index;
                    } else null;

                    try p.expect('=');

                    const in = if (@typeInfo(Input) == .@"enum")
                        @field(Input, input_variant)
                    else if (input_width != 0)
                        @unionInit(Input, input_variant, @intCast(index.?))
                    else
                        @unionInit(Input, input_variant, {});
                    const code: u5 = try parse_input(p, tile, in);

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
                    try p.expect(';');
                }
            }
        } else {
            var bram_width: ?u16 = null;
            inline for (table) |row| {
                const expected_word: []const u8 = row.@"0";
                const width: usize = row.@"1";
                const config_field: []const u8 = row.@"2";
                const value_kind: text_tables.ValueKind = row.@"3";
                if (std.mem.eql(u8, word, expected_word)) {
                    const index: ?u4 = if (width != 0) blk: { // Array
                        try p.expect('[');
                        const index = try p.parseNumber(u4);
                        try p.expect(']');
                        if (index >= width)
                            try p.err(
                                "{s} only has width {}, tried to access {s}[{}]",
                                .{ word, width, word, index },
                            );
                        break :blk index;
                    } else null;

                    if (value_kind != .reg and value_kind != .data)
                        try p.expect('=');

                    switch (value_kind) {
                        .bit, .bin, .dec, .hex => {
                            const IntType = switch (value_kind) {
                                .bit => bool,
                                .bin => |X| X,
                                .dec => |X| X,
                                .hex => |X| X,
                                else => comptime unreachable,
                            };
                            const x: IntType = try p.parseNumber(IntType);

                            if (width != 0) {
                                // Array
                                @field(t.*, config_field)[index.?] = x;
                            } else {
                                // Plain
                                @field(t.*, config_field) = x;
                            }
                            try p.expect(';');
                        },
                        .width => {
                            const x = try p.parseNumber(u16);
                            const width_val: u3 = switch (x) {
                                1 => 0,
                                2 => 1,
                                4 => 2,
                                8 => 3,
                                16 => 4,
                                else => try p.err("BRAM width can only be 1, 2, 4, 8 or 16, not {}", .{x}),
                            };
                            bram_width = x;
                            @field(t.*, config_field) = width_val;
                            try p.expect(';');
                        },
                        .cin_src => {
                            const cin_src: Configuration.Logic.CinSource = if (try p.parseInputConstant()) |c| blk: {
                                break :blk if (c == 0) .zero else .one;
                            } else blk: {
                                const cin_src_word = try p.parseWord();
                                if (cin_sources.get(cin_src_word)) |cs|
                                    break :blk cs
                                else
                                    try p.err(
                                        "Expected one of 0, 1, above, A1, but got {s}",
                                        .{cin_src_word},
                                    );
                            };

                            @field(t.*, config_field) = cin_src;
                            try p.expect(';');
                        },
                        .clk => {
                            const clk_word = try p.parseWord();
                            if (clocks.get(clk_word)) |code|
                                @field(t.*, config_field) = code
                            else
                                try p.err(
                                    "Expected a clock like CLK3, but got {s}",
                                    .{clk_word},
                                );
                            try p.expect(';');
                        },
                        .rst => {
                            const rst_word = try p.parseWord();
                            if (resets.get(rst_word)) |code|
                                @field(t.*, config_field) = code
                            else
                                try p.err(
                                    "Expected a clock like RST3, but got {s}",
                                    .{rst_word},
                                );
                            try p.expect(';');
                        },
                        .reg => {
                            const num = try p.parseNumber(u8);
                            if (num != 1 and num != 2)
                                try p.err(
                                    "reg {} is not supported, only reg 1 and reg 2",
                                    .{num},
                                );

                            try p.parseCommands(
                                text_tables.reg_table,
                                .{},
                                Configuration.Logic.Reg,
                                common.LogicInput,
                                parseLogicInputSrc,
                                tile,
                                &t.*.regs[num - 1],
                            );
                        },
                        .data => {
                            if (bram_width == null)
                                try p.err("In BRAM block, WIDTH must be specified before data", .{});
                            const data_width = bram_width.?;
                            const addr_depth = 4096 / data_width;
                            try p.expect('{');
                            const data = p.config.?.getBramData(tile);
                            while (!p.check('}')) {
                                const addr = try p.parseNumber(u16);
                                if (addr >= addr_depth)
                                    try p.err(
                                        "If WIDTH={}, BRAM addresses only go up to 0x{X}, 0x{X} is outside that range",
                                        .{ data_width, addr_depth - 1, addr },
                                    );

                                try p.expect(':');
                                while (!p.check(';')) {
                                    const x = try p.parseNumber(u16);
                                    if (x >= (@as(u32, 1) << @intCast(data_width))) {
                                        try p.err(
                                            "If WIDTH={}, BRAM data only go up to 0x{X}, 0x{X} is outside that range",
                                            .{ data_width, (@as(u32, 1) << @intCast(data_width)) - 1, x },
                                        );
                                    }
                                    switch (data_width) {
                                        1 => {
                                            const byte_idx = addr / 8;
                                            const bit_idx: u3 = @intCast(addr % 8);
                                            setBits(
                                                &data.data[byte_idx],
                                                @intCast(x),
                                                bit_idx,
                                                0x1,
                                            );
                                        },
                                        2 => {
                                            const byte_idx = addr / 4;
                                            const bit_idx: u3 = @intCast(2 * (addr % 4));
                                            setBits(
                                                &data.data[byte_idx],
                                                @intCast(x),
                                                bit_idx,
                                                0x3,
                                            );
                                        },
                                        4 => {
                                            const byte_idx = addr / 2;
                                            const bit_idx: u3 = @intCast(4 * (addr % 2));
                                            setBits(
                                                &data.data[byte_idx],
                                                @intCast(x),
                                                bit_idx,
                                                0xF,
                                            );
                                        },
                                        8 => data.data[addr] = @intCast(x),
                                        16 => {
                                            data.data[2 * addr] = @intCast(x & 0xFF);
                                            data.data[2 * addr + 1] = @intCast(x >> 8);
                                        },
                                        else => unreachable,
                                    }
                                }
                            }
                            try p.expect('}');
                        },
                    }
                }
            }
        }
    }
    try p.expect('}');
}

fn parseGlobalBlock(p: *TextParser) !void {
    // 'global' already parsed
    try p.parseCommands(
        text_tables.global_table,
        .{},
        Configuration.Global,
        common.LogicInput,
        parseLogicInputSrc,
        .{ .row = 0, .col = 0 },
        &p.config.?.global,
    );
}

fn parseLogicBlock(p: *TextParser) !void {
    // 'logic' already parsed
    const tile = try p.parseTileCoords();
    if (p.config.?.model.tileType(tile) != .logic)
        try p.err(
            "Tile ({}, {}) is {s}, not logic",
            .{ tile.row, tile.col, @tagName(p.config.?.model.tileType(tile)) },
        );
    try p.parseCommands(
        text_tables.logic_table,
        text_tables.logic_inputs_table,
        Configuration.Logic,
        common.LogicInput,
        parseLogicInputSrc,
        tile,
        p.config.?.getLogic(tile),
    );
}

fn parseBramBlock(p: *TextParser) !void {
    // 'bram' already parsed
    const tile = try p.parseTileCoords();
    if (p.config.?.model.tileType(tile) != .bram)
        try p.err(
            "Tile ({}, {}) is {s}, not bram",
            .{ tile.row, tile.col, @tagName(p.config.?.model.tileType(tile)) },
        );
    try p.parseCommands(
        text_tables.bram_table,
        text_tables.bram_inputs_table,
        Configuration.Bram,
        common.BramInput,
        parseBramInputSrc,
        tile,
        p.config.?.getBram(tile),
    );
}

fn parseDspBlock(p: *TextParser) !void {
    // 'dsp' already parsed
    const tile = try p.parseTileCoords();
    if (p.config.?.model.tileType(tile) != .dsp)
        try p.err(
            "Tile ({}, {}) is {s}, not dsp",
            .{ tile.row, tile.col, @tagName(p.config.?.model.tileType(tile)) },
        );
    try p.parseCommands(
        text_tables.dsp_table,
        text_tables.dsp_inputs_table,
        Configuration.Dsp,
        common.DspInput,
        parseDspInputSrc,
        tile,
        p.config.?.getDsp(tile),
    );
}

fn parseIoBlock(p: *TextParser) !void {
    // 'io' already parsed
    const tile = try p.parseTileCoords();
    if (p.config.?.model.tileType(tile) != .io)
        try p.err(
            "Tile ({}, {}) is {s}, not io",
            .{ tile.row, tile.col, @tagName(p.config.?.model.tileType(tile)) },
        );
    try p.parseCommands(
        text_tables.io_table,
        text_tables.io_inputs_table,
        Configuration.Io,
        common.IoInput,
        parseIoInputSrc,
        tile,
        p.config.?.getIo(tile),
    );
}

pub const Result = struct {
    c: ?Configuration,
    err: ?[]const u8,
};

pub fn parse(input: []const u8, alloc: std.mem.Allocator) Result {
    var p = TextParser.init(input, alloc);
    p.parseHeader() catch return Result{
        .c = null,
        .err = p.errorText,
    };

    while (!p.checkEof())
        p.parseBlock() catch return Result{
            .c = p.config.?,
            .err = p.errorText,
        };

    return Result{
        .c = p.config.?,
        .err = p.errorText,
    };
}
