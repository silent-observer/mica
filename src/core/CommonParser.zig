const std = @import("std");

const common = @import("common.zig");
const wire_codes = @import("wire_codes.zig");
const DeviceModel = @import("DeviceModel.zig");

const CommonParser = @This();

alloc: std.mem.Allocator,
input: []const u8,
pos: usize,
errorText: ?[]const u8,

pub fn init(input: []const u8, alloc: std.mem.Allocator) CommonParser {
    return .{
        .alloc = alloc,
        .input = input,
        .pos = 0,
        .errorText = null,
    };
}

const Mark = enum(usize) { _ };
pub fn mark(p: *const CommonParser) Mark {
    return @enumFromInt(p.pos);
}
pub fn reset(p: *CommonParser, m: Mark) void {
    p.pos = @intFromEnum(m);
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
                while (p.peek(0)) |c2| : (p.pos += 1) {
                    if (c2 == '\n') break;
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
    p.pos += 1;
}

pub fn checkEof(p: *CommonParser) bool {
    p.skipWhitespace();
    return p.eof();
}

pub fn parseWord(p: *CommonParser) ![]const u8 {
    return p.parseWordExtra("_");
}

pub fn parseWordExtra(p: *CommonParser, comptime extra: []const u8) ![]const u8 {
    p.skipWhitespace();
    if (p.eof())
        try p.err("Expected a word, but got end of file", .{});
    if (!std.ascii.isAlphabetic(p.peek(0).?))
        try p.err("Expected a word, but got '{c}'", .{p.peek(0).?});
    const start = p.pos;
    while (p.peek(0)) |c| : (p.pos += 1) {
        var ok = false;
        if (std.ascii.isAlphanumeric(c)) ok = true;
        inline for (extra) |ext| {
            if (c == ext)
                ok = true;
        }
        if (!ok) break;
    }
    const end = p.pos;
    return p.input[start..end];
}

/// Scans the digits `chars` accepts, parses them in `base`, and checks the
/// result fits `T`. `base` 0 lets the `0x`/`0b` prefix pick it.
fn parseDigits(
    p: *CommonParser,
    comptime T: type,
    comptime chars: []const u8,
    comptime base: u8,
    comptime what: []const u8,
) !T {
    comptime std.debug.assert(@typeInfo(T) == .int);
    comptime std.debug.assert(@typeInfo(T).int.signedness == .unsigned);
    const start = p.pos;
    while (p.peek(0)) |c| : (p.pos += 1) {
        if (std.mem.countScalar(u8, chars, c) == 0) break;
    }
    const text = p.input[start..p.pos];
    const x = std.fmt.parseInt(u64, text, base) catch
        try p.err("Expected " ++ what ++ ", but got '{s}'", .{text});
    const actual_bits: usize = if (x == 0) 1 else std.math.log2_int(u64, x) + 1;
    if (actual_bits > @typeInfo(T).int.bits)
        try p.err(
            "Expected a {}-bit number, but got '{}', which needs {} bits",
            .{ @typeInfo(T).int.bits, x, actual_bits },
        );
    return @intCast(x);
}

pub fn parseNumber(p: *CommonParser, comptime T: type) !T {
    if (T == bool)
        return try p.parseNumber(u1) > 0;

    p.skipWhitespace();
    if (p.eof())
        try p.err("Expected a number, but got end of file", .{});
    if (!std.ascii.isDigit(p.peek(0).?))
        try p.err("Expected a number, but got '{c}'", .{p.peek(0).?});
    return try p.parseDigits(T, "0123456789ABCDEFabcdef_xb", 0, "a number");
}

pub fn parseHexNumber(p: *CommonParser, comptime T: type) !T {
    p.skipWhitespace();
    if (p.eof())
        try p.err("Expected a number, but got end of file", .{});
    return try p.parseDigits(T, "0123456789ABCDEFabcdef", 16, "a hex number");
}

pub fn parseString(p: *CommonParser) ![]const u8 {
    p.skipWhitespace();
    const start = p.pos;
    try p.expect('"');
    const end = while (!p.eof()) : (p.pos += 1) {
        if (p.peek(0) == '"') {
            p.pos += 1;
            // A doubled quote is an escaped one, so the string continues.
            if (p.peek(0) != '"')
                break p.pos;
        }
    } else try p.err("Unterminated string", .{});
    return p.input[start + 1 .. end - 1];
}

/// Both formats open with the same two lines, `format 1;` and `device "M1/S";`
/// -- the netlist then continues with `design` and `pass`, the bitstream goes
/// straight to its blocks.
pub fn parseFormatAndDevice(p: *CommonParser) !DeviceModel {
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

    return for (&DeviceModel.models) |m| {
        if (std.mem.eql(u8, device_str, m.model_id))
            break m;
    } else try p.err("Unknown device model: '{s}'", .{device_str});
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

/// Parses `(row, col)` and range-checks it against the model. `C` picks which
/// grid the coordinates address: tiles include the IO ring, switchboxes sit on
/// its vertices, so the two have different bounds.
fn parseCoords(p: *CommonParser, comptime C: type, model: *const DeviceModel) !C {
    const rows, const cols, const what = switch (C) {
        common.TileCoords => .{ model.grid.rows, model.grid.cols, "tile " },
        common.SwitchCoords => .{ model.grid.vertexRows(), model.grid.vertexCols(), "switch " },
        else => @compileError("not a coordinate type: " ++ @typeName(C)),
    };

    try p.expect('(');
    const row = try p.parseNumber(u32);
    try p.expect(',');
    const col = try p.parseNumber(u32);
    try p.expect(')');
    if (row >= rows)
        try p.err(
            "Model '{s}' only has {} " ++ what ++ "rows, but tile ({}, {}) was used",
            .{ model.model_id, rows, row, col },
        );
    if (col >= cols)
        try p.err(
            "Model '{s}' only has {} " ++ what ++ "columns, but tile ({}, {}) was used",
            .{ model.model_id, cols, row, col },
        );
    return .{ .row = row, .col = col };
}

pub fn parseTileCoords(p: *CommonParser, model: *const DeviceModel) !common.TileCoords {
    return try p.parseCoords(common.TileCoords, model);
}

pub fn parseSwitchCoords(p: *CommonParser, model: *const DeviceModel) !common.SwitchCoords {
    return try p.parseCoords(common.SwitchCoords, model);
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
    const m = p.mark();
    const side_word = try p.parseWord();
    const side = sides.get(side_word) orelse {
        p.reset(m);
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

/// Parses a connection-box wire name like `N[R].L1[3]` (1x1 tiles) or
/// `H2[R].L1[3]` (4x1 BRAM/DSP tiles). Returns null, having consumed nothing,
/// when the leading word does not name an edge -- the caller then tries
/// another alternative.
fn parseDirectionalWire(p: *CommonParser, comptime W: type) !?W {
    const edges, const example = switch (W) {
        common.DirectionalWire1x1 => .{ sides, "N[R].L1[3]" },
        common.DirectionalWire4x1 => .{ big_edges, "H2[R].L1[3]" },
        else => @compileError("not a directional wire type: " ++ @typeName(W)),
    };

    const m = p.mark();
    const side_word = try p.parseWord();
    const side = edges.get(side_word) orelse {
        p.reset(m);
        return null;
    };

    try p.expect('[');
    const dir_word = try p.parseWord();
    try p.expect(']');
    const dir = dirs.get(dir_word) orelse
        try p.err(
            "Expected a wire like " ++ example ++ ", but got '{s}[{s}]'",
            .{ side_word, dir_word },
        );
    const legal = side.legalDirs();
    if (dir != legal[0] and dir != legal[1])
        try p.err(
            "Wrong direction {s}[{s}], for the side {s} only {s} and {s} are possible",
            .{
                side_word,
                dir_word,
                side_word,
                @tagName(legal[0]),
                @tagName(legal[1]),
            },
        );

    try p.expect('.');
    const class_word = try p.parseWord();
    const class = classes.get(class_word) orelse
        try p.err(
            "Expected a wire like " ++ example ++ ", but got '{s}[{s}].{s}'",
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

    return W{
        .class = class,
        .side = side,
        .dir = dir,
        .track = .track(track),
    };
}

pub fn parseDirectionalWire1x1(p: *CommonParser) !?common.DirectionalWire1x1 {
    return try p.parseDirectionalWire(common.DirectionalWire1x1);
}

pub fn parseDirectionalWire4x1(p: *CommonParser) !?common.DirectionalWire4x1 {
    return try p.parseDirectionalWire(common.DirectionalWire4x1);
}

/// `DO[n]` on BRAM and `O[n]` on DSP name one of the four outputs of a cell in
/// a 4x1 tile. The index runs across the whole tile, so it has to land in the
/// quarter belonging to this corner's row (§"Switchboxes").
fn parseBigTileOutput(
    p: *CommonParser,
    sw: common.SwitchCoords,
    corner: common.Corner,
    corner_word: []const u8,
    tile_type: common.TileType,
    comptime t: common.TileType,
    comptime keyword: []const u8,
    comptime long_name: []const u8,
) !wire_codes.SwitchSinkSrc {
    try p.expect('[');
    const index = try p.parseNumber(u4);
    try p.expect(']');
    if (tile_type != t)
        try p.err(
            "Trying to access output " ++ keyword ++ "[{}], but tile ({},{}).{s} is {s}, not " ++ @tagName(t),
            .{ index, sw.row, sw.col, corner_word, @tagName(tile_type) },
        );

    const tile_idx = (sw.tile(corner).row - 1) % 4;
    if (index / 4 != tile_idx)
        try p.err(
            "Trying to access output " ++ keyword ++ "[{}] at tile ({},{}).{s}, " ++
                "but it is cell #{} in " ++ long_name ++
                ", which only has outputs " ++ keyword ++ "[{}...{}]",
            .{
                index,
                sw.row,
                sw.col,
                corner_word,
                tile_idx,
                tile_idx * 4,
                tile_idx * 4 + 3,
            },
        );

    return .{ .out = .{
        .corner = corner,
        .index = @intCast(index % 4),
    } };
}

pub fn parseSwitchSrc(p: *CommonParser, sw: common.SwitchCoords, model: *const DeviceModel) !wire_codes.SwitchSinkSrc {
    const m = p.mark();
    if (std.mem.eql(u8, try p.parseWord(), "code")) {
        const raw = try p.parseNumber(u4);
        return .{ .code = raw };
    } else p.reset(m);

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
            return try p.parseBigTileOutput(sw, corner, word, tile_type, .bram, "DO", "Block RAM");
        } else if (std.mem.eql(u8, output_word, "O")) {
            return try p.parseBigTileOutput(sw, corner, word, tile_type, .dsp, "O", "DSP");
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
            .{output_word},
        );
    } else p.reset(m);

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

pub fn parseInputSrc(
    p: *CommonParser,
    comptime t: common.TileType,
    in: t.Input(),
    cxt: t.Input().Cxt,
) !u5 {
    if (try p.parseInputConstant()) |c|
        return wire_codes.encodeInput(t, in, cxt, if (c == 0) .zero else .one).?;

    const m = p.mark();
    if (std.mem.eql(u8, try p.parseWord(), "code")) {
        return switch (wire_codes.codeBits(t, in)) {
            4 => try p.parseNumber(u4),
            5 => try p.parseNumber(u5),
            else => unreachable,
        };
    } else p.reset(m);

    if (t == .logic) {
        if (logic_outputs.get(try p.parseWord())) |lo|
            return wire_codes.encodeInput(t, in, cxt, .{ .local = lo }).?
        else
            p.reset(m);
    }

    const wire = switch (comptime t.big()) {
        false => try p.parseDirectionalWire1x1() orelse
            try p.err("Expected a logic tile input like N[R].L1[3]", .{}),
        true => try p.parseDirectionalWire4x1() orelse
            try p.err("Expected a BRAM tile input like H1[R].L1[3]", .{}),
    };

    return wire_codes.encodeInput(t, in, cxt, .{ .wire = wire }) orelse
        try p.err("For input {f}, wire {f} is not accessible", .{ in, wire });
}

pub fn parseInputCommand(
    p: *CommonParser,
    comptime t: common.TileType,
    cxt: t.Input().Cxt,
) !struct { t.Input(), u5 } {
    // 'in' already parsed
    const input_word = try p.parseWord();
    inline for (std.meta.fields(t.Input())) |f| {
        const expected_input_word: [f.name.len]u8 = comptime blk: {
            var buf: [f.name.len]u8 = undefined;
            _ = std.ascii.upperString(&buf, f.name);
            break :blk buf;
        };

        const input_width: usize = t.Input().WIDTHS.get(@field(t.Input(), f.name));
        const input_variant: []const u8 = f.name;
        if (std.mem.eql(u8, input_word, &expected_input_word)) {
            const index: ?u4 = if (@typeInfo(t.Input()) == .@"union" and f.type != void) blk: { // Array
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

            const in = if (@typeInfo(t.Input()) == .@"enum")
                @field(t.Input(), input_variant)
            else if (f.type == void)
                @unionInit(t.Input(), input_variant, {})
            else
                @unionInit(t.Input(), input_variant, @intCast(index.?));

            const code: u5 = try p.parseInputSrc(t, in, cxt);
            try p.expect(';');
            return .{ in, code };
        }
    }

    try p.err(
        "No such input '{s}' for {s} tile",
        .{ input_word, @tagName(t) },
    );
}

/// Parses one hex literal of a `data {}` entry into `slot`, right-aligned and
/// big-endian, so the padding bits land in the high bits of `slot[0]`. Both
/// formats are big-endian throughout, which is what lets a sink keeping
/// entries in this layout store them without shifting.
///
/// Leading zeroes are free; a non-zero digit above `data_width` is an error,
/// which is the check `parseHexNumber`'s width-typed return used to give.
fn parseMemSlot(p: *CommonParser, slot: []u8, data_width: u16) !void {
    p.skipWhitespace();
    const start = p.pos;
    while (p.peek(0)) |c| : (p.pos += 1) {
        if (!std.ascii.isHex(c)) break;
    }
    const text = p.input[start..p.pos];
    if (text.len == 0) {
        if (p.eof())
            try p.err("Expected a hex number, but got end of file", .{});
        try p.err("Expected a hex number, but got '{c}'", .{p.peek(0).?});
    }

    @memset(slot, 0);
    // Right to left, so digit `i` from the end is nibble `i` from the end of
    // the slot regardless of how many digits were written.
    for (0..text.len) |i| {
        const digit = std.fmt.charToDigit(text[text.len - 1 - i], 16) catch unreachable;
        if (digit == 0) continue;
        if (i >= slot.len * 2)
            try p.err("Memory values are {} bits wide, '{s}' does not fit", .{ data_width, text });
        const byte = slot.len - 1 - i / 2;
        slot[byte] |= if (i % 2 == 0) digit else @as(u8, digit) << 4;
    }

    // The slot is whole bytes, so a width like 12 leaves padding to check.
    const pad: u4 = @intCast(slot.len * 8 - data_width);
    if (pad > 0 and slot[0] >> @intCast(8 - pad) != 0)
        try p.err("Memory values are {} bits wide, '{s}' does not fit", .{ data_width, text });
}

/// Parses the body of a `data {}` block: a sparse list of runs, each an
/// address followed by one value per consecutive address from there.
///
/// Values reach `sink.setSlot(addr, bytes)` as a `common.memStride`-byte
/// big-endian slot, so a sink that stores entries that way can copy them and
/// one that packs them tighter - the bitstream's `Bram.Data` - can widen
/// them, without either knowing about the other. `setSlot` returns whether `addr` already
/// had a value, which the netlist's monotonic-union rule rejects and the
/// bitstream, having no such rule, never reports.
pub fn parseRamData(
    p: *CommonParser,
    addr_width: u8,
    data_width: u16,
    sink: anytype,
) !void {
    if (addr_width > common.mem_max_addr_width)
        try p.err(
            "Cannot declare a memory with ADDR_WIDTH = {}, the limit is {}",
            .{ addr_width, common.mem_max_addr_width },
        );
    if (data_width == 0 or data_width > common.mem_max_data_width)
        try p.err(
            "Cannot declare a memory with DATA_WIDTH = {}, the limit is {}",
            .{ data_width, common.mem_max_data_width },
        );

    const addr_top = @as(u32, 1) << @intCast(addr_width);
    const stride = common.memStride(data_width);
    var slot: [common.mem_max_data_width / 8]u8 = undefined;

    try p.expect('{');
    while (!p.check('}')) {
        var addr = try p.parseHexNumber(u32);

        try p.expect(':');
        while (!p.check(';')) {
            // Phrased without naming the parameter: the bitstream spells this
            // shape `WIDTH` and the netlist `ADDR_WIDTH`, and only the bound
            // itself is common to both.
            if (addr >= addr_top)
                try p.err(
                    "Memory addresses only go up to 0x{X}, 0x{X} is outside that range",
                    .{ addr_top - 1, addr },
                );

            try p.parseMemSlot(slot[0..stride], data_width);
            if (sink.setSlot(addr, slot[0..stride]))
                try p.err(
                    "Memory conflict, address 0x{X} was already written before",
                    .{addr},
                );
            addr += 1;
        }
        try p.expect(';');
    }
    try p.expect('}');
}
