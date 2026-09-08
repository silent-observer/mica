const std = @import("std");

const common = @import("common.zig");
const wire_codes = @import("wire_codes.zig");
const DeviceModel = @import("DeviceModel.zig");

const CommonParser = @This();

alloc: std.mem.Allocator,
input: []const u8,
pos: usize,
prev_pos: usize,
errorText: ?[]const u8,

pub fn init(input: []const u8, alloc: std.mem.Allocator) CommonParser {
    return .{
        .alloc = alloc,
        .input = input,
        .pos = 0,
        .prev_pos = 0,
        .errorText = null,
    };
}

pub fn peek(p: *const CommonParser, i: usize) ?u8 {
    return if (p.pos + i < p.input.len)
        p.input[p.pos + i]
    else
        null;
}

pub fn eof(p: *const CommonParser) bool {
    return p.pos >= p.input.len;
}

pub fn err(p: *CommonParser, comptime fmt: []const u8, args: anytype) !noreturn {
    const text = p.input[0..@min(p.pos, p.input.len)];
    const line = 1 + std.mem.countScalar(u8, text, '\n');
    const last_line = std.mem.findScalarLast(u8, text, '\n');
    const col = if (last_line) |ll| p.pos - ll + 1 else p.pos;
    p.errorText = std.fmt.allocPrint(
        p.alloc,
        "{}:{}: " ++ fmt,
        .{ line, col } ++ args,
    ) catch common.oom();
    return error.ParsingError;
}

pub fn skipWhitespace(p: *CommonParser) void {
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

pub fn check(p: *CommonParser, expected: u8) bool {
    p.skipWhitespace();
    return p.peek(0) == expected;
}

pub fn expect(p: *CommonParser, expected: u8) !void {
    p.skipWhitespace();
    const c = p.peek(0) orelse try p.err("Expected '{c}', but got end of file", .{expected});
    if (c != expected) return try p.err("Expected '{c}', but got '{c}'", .{ expected, c });
    p.prev_pos = p.pos;
    p.pos += 1;
}

pub fn undo(p: *CommonParser) void {
    p.pos = p.prev_pos;
}

pub fn checkEof(p: *CommonParser) bool {
    p.skipWhitespace();
    return p.eof();
}

pub fn parseWord(p: *CommonParser) ![]const u8 {
    p.skipWhitespace();
    if (p.eof())
        try p.err("Expected a word, but got end of file", .{});
    if (!std.ascii.isAlphabetic(p.peek(0).?))
        try p.err("Expected a word, but got '{c}'", .{p.peek(0).?});
    const start = p.pos;
    p.prev_pos = p.pos;
    while (p.peek(0)) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') break;
        p.pos += 1;
    }
    const end = p.pos;
    return p.input[start..end];
}

pub fn parseNumber(p: *CommonParser, comptime T: type) !T {
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
    p.prev_pos = p.pos;
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

pub fn parseHexNumber(p: *CommonParser, comptime T: type) !T {
    comptime std.debug.assert(@typeInfo(T) == .int);
    comptime std.debug.assert(@typeInfo(T).int.signedness == .unsigned);
    p.skipWhitespace();
    if (p.eof())
        try p.err("Expected a number, but got end of file", .{});
    const start = p.pos;
    p.prev_pos = p.pos;
    while (p.peek(0)) |c| {
        if (std.mem.countScalar(u8, "0123456789ABCDEFabcdef", c) == 0) break;
        p.pos += 1;
    }
    const end = p.pos;
    const x = std.fmt.parseInt(u64, p.input[start..end], 16) catch
        try p.err("Expected a hex number, but got '{s}'", .{p.input[start..end]});
    const actual_bits: usize = if (x == 0) 1 else std.math.log2_int(u64, x) + 1;
    if (actual_bits > @typeInfo(T).int.bits)
        try p.err(
            "Expected a {}-bit number, but got '{}', which needs {} bits",
            .{ @typeInfo(T).int.bits, x, actual_bits },
        );
    return @intCast(x);
}

pub fn parseString(p: *CommonParser) ![]const u8 {
    p.skipWhitespace();
    const start = p.pos;
    p.prev_pos = p.pos;
    try p.expect('"');
    while (!p.eof()) {
        if (p.check('"')) {
            p.pos += 1;
            if (p.check('"'))
                p.pos += 1
            else
                break;
        } else p.pos += 1;
    }
    const end = p.pos;
    return p.input[start + 1 .. end - 1];
}

pub fn parseDeviceName(p: *CommonParser) ![]const u8 {
    const str = try p.parseString();
    if (str.len != 4)
        try p.err("Expected a 4 character device name like \"M1/S\", but got end of file", .{});

    for (str) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '/' and c != '_')
            try p.err("Only alphanumeric characters, '/' and '_' are allowed in device names" ++
                ", but got '{s}'", .{str});
    }
    return str;
}

pub fn parseTileCoords(p: *CommonParser) !common.TileCoords {
    try p.expect('(');
    const row = try p.parseNumber(u32);
    try p.expect(',');
    const col = try p.parseNumber(u32);
    try p.expect(')');
    return .{ .row = row, .col = col };
}

pub fn parseSwitchCoords(p: *CommonParser) !common.SwitchCoords {
    try p.expect('(');
    const row = try p.parseNumber(u32);
    try p.expect(',');
    const col = try p.parseNumber(u32);
    try p.expect(')');
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

pub fn parseSwitchWire(p: *CommonParser) !?common.SwitchWire {
    const side_word = try p.parseWord();
    const side = sides.get(side_word) orelse {
        p.undo();
        return null;
    };
    try p.expect('.');
    const class_word = try p.parseWord();
    const class = classes.get(class_word) orelse
        try p.err(
            "Expected a wire like N.L1[3], but got '{s}.{s}'",
            .{ side_word, class_word },
        );
    try p.expect('[');
    const track = try p.parseNumber(u3);
    try p.expect(']');

    if (track >= class.tracksPerSwitch())
        try p.err(
            "{f} wires only have {} tracks per switch, tried to access {f}[{}]",
            .{
                class,
                class.tracksPerSwitch(),
                class,
                track,
            },
        );

    return .{
        .side = side,
        .class = class,
        .track = .track(track),
    };
}

pub fn parseDirectionalWire1x1(p: *CommonParser) !?common.DirectionalWire1x1 {
    const side_word = try p.parseWord();
    const side = sides.get(side_word) orelse {
        p.undo();
        return null;
    };

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

    if (track >= class.tracksPerEdge())
        try p.err(
            "{f} wires only have {} tracks, tried to access {f}[{}]",
            .{
                class,
                class.tracksPerEdge(),
                class,
                track,
            },
        );

    return common.DirectionalWire1x1{
        .class = class,
        .side = side,
        .dir = dir,
        .track = .track(track),
    };
}

pub fn parseDirectionalWire4x1(p: *CommonParser) !?common.DirectionalWire4x1 {
    const side_word = try p.parseWord();
    const side = big_edges.get(side_word) orelse {
        p.undo();
        return null;
    };

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

    if (track >= class.tracksPerEdge())
        try p.err(
            "{f} wires only have {} tracks, tried to access {f}[{}]",
            .{
                class,
                class.tracksPerEdge(),
                class,
                track,
            },
        );

    return common.DirectionalWire4x1{
        .class = class,
        .side = side,
        .dir = dir,
        .track = .track(track),
    };
}

pub fn parseSwitchSrc(p: *CommonParser, sw: common.SwitchCoords, model: *const DeviceModel) !wire_codes.SwitchSinkSrc {
    if (std.mem.eql(u8, try p.parseWord(), "code")) {
        const raw = try p.parseNumber(u4);
        return .{ .code = raw };
    } else p.undo();

    if (try p.parseSwitchWire()) |wire|
        return .{ .wire = wire };

    const word = try p.parseWord();
    if (corners.get(word)) |corner| {
        try p.expect('.');
        const output_word = try p.parseWord();
        const tile = sw.tile(corner);
        const tile_type = model.tileType(tile);
        if (logic_outputs.get(output_word)) |lo| {
            // Logic
            if (tile_type != .logic)
                try p.err(
                    "Trying to access output {s}, but tile ({},{}).{s} is {s}, not logic",
                    .{ output_word, sw.row, sw.col, word, @tagName(tile_type) },
                );
            return .{ .out = .{
                .corner = corner,
                .index = @intFromEnum(lo),
            } };
        } else if (std.mem.eql(u8, output_word, "I")) {
            // IO
            if (tile_type != .io)
                try p.err(
                    "Trying to access output I, but tile ({},{}).{s} is {s}, not io",
                    .{ sw.row, sw.col, word, @tagName(tile_type) },
                );
            return .{ .out = .{
                .corner = corner,
                .index = 0,
                .any = true,
            } };
        } else if (std.mem.eql(u8, output_word, "DO")) {
            // BRAM
            try p.expect('[');
            const index = try p.parseNumber(u4);
            try p.expect(']');
            if (tile_type != .bram)
                try p.err(
                    "Trying to access output DO[{}], but tile ({},{}).{s} is {s}, not bram",
                    .{ index, sw.row, sw.col, word, @tagName(tile_type) },
                );
            const tile_idx = (sw.tile(corner).row - 1) % 4;
            if (index / 4 != tile_idx)
                try p.err(
                    "Trying to access output DO[{}] at tile ({},{}).{s}, " ++
                        "but it is cell #{} in Block RAM, which only has outputs DO[{}...{}]",
                    .{
                        index,
                        sw.row,
                        sw.col,
                        word,
                        tile_idx,
                        tile_idx * 4,
                        tile_idx * 4 + 3,
                    },
                );

            return .{ .out = .{
                .corner = corner,
                .index = @intCast(index % 4),
            } };
        } else if (std.mem.eql(u8, output_word, "O")) {
            // DSP
            try p.expect('[');
            const index = try p.parseNumber(u4);
            try p.expect(']');
            if (tile_type != .dsp)
                try p.err(
                    "Trying to access output O[{}], but tile ({},{}).{s} is {s}, not dsp",
                    .{ index, sw.row, sw.col, word, @tagName(tile_type) },
                );
            const tile_idx = (sw.tile(corner).row - 1) % 4;
            if (index / 4 != tile_idx)
                try p.err(
                    "Trying to access output O[{}] at tile ({},{}).{s}, " ++
                        "but it is cell #{} in DSP, which only has outputs O[{}...{}]",
                    .{
                        index,
                        sw.row,
                        sw.col,
                        word,
                        tile_idx,
                        tile_idx * 4,
                        tile_idx * 4 + 3,
                    },
                );

            return .{ .out = .{
                .corner = corner,
                .index = @intCast(index % 4),
            } };
        } else if (std.mem.eql(u8, output_word, "ZERO")) {
            if (tile_type != .inert)
                try p.err(
                    "Trying to access output ZERO, but tile ({},{}).{s} is {s}, not inert",
                    .{ sw.row, sw.col, word, @tagName(tile_type) },
                );
            return .{ .out = .{
                .corner = corner,
                .index = 0,
                .any = true,
            } };
        } else try p.err(
            "Trying to access unknown output '{s}'",
            .{word},
        );
    } else p.undo();

    try p.err(
        "Invalid switch sink: '{s}'",
        .{word},
    );
}

pub fn parseInputConstant(p: *CommonParser) !?u1 {
    p.skipWhitespace();
    return if (p.peek(0) == '0' or p.peek(0) == '1')
        try p.parseNumber(u1)
    else
        null;
}

pub fn parseLogicInputSrc(p: *CommonParser, in: common.LogicInput) !u5 {
    if (try p.parseInputConstant()) |c|
        return wire_codes.encodeLogicInput(in, if (c == 0) .zero else .one).?;

    if (std.mem.eql(u8, try p.parseWord(), "code"))
        return try p.parseNumber(u5)
    else
        p.undo();

    if (logic_outputs.get(try p.parseWord())) |lo|
        return wire_codes.encodeLogicInput(in, .{ .local = lo }).?
    else
        p.undo();

    const wire = try p.parseDirectionalWire1x1() orelse
        try p.err("Expected a logic tile input like N[R].L1[3]", .{});
    return wire_codes.encodeLogicInput(in, .{ .wire = wire }) orelse
        try p.err("For input {f}, wire {f} is not accessible", .{ in, wire });
}

pub fn parseBramInputSrc(p: *CommonParser, in: common.BramInput) !u5 {
    if (try p.parseInputConstant()) |c|
        return wire_codes.encodeBramInput(in, if (c == 0) .zero else .one).?;

    if (std.mem.eql(u8, try p.parseWord(), "code")) {
        return switch (in) {
            .a1, .a2, .di => try p.parseNumber(u4),
            .we1, .we2 => try p.parseNumber(u5),
        };
    } else p.undo();

    const wire = try p.parseDirectionalWire4x1() orelse
        try p.err("Expected a BRAM tile input like H1[R].L1[3]", .{});
    return wire_codes.encodeBramInput(in, .{ .wire = wire }) orelse
        try p.err("For input {f}, wire {f} is not accessible", .{ in, wire });
}

pub fn parseDspInputSrc(p: *CommonParser, in: common.DspInput) !u5 {
    if (try p.parseInputConstant()) |c|
        return wire_codes.encodeDspInput(in, if (c == 0) .zero else .one).?;

    if (std.mem.eql(u8, try p.parseWord(), "code"))
        return try p.parseNumber(u5)
    else
        p.undo();

    const wire = try p.parseDirectionalWire4x1() orelse
        try p.err("Expected a DSP tile input like H1[R].L1[3]", .{});
    return wire_codes.encodeDspInput(in, .{ .wire = wire }) orelse
        try p.err("For input {f}, wire {f} is not accessible", .{ in, wire });
}

pub fn parseIoInputSrc(p: *CommonParser, side: common.Side, in: common.IoInput) !u5 {
    if (try p.parseInputConstant()) |c|
        return wire_codes.encodeIoInput(in, side, if (c == 0) .zero else .one).?;

    if (std.mem.eql(u8, try p.parseWord(), "code"))
        return try p.parseNumber(u5)
    else
        p.undo();

    const wire = try p.parseDirectionalWire1x1() orelse
        try p.err("Expected an IO tile input like N[R].L1[3]", .{});
    return wire_codes.encodeIoInput(in, side, .{ .wire = wire }) orelse
        try p.err("For input {f}, wire {f} is not accessible", .{ in, wire });
}
