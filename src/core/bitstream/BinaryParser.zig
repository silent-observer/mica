const std = @import("std");

const common = @import("../common.zig");
const wire_codes = @import("../wire_codes.zig");
const Configuration = @import("../Configuration.zig");
const DeviceModel = @import("../DeviceModel.zig");
const BitReader = @import("BitReader.zig");

const BinaryParser = @This();

alloc: std.mem.Allocator,
r: std.Io.Reader,
config: ?Configuration,
errorText: ?[]const u8,
warnings: std.ArrayList([]const u8),

fn init(input: []const u8, alloc: std.mem.Allocator) BinaryParser {
    return .{
        .alloc = alloc,
        .r = .fixed(input),
        .config = null,
        .errorText = null,
        .warnings = .empty,
    };
}

fn err(p: *BinaryParser, comptime fmt: []const u8, args: anytype) !noreturn {
    p.errorText = std.fmt.allocPrint(
        p.alloc,
        "0x{X}: " ++ fmt,
        .{p.r.seek} ++ args,
    ) catch common.oom();
    return error.ParsingError;
}

fn warn(p: *BinaryParser, comptime fmt: []const u8, args: anytype) void {
    const text = std.fmt.allocPrint(
        p.alloc,
        "0x{X}: " ++ fmt,
        .{p.r.seek} ++ args,
    ) catch common.oom();
    p.warnings.append(p.alloc, text) catch common.oom();
}

fn parseHeader(p: *BinaryParser) error{ParsingError}!void {
    if (p.r.buffer.len < 20)
        try p.err("File must be at least 20 bytes", .{});
    const magic = p.r.take(4) catch unreachable;
    if (!std.mem.eql(u8, magic, "MICA"))
        try p.err("Malformed bitstream file", .{});

    const crc_val = p.r.takeInt(u32, .big) catch unreachable;
    var crc = std.hash.Crc32.init();
    crc.update(p.r.buffer[8..]);
    const actual_crc = crc.final();
    if (crc_val != actual_crc) {
        p.warn(
            "File specifies CRC {X:0>8}, but its actual CRC is {X:0>8}",
            .{ crc_val, actual_crc },
        );
    }

    const version = p.r.takeInt(u32, .big) catch unreachable;
    if (version != 1)
        try p.err("Unknown bitstream file version: {}", .{version});

    const device_str = p.r.take(4) catch unreachable;
    const model: DeviceModel = for (&DeviceModel.models) |m| {
        if (std.mem.eql(u8, device_str, m.model_id))
            break m;
    } else try p.err("Unknown device model: '{s}'", .{device_str});

    p.config = .init(model, p.alloc);
}

const Frame = struct {
    section: u8,
    offset: u32,
    r: BitReader,
};

fn parseFrame(p: *BinaryParser) error{ParsingError}!Frame {
    const section = p.r.takeByte() catch
        try p.err("Unexpected EOF when trying to read frame header", .{});
    const offset = p.r.takeInt(u32, .big) catch
        try p.err("Unexpected EOF when trying to read frame header", .{});
    const bit_len = p.r.takeInt(u32, .big) catch
        try p.err("Unexpected EOF when trying to read frame header", .{});
    if (bit_len > 0xFFFFFFF0)
        try p.err("The bit length is way to big ({}), the frame is malformed", .{bit_len});
    const byte_len = (bit_len + 7) / 8;
    const data = p.r.take(byte_len) catch
        try p.err(
            "Unexpected EOF when trying to read frame data ({} bits, {} bytes)",
            .{ bit_len, byte_len },
        );

    if (bit_len % 8 != 0) {
        // Check padding
        const last_byte = data[data.len - 1];
        const padding_len: u3 = @intCast(byte_len * 8 - bit_len);
        const padding = last_byte & ((@as(u8, 1) << padding_len) - 1);
        if (padding != 0)
            p.warn("Padding of the frame isn't 0, it's {b:0>8}", .{padding});
    }

    return .{
        .section = section,
        .offset = offset,
        .r = .init(data, bit_len),
    };
}

fn parseGlobal(p: *BinaryParser, f: *Frame) error{ParsingError}!void {
    std.debug.assert(f.section == 0);
    if (f.offset != 0)
        try p.err("Global frame must start at 0, not at {}", .{f.offset});
    if (f.r.bit_len > 16)
        try p.err("Global frame can have at most 16 bits, not {}", .{f.r.bit_len});

    // 8 bits
    for (&p.config.?.global.clk_enable) |*clk_en|
        clk_en.* = f.r.read(bool) orelse return;
    // 4 bits
    for (&p.config.?.global.rst_enable) |*rst_en|
        rst_en.* = f.r.read(bool) orelse return;
    // 4 bits
    p.config.?.global.reserved = f.r.read(u4) orelse return;
}

fn parseSwitches(p: *BinaryParser, f: *Frame) error{ParsingError}!void {
    std.debug.assert(f.section == 1);

    const total_bits = 144;
    if (f.offset % total_bits != 0)
        try p.err(
            "Switch frame must start at a multiple of {}, not at {}",
            .{ total_bits, f.offset },
        );

    const start_idx = f.offset / total_bits;
    if (start_idx >= p.config.?.switches.len)
        try p.err(
            "Switch frame overflow, this model only has {} switches, so max offset is 0x{X}",
            .{ p.config.?.model.switch_count, p.config.?.model.switch_count * total_bits - 1 },
        );

    for (p.config.?.switches[start_idx..]) |*sw| {
        // 36 x 4 = 144 bits in total
        for (&sw.sides.values) |*ps| {
            // 6 x 4 = 24 bits
            for (&ps.l1) |*code|
                code.* = f.r.read(u4) orelse return;
            // 2 x 4 = 8 bits
            for (&ps.l4) |*code|
                code.* = f.r.read(u4) orelse return;
            // 4 bits
            ps.l16 = f.r.read(u4) orelse return;
            // 36 bits in total
        }
    }

    if (f.r.readBit() != null)
        try p.err(
            "Switch frame overflow, this model only has {} switches, so max offset is 0x{X}",
            .{ p.config.?.model.switch_count, p.config.?.model.switch_count * total_bits - 1 },
        );
}

fn parseLogicTiles(p: *BinaryParser, f: *Frame) error{ParsingError}!void {
    std.debug.assert(f.section == 2);

    const total_bits = 103;
    if (f.offset % total_bits != 0)
        try p.err(
            "Logic frame must start at a multiple of {}, not at {}",
            .{ total_bits, f.offset },
        );
    const start_idx = f.offset / total_bits;
    if (start_idx >= p.config.?.logic.len)
        try p.err(
            "Logic frame overflow, this model only has {} logic tiles, so max offset is 0x{X}",
            .{
                p.config.?.model.tile_counts.get(.logic),
                p.config.?.model.tile_counts.get(.logic) * total_bits - 1,
            },
        );

    for (p.config.?.logic[start_idx..]) |*config| {
        // 39 bits
        config.carry = f.r.read(bool) orelse return;
        config.mem = f.r.read(bool) orelse return;
        config.mem_dual = f.r.read(bool) orelse return;
        config.cin_src = @enumFromInt(f.r.read(u2) orelse return);
        config.frac1 = f.r.read(bool) orelse return;
        config.frac2 = f.r.read(bool) orelse return;
        config.lut1 = f.r.read(u16) orelse return;
        config.lut2 = f.r.read(u16) orelse return;

        // 2 x 7 = 14 bits
        for (&config.regs) |*reg| {
            reg.reg = f.r.read(bool) orelse return;
            reg.clk = f.r.read(u3) orelse return;
            reg.rst_en = f.r.read(bool) orelse return;
            reg.rst = f.r.read(u2) orelse return;
        }

        // 5 x 10 = 50 bits
        for (&config.inputs.values) |*code|
            code.* = f.r.read(u5) orelse return;

        // 103 bits in total
    }

    if (f.r.readBit() != null)
        try p.err(
            "Logic frame overflow, this model only has {} logic tiles, so max offset is 0x{X}",
            .{
                p.config.?.model.tile_counts.get(.logic),
                p.config.?.model.tile_counts.get(.logic) * total_bits - 1,
            },
        );
}

fn parseBramTiles(p: *BinaryParser, f: *Frame) error{ParsingError}!void {
    std.debug.assert(f.section == 3);

    const total_bits = 176;
    if (f.offset % total_bits != 0)
        try p.err(
            "BRAM frame must start at a multiple of {}, not at {}",
            .{ total_bits, f.offset },
        );
    const start_idx = f.offset / total_bits;
    if (start_idx >= p.config.?.bram.len)
        try p.err(
            "BRAM frame overflow, this model only has {} BRAM tiles, so max offset is 0x{X}",
            .{
                p.config.?.model.tile_counts.get(.bram),
                p.config.?.model.tile_counts.get(.bram) * total_bits - 1,
            },
        );

    for (p.config.?.bram[start_idx..]) |*config| {
        // 6 bits
        config.width = f.r.read(u3) orelse return;
        config.clk = f.r.read(u3) orelse return;

        // 4 x 12 = 48 bits
        for (&config.a1) |*code|
            code.* = f.r.read(u4) orelse return;
        // 4 x 12 = 48 bits
        for (&config.a2) |*code|
            code.* = f.r.read(u4) orelse return;
        // 4 x 16 = 64 bits
        for (&config.di) |*code|
            code.* = f.r.read(u4) orelse return;
        // 5 bits
        config.we1 = f.r.read(u5) orelse return;
        // 5 bits
        config.we2 = f.r.read(u5) orelse return;

        // 176 bits in total
    }
    if (f.r.readBit() != null)
        try p.err(
            "BRAM frame overflow, this model only has {} BRAM tiles, so max offset is 0x{X}",
            .{
                p.config.?.model.tile_counts.get(.bram),
                p.config.?.model.tile_counts.get(.bram) * total_bits - 1,
            },
        );
}

fn parseDspTiles(p: *BinaryParser, f: *Frame) error{ParsingError}!void {
    std.debug.assert(f.section == 4);

    const total_bits = 184;
    if (f.offset % total_bits != 0)
        try p.err(
            "DSP frame must start at a multiple of {}, not at {}",
            .{ total_bits, f.offset },
        );
    const start_idx = f.offset / total_bits;
    if (start_idx >= p.config.?.dsp.len)
        try p.err(
            "DSP frame overflow, this model only has {} DSP tiles, so max offset is 0x{X}",
            .{
                p.config.?.model.tile_counts.get(.dsp),
                p.config.?.model.tile_counts.get(.dsp) * total_bits - 1,
            },
        );

    for (p.config.?.dsp[start_idx..]) |*config| {
        // 9 bits
        config.signed_a = f.r.read(bool) orelse return;
        config.signed_b = f.r.read(bool) orelse return;
        config.acc = f.r.read(bool) orelse return;
        config.clk = f.r.read(u3) orelse return;
        config.rst_en = f.r.read(bool) orelse return;
        config.rst = f.r.read(u2) orelse return;

        // 5 x 8 = 40 bits
        for (&config.a) |*code|
            code.* = f.r.read(u5) orelse return;
        // 5 x 8 = 40 bits
        for (&config.b) |*code|
            code.* = f.r.read(u5) orelse return;
        // 5 x 16 = 80 bits
        for (&config.c) |*code|
            code.* = f.r.read(u5) orelse return;
        // 5 bits
        config.md = f.r.read(u5) orelse return;
        // 5 bits
        config.ad = f.r.read(u5) orelse return;
        // 5 bits
        config.we = f.r.read(u5) orelse return;

        // 184 bits in total
    }
    if (f.r.readBit() != null)
        try p.err(
            "DSP frame overflow, this model only has {} DSP tiles, so max offset is 0x{X}",
            .{
                p.config.?.model.tile_counts.get(.dsp),
                p.config.?.model.tile_counts.get(.dsp) * total_bits - 1,
            },
        );
}

fn parseIoTiles(p: *BinaryParser, f: *Frame) error{ParsingError}!void {
    std.debug.assert(f.section == 5);

    const total_bits = 35;
    if (f.offset % total_bits != 0)
        try p.err(
            "IO frame must start at a multiple of {}, not at {}",
            .{ total_bits, f.offset },
        );
    const start_idx = f.offset / total_bits;
    if (start_idx >= p.config.?.io.len)
        try p.err(
            "IO frame overflow, this model only has {} IO tiles, so max offset is 0x{X}",
            .{
                p.config.?.model.tile_counts.get(.io),
                p.config.?.model.tile_counts.get(.io) * total_bits - 1,
            },
        );

    for (p.config.?.io[start_idx..]) |*config| {
        // 10 bits
        config.reg_i = f.r.read(bool) orelse return;
        config.reg_o = f.r.read(bool) orelse return;
        config.pullup = f.r.read(bool) orelse return;
        config.pulldown = f.r.read(bool) orelse return;
        config.clk = f.r.read(u3) orelse return;
        config.rst_en = f.r.read(bool) orelse return;
        config.rst = f.r.read(u2) orelse return;

        // 5 x 5 = 25 bits
        for (&config.inputs.values) |*code|
            code.* = f.r.read(u5) orelse return;

        // 35 bits in total
    }
    if (f.r.readBit() != null)
        try p.err(
            "IO frame overflow, this model only has {} IO tiles, so max offset is 0x{X}",
            .{
                p.config.?.model.tile_counts.get(.io),
                p.config.?.model.tile_counts.get(.io) * total_bits - 1,
            },
        );
}

fn parseBramData(p: *BinaryParser, f: *Frame) error{ParsingError}!void {
    std.debug.assert(f.section == 6);

    const total_bits = 4096;
    if (f.offset % total_bits != 0)
        try p.err(
            "BRAM data frame must start at a multiple of {}, not at {}",
            .{ total_bits, f.offset },
        );
    const start_idx = f.offset / total_bits;
    if (start_idx >= p.config.?.bram_data.len)
        try p.err(
            "BRAM data frame overflow, this model only has {} BRAM tiles, so max offset is 0x{X}",
            .{
                p.config.?.model.tile_counts.get(.bram),
                p.config.?.model.tile_counts.get(.bram) * total_bits - 1,
            },
        );

    for (p.config.?.bram_data[start_idx..]) |*config| {
        for (0..config.data.len) |i| {
            config.data[i] = f.r.read(u16) orelse return;
        }

        // 4096 bits in total
    }
    if (f.r.readBit() != null)
        try p.err(
            "BRAM data frame overflow, this model only has {} BRAM tiles, so max offset is 0x{X}",
            .{
                p.config.?.model.tile_counts.get(.bram),
                p.config.?.model.tile_counts.get(.bram) * total_bits - 1,
            },
        );
}

pub const Result = struct {
    c: ?Configuration,
    err: ?[]const u8,
    warnings: []const []const u8,

    pub fn deinit(r: Result, alloc: std.mem.Allocator) void {
        if (r.c) |c|
            c.deinit(alloc);
        if (r.err) |e|
            alloc.free(e);
        for (r.warnings) |warning|
            alloc.free(warning);
        alloc.free(r.warnings);
    }
};

pub fn parse(input: []const u8, alloc: std.mem.Allocator) Result {
    var p = BinaryParser.init(input, alloc);
    p.parseHeader() catch return Result{
        .c = null,
        .err = p.errorText,
        .warnings = p.warnings.toOwnedSlice(alloc) catch common.oom(),
    };

    const frame_count = p.r.takeInt(u32, .big) catch unreachable;
    var last_section: u8 = 0;
    var last_offset: u32 = 0;
    var last_end: u32 = 0;
    for (0..frame_count) |_| {
        var frame = p.parseFrame() catch return Result{
            .c = p.config.?,
            .err = p.errorText,
            .warnings = p.warnings.toOwnedSlice(alloc) catch common.oom(),
        };

        if (frame.r.bit_len == 0) {
            p.warn("Frame with SIZE = 0 is illegal", .{});
            continue;
        }

        if (frame.section < last_section or
            frame.section == last_section and frame.offset < last_offset)
            p.warn("Frames should be in increasing (SECTION, OFFSET) order!", .{})
        else if (frame.section == last_section and frame.offset < last_end)
            p.warn("Frames should not overlap!", .{});

        last_section = frame.section;
        last_offset = frame.offset;
        last_end = frame.offset +| frame.r.bit_len;

        (switch (frame.section) {
            0 => p.parseGlobal(&frame),
            1 => p.parseSwitches(&frame),
            2 => p.parseLogicTiles(&frame),
            3 => p.parseBramTiles(&frame),
            4 => p.parseDspTiles(&frame),
            5 => p.parseIoTiles(&frame),
            6 => p.parseBramData(&frame),
            else => {
                // Skip unknown sections
                p.warn("Unknown section {}", .{frame.section});
            },
        }) catch return Result{
            .c = p.config.?,
            .err = p.errorText,
            .warnings = p.warnings.toOwnedSlice(alloc) catch common.oom(),
        };
    }

    return Result{
        .c = p.config.?,
        .err = p.errorText,
        .warnings = p.warnings.toOwnedSlice(alloc) catch common.oom(),
    };
}
