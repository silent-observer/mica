//! `Configuration` to `.bit` binary, as `(section, bit offset, bit size, data)`
//! frames. An all-zero tile is skipped by ending the current frame and
//! advancing `frame_offset` past it, which is what keeps sparse bitstreams
//! small - the gap in the offsets is the tile.

const std = @import("std");

const common = @import("../common.zig");
const wire_codes = @import("../wire_codes.zig");
const Configuration = @import("../Configuration.zig");
const DeviceModel = @import("../DeviceModel.zig");
const BitWriter = @import("BitWriter.zig");

const BinaryEmitter = @This();

config: *const Configuration,
w: std.Io.Writer.Allocating,

section: u8,
frame_offset: u32,
frame_w: BitWriter,
frame_count: u32,

fn init(config: *const Configuration, alloc: std.mem.Allocator) BinaryEmitter {
    return .{
        .w = .init(alloc),
        .frame_w = .init(alloc),
        .config = config,
        .frame_count = 0,
        .section = 0,
        .frame_offset = 0,
    };
}

fn finish(e: *BinaryEmitter) []u8 {
    e.frame_w.deinit();
    return e.w.toOwnedSlice() catch common.oom();
}

fn emitHeader(e: *BinaryEmitter) !void {
    const w = &e.w.writer;
    try w.writeAll("MICA");
    try w.writeInt(u32, 0, .big); // CRC stub
    try w.writeInt(u32, 1, .big); // Version
    try w.writeAll(e.config.model.model_id);
    try w.writeInt(u32, 0, .big); // Frame count
}

fn endFrame(e: *BinaryEmitter) !void {
    const bit_len = e.frame_w.bitLen();
    if (bit_len == 0) return;

    const w = &e.w.writer;
    try w.writeByte(e.section); // Section
    try w.writeInt(u32, e.frame_offset, .big); // Frame offset
    try w.writeInt(u32, bit_len, .big); // Frame size

    const data = e.frame_w.finish();
    try w.writeAll(data);

    e.frame_w.reset();
    e.frame_offset += bit_len;
    e.frame_count += 1;
}

fn emitGlobal(e: *BinaryEmitter) !void {
    e.section = 0; // Global section
    e.frame_offset = 0;
    if (std.meta.eql(e.config.global, std.mem.zeroes(Configuration.Global)))
        return;

    // 8 bits
    for (e.config.global.clk_enable) |clk_en|
        e.frame_w.write(bool, clk_en);
    // 4 bits
    for (e.config.global.rst_enable) |rst_en|
        e.frame_w.write(bool, rst_en);
    // 4 bits
    e.frame_w.write(u4, e.config.global.reserved);

    try e.endFrame();
}

fn emitSwitches(e: *BinaryEmitter) !void {
    e.section = 1; // Switch section
    e.frame_offset = 0;
    const total_bits = 144;
    for (e.config.switches) |sw| {
        if (std.meta.eql(sw, std.mem.zeroes(Configuration.Switch))) {
            try e.endFrame();
            e.frame_offset += total_bits;
            continue;
        }

        // 36 x 4 = 144 bits in total
        for (&sw.sides.values) |ps| {
            // 6 x 4 = 24 bits
            for (&ps.l1) |code|
                e.frame_w.write(u4, code);
            // 2 x 4 = 8 bits
            for (&ps.l4) |code|
                e.frame_w.write(u4, code);
            // 4 bits
            e.frame_w.write(u4, ps.l16);
            // 36 bits in total
        }
    }

    try e.endFrame();
}

fn emitLogicTiles(e: *BinaryEmitter) !void {
    e.section = 2; // Logic section
    e.frame_offset = 0;
    const total_bits = 103;
    for (e.config.logic) |config| {
        if (std.meta.eql(config, std.mem.zeroes(Configuration.Logic))) {
            try e.endFrame();
            e.frame_offset += total_bits;
            continue;
        }

        // 39 bits
        e.frame_w.write(bool, config.carry);
        e.frame_w.write(bool, config.mem);
        e.frame_w.write(bool, config.mem_dual);
        e.frame_w.write(u2, @intFromEnum(config.cin_src));
        e.frame_w.write(bool, config.frac1);
        e.frame_w.write(bool, config.frac2);
        e.frame_w.write(u16, config.lut1);
        e.frame_w.write(u16, config.lut2);

        // 2 x 7 = 14 bits
        for (config.regs) |reg| {
            e.frame_w.write(bool, reg.reg);
            e.frame_w.write(u3, reg.clk);
            e.frame_w.write(bool, reg.rst_en);
            e.frame_w.write(u2, reg.rst);
        }

        // 5 x 10 = 50 bits
        for (config.inputs.values) |code|
            e.frame_w.write(u5, code);

        // 103 bits in total
    }
    try e.endFrame();
}

fn emitBramTiles(e: *BinaryEmitter) !void {
    e.section = 3; // BRAM section
    e.frame_offset = 0;
    const total_bits = 176;
    for (e.config.bram) |config| {
        if (std.meta.eql(config, std.mem.zeroes(Configuration.Bram))) {
            try e.endFrame();
            e.frame_offset += total_bits;
            continue;
        }

        // 6 bits
        e.frame_w.write(u3, @intFromEnum(config.width));
        e.frame_w.write(u3, config.clk);

        // 4 x 12 = 48 bits
        for (config.a1) |code|
            e.frame_w.write(u4, code);
        // 4 x 12 = 48 bits
        for (config.a2) |code|
            e.frame_w.write(u4, code);
        // 4 x 16 = 64 bits
        for (config.di) |code|
            e.frame_w.write(u4, code);
        // 5 bits
        e.frame_w.write(u5, config.we1);
        // 5 bits
        e.frame_w.write(u5, config.we2);

        // 176 bits in total
    }
    try e.endFrame();
}

fn emitDspTiles(e: *BinaryEmitter) !void {
    e.section = 4; // DSP section
    e.frame_offset = 0;
    const total_bits = 184;
    for (e.config.dsp) |config| {
        if (std.meta.eql(config, std.mem.zeroes(Configuration.Dsp))) {
            try e.endFrame();
            e.frame_offset += total_bits;
            continue;
        }

        // 9 bits
        e.frame_w.write(bool, config.signed_a);
        e.frame_w.write(bool, config.signed_b);
        e.frame_w.write(bool, config.acc);
        e.frame_w.write(u3, config.clk);
        e.frame_w.write(bool, config.rst_en);
        e.frame_w.write(u2, config.rst);

        // 5 x 8 = 40 bits
        for (config.a) |code|
            e.frame_w.write(u5, code);
        // 5 x 8 = 40 bits
        for (config.b) |code|
            e.frame_w.write(u5, code);
        // 5 x 16 = 80 bits
        for (config.c) |code|
            e.frame_w.write(u5, code);
        // 5 bits
        e.frame_w.write(u5, config.md);
        // 5 bits
        e.frame_w.write(u5, config.ad);
        // 5 bits
        e.frame_w.write(u5, config.we);

        // 184 bits in total
    }
    try e.endFrame();
}

fn emitIoTiles(e: *BinaryEmitter) !void {
    e.section = 5; // IO section
    e.frame_offset = 0;
    const total_bits = 35;
    for (e.config.io) |config| {
        if (std.meta.eql(config, std.mem.zeroes(Configuration.Io))) {
            try e.endFrame();
            e.frame_offset += total_bits;
            continue;
        }

        // 10 bits
        e.frame_w.write(bool, config.reg_i);
        e.frame_w.write(bool, config.reg_o);
        e.frame_w.write(bool, config.pullup);
        e.frame_w.write(bool, config.pulldown);
        e.frame_w.write(u3, config.clk);
        e.frame_w.write(bool, config.rst_en);
        e.frame_w.write(u2, config.rst);

        // 5 x 5 = 25 bits
        for (config.inputs.values) |code|
            e.frame_w.write(u5, code);

        // 35 bits in total
    }
    try e.endFrame();
}

fn emitBramData(e: *BinaryEmitter) !void {
    e.section = 6; // BRAM data section
    e.frame_offset = 0;
    const total_bits = 4096;
    for (e.config.bram_data) |config| {
        if (std.mem.allEqual(u16, &config.data, 0)) {
            try e.endFrame();
            e.frame_offset += total_bits;
            continue;
        }

        for (0..config.data.len) |i| {
            e.frame_w.write(u16, config.data[i]);
        }

        // 4096 bits in total
    }
    try e.endFrame();
}

pub fn emit(config: *const Configuration, alloc: std.mem.Allocator) []const u8 {
    var e = BinaryEmitter.init(config, alloc);
    e.emitHeader() catch common.oom();
    e.emitGlobal() catch common.oom();
    e.emitSwitches() catch common.oom();
    e.emitLogicTiles() catch common.oom();
    e.emitBramTiles() catch common.oom();
    e.emitDspTiles() catch common.oom();
    e.emitIoTiles() catch common.oom();
    e.emitBramData() catch common.oom();
    const file = e.finish();

    std.mem.writeInt(u32, file[16..20], e.frame_count, .big);

    var crc = std.hash.Crc32.init();
    crc.update(file[8..]);
    const crc_val = crc.final();
    std.mem.writeInt(u32, file[4..8], crc_val, .big);

    return file;
}
