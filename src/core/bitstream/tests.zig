//! Tests for the four converters in this directory.
//!
//! Golden files come first: the examples converted both ways, compared byte for
//! byte. `examples/*.mica` are kept in the canonical form the emitter produces,
//! so each one is both the input and the expected output, and `examples/*.bit`
//! is the expected binary. build.zig hands them in as imports, since @embedFile
//! cannot see outside the module root. Then the round-trip properties over
//! random configurations, then the malformed input each parser has to survive.

const std = @import("std");

const Configuration = @import("../Configuration.zig");
const DeviceModel = @import("../DeviceModel.zig");
const TextParser = @import("TextParser.zig");
const TextEmitter = @import("TextEmitter.zig");
const BinaryParser = @import("BinaryParser.zig");
const BinaryEmitter = @import("BinaryEmitter.zig");

const alloc = std.testing.allocator;

// -------------------------------------------------------------------------
// Helpers
// -------------------------------------------------------------------------

/// Parses text that is expected to be valid. The caller owns the result.
fn parseText(text: []const u8) !TextParser.Result {
    const r = TextParser.parse(text, alloc);
    if (r.err) |e| {
        std.debug.print("unexpected text parse error: {s}\n", .{e});
        r.deinit(alloc);
        return error.TextParseFailed;
    }
    return r;
}

/// Parses a bitstream that is expected to be valid *and* unremarkable: a
/// warning fails the test, since a well-formed file must not produce one.
fn parseBinary(bytes: []const u8) !BinaryParser.Result {
    const r = BinaryParser.parse(bytes, alloc);
    if (r.err) |e| {
        std.debug.print("unexpected binary parse error: {s}\n", .{e});
        r.deinit(alloc);
        return error.BinaryParseFailed;
    }
    if (r.warnings.len != 0) {
        for (r.warnings) |w| std.debug.print("unexpected warning: {s}\n", .{w});
        r.deinit(alloc);
        return error.BinaryParseWarned;
    }
    return r;
}

/// Emits text that is expected to describe a sane configuration.
fn emitText(c: *const Configuration) !TextEmitter.Result {
    const t = TextEmitter.emit(c, alloc);
    if (t.warnings.len != 0) {
        for (t.warnings) |w| std.debug.print("unexpected warning: {s}\n", .{w});
        t.deinit(alloc);
        return error.TextEmitWarned;
    }
    return t;
}

fn expectEqualConfigs(a: *const Configuration, b: *const Configuration) !void {
    try std.testing.expectEqualStrings(a.model.model_id, b.model.model_id);
    try std.testing.expectEqual(a.global, b.global);
    inline for (.{ "switches", "logic", "bram", "bram_data", "dsp", "io" }) |name| {
        for (@field(a, name), @field(b, name), 0..) |x, y, i| {
            if (!std.meta.eql(x, y)) {
                std.debug.print(
                    "configurations differ at {s}[{}]:\n  {any}\nvs\n  {any}\n",
                    .{ name, i, x, y },
                );
                return error.TestExpectedEqual;
            }
        }
    }
}

/// Per-tile size of every section, in bits, and how many of them a device has.
/// A frame must start on a multiple of the first and stay within the second.
const section_bits = [7]u32{ 16, 144, 103, 176, 184, 35, 4096 };

fn sectionTiles(model: *const DeviceModel, section: u8) u32 {
    return switch (section) {
        0 => 1,
        1 => model.switch_count,
        2 => model.tile_counts.get(.logic),
        3, 6 => model.tile_counts.get(.bram),
        4 => model.tile_counts.get(.dsp),
        5 => model.tile_counts.get(.io),
        else => unreachable,
    };
}

const Frame = struct { section: u8, offset: u32, size: u32 };

/// Walks the container structure and checks everything §"Binary format"
/// requires of an emitted file: correct magic, version, CRC and frame count,
/// and frames that are non-empty, in a known section, tile-aligned, sorted,
/// non-overlapping, inside their section and zero-padded. When `expected` is
/// given, the frame table has to match it as well.
fn checkBitstream(
    model: *const DeviceModel,
    bytes: []const u8,
    expected: ?[]const Frame,
) !void {
    try std.testing.expectEqualStrings("MICA", bytes[0..4]);
    var crc = std.hash.Crc32.init();
    crc.update(bytes[8..]);
    try std.testing.expectEqual(crc.final(), std.mem.readInt(u32, bytes[4..8], .big));
    try std.testing.expectEqual(1, std.mem.readInt(u32, bytes[8..12], .big));
    try std.testing.expectEqualStrings(model.model_id, bytes[12..16]);

    const count = std.mem.readInt(u32, bytes[16..20], .big);
    if (expected) |e| try std.testing.expectEqual(e.len, count);

    var pos: usize = 20;
    var last = Frame{ .section = 0, .offset = 0, .size = 0 };
    for (0..count) |i| {
        try std.testing.expect(pos + 9 <= bytes.len);
        const f = Frame{
            .section = bytes[pos],
            .offset = std.mem.readInt(u32, bytes[pos + 1 ..][0..4], .big),
            .size = std.mem.readInt(u32, bytes[pos + 5 ..][0..4], .big),
        };
        pos += 9;

        if (expected) |e| try std.testing.expectEqual(e[i], f);
        try std.testing.expect(f.section <= 6);
        try std.testing.expect(f.size != 0);
        try std.testing.expectEqual(0, f.offset % section_bits[f.section]);
        try std.testing.expect(f.offset + f.size <=
            sectionTiles(model, f.section) * section_bits[f.section]);
        if (i != 0) {
            try std.testing.expect(f.section >= last.section);
            if (f.section == last.section)
                try std.testing.expect(f.offset >= last.offset + last.size);
        }
        last = f;

        const byte_len = (f.size + 7) / 8;
        try std.testing.expect(pos + byte_len <= bytes.len);
        if (f.size % 8 != 0) {
            const padding: u3 = @intCast(byte_len * 8 - f.size);
            try std.testing.expectEqual(0, bytes[pos + byte_len - 1] &
                ((@as(u8, 1) << padding) - 1));
        }
        pos += byte_len;
    }
    try std.testing.expectEqual(bytes.len, pos);
}

// -------------------------------------------------------------------------
// Golden files
// -------------------------------------------------------------------------

/// §"Worked examples", example 1: pin 2 inverted onto pin 3 through logic tile
/// (1,2).
const inverter_text = @embedFile("inverter_mica");

test "golden: the inverter example, both directions" {
    const r = try parseText(inverter_text);
    defer r.deinit(alloc);

    // Indices: switchbox (0,2) is 0 + 2*49 = 98, logic (1,2) is 0 + 1*48 = 48,
    // and the north IO tiles of columns 2 and 3 are 48 + 1*2 = 50 and
    // 48 + 2*2 = 52, so the frames land at 14112, 4944, 1750 and 1820 bits.
    const bin = BinaryEmitter.emit(&r.c.?, alloc);
    defer alloc.free(bin);
    try checkBitstream(&r.c.?.model, bin, &.{
        .{ .section = 1, .offset = 98 * 144, .size = 144 },
        .{ .section = 2, .offset = 48 * 103, .size = 103 },
        .{ .section = 5, .offset = 50 * 35, .size = 35 },
        .{ .section = 5, .offset = 52 * 35, .size = 35 },
    });
    try std.testing.expectEqualSlices(u8, @embedFile("inverter_bit"), bin);

    const back = try parseBinary(bin);
    defer back.deinit(alloc);
    try expectEqualConfigs(&r.c.?, &back.c.?);

    const t = try emitText(&back.c.?);
    defer t.deinit(alloc);
    try std.testing.expectEqualStrings(inverter_text, t.text);

    // §"Textual format": zero-valued commands are skipped, except that a wire
    // something else reads is named anyway. W.L1[0] = NW.I is code 0 and
    // appears only because logic (1,2) reads that segment on A1 - drop the
    // reader and the line goes with it.
    var c = back.c.?;
    c.getLogic(.{ .row = 1, .col = 2 }).inputs.set(.a1, 0);
    const without = try emitText(&c);
    defer without.deinit(alloc);
    try std.testing.expect(std.mem.containsAtLeast(u8, t.text, 1, "W.L1[0] = NW.I;"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, without.text, 1, "W.L1[0]"));
    try std.testing.expect(std.mem.containsAtLeast(u8, without.text, 1, "E.L1[0] = SW.O1A;"));
}

test "golden: the toggle example round-trips through both formats" {
    // §"Worked examples", example 2: the inverter fed from its own registered
    // output, which adds the global block, a register and a clock network.
    const text = @embedFile("toggle_mica");
    const r = try parseText(text);
    defer r.deinit(alloc);

    const bin = BinaryEmitter.emit(&r.c.?, alloc);
    defer alloc.free(bin);
    try checkBitstream(&r.c.?.model, bin, &.{
        .{ .section = 0, .offset = 0, .size = 16 },
        .{ .section = 1, .offset = 98 * 144, .size = 144 },
        .{ .section = 2, .offset = 48 * 103, .size = 103 },
        .{ .section = 5, .offset = 52 * 35, .size = 35 },
    });
    try std.testing.expectEqualSlices(u8, @embedFile("toggle_bit"), bin);

    const back = try parseBinary(bin);
    defer back.deinit(alloc);
    const t = try emitText(&back.c.?);
    defer t.deinit(alloc);
    try std.testing.expectEqualStrings(text, t.text);
}

test "golden: BRAM, DSP and the remaining value kinds" {
    // Neither worked example touches BRAM, DSP or most `ValueKind`s, so this
    // fixture exists to cover them. Its two switch blocks are there because
    // the BRAM inputs read those segments: all three sinks are code 0, named
    // only because of the exception in §"Textual format".
    const text = @embedFile("bram_dsp_mica");
    const r = try parseText(text);
    defer r.deinit(alloc);

    // logic (1,8) is 0 + 7*48 = 336; dsp (5,18) is (5-1)/4 = 1 in the first
    // DSP column; bram (25,38) is (25-1)/4 = 6 plus 2*12 for the third BRAM
    // column, so 30; io (0,4) is 48 + (4-1)*2 = 54.
    const bin = BinaryEmitter.emit(&r.c.?, alloc);
    defer alloc.free(bin);
    try checkBitstream(&r.c.?.model, bin, &.{
        .{ .section = 0, .offset = 0, .size = 16 },
        .{ .section = 2, .offset = 336 * 103, .size = 103 },
        .{ .section = 3, .offset = 30 * 176, .size = 176 },
        .{ .section = 4, .offset = 1 * 184, .size = 184 },
        .{ .section = 5, .offset = 54 * 35, .size = 35 },
        .{ .section = 6, .offset = 30 * 4096, .size = 4096 },
    });

    const back = try parseBinary(bin);
    defer back.deinit(alloc);
    try expectEqualConfigs(&r.c.?, &back.c.?);

    const t = try emitText(&back.c.?);
    defer t.deinit(alloc);
    try std.testing.expectEqualStrings(text, t.text);
}

test "golden: values that only the emitter can decide" {
    // WIDTH has to precede data {} (§"Textual format" and the grammar), so a
    // width of 1 - which encodes as 0 - must not be skipped as a zero value.
    var c = Configuration.init(.mica1s, alloc);
    defer c.deinit(alloc);
    c.getBramData(.{ .row = 1, .col = 9 }).set(u1, 3, 1);

    const t = try emitText(&c);
    defer t.deinit(alloc);
    const width = std.mem.indexOf(u8, t.text, "WIDTH = 1;") orelse {
        std.debug.print("WIDTH is missing from:\n{s}", .{t.text});
        return error.TestExpectedWidth;
    };
    try std.testing.expect(width < std.mem.indexOf(u8, t.text, "data {").?);

    const r = try parseText(t.text);
    defer r.deinit(alloc);
    try expectEqualConfigs(&c, &r.c.?);

    // A code that names no wire here degrades to `code <N>` with an error
    // (§"Bitstream format"). Code 10 on A1 is N[R].L4[2], whose segment would
    // have to start three switchboxes west of the grid.
    var d = Configuration.init(.mica1s, alloc);
    defer d.deinit(alloc);
    d.getLogic(.{ .row = 1, .col = 1 }).inputs.set(.a1, 10);

    const t2 = TextEmitter.emit(&d, alloc);
    defer t2.deinit(alloc);
    try std.testing.expect(std.mem.containsAtLeast(u8, t2.text, 1, "in A1 = code 10;"));
    try std.testing.expectEqual(1, t2.warnings.len);
    try std.testing.expectEqualStrings(
        "logic (1,1) in A1: code 10 names a wire that does not exist here",
        t2.warnings[0],
    );

    const r2 = try parseText(t2.text);
    defer r2.deinit(alloc);
    try expectEqualConfigs(&d, &r2.c.?);
}

// -------------------------------------------------------------------------
// Round-trip properties
// -------------------------------------------------------------------------

/// Fills `p` with random bits. Every field of a `Configuration` is a bool, an
/// unsigned int, an exhaustive enum, an array or a struct of those, which is
/// exactly the shape the binary format packs.
fn randomize(comptime T: type, rand: std.Random, p: *T) void {
    switch (@typeInfo(T)) {
        .bool => p.* = rand.boolean(),
        .int => p.* = rand.int(T),
        .@"enum" => {
            const values = std.enums.values(T);
            p.* = values[rand.uintLessThan(usize, values.len)];
        },
        .array => |a| for (p) |*item| randomize(a.child, rand, item),
        .@"struct" => |s| inline for (s.fields) |f|
            randomize(f.type, rand, &@field(p.*, f.name)),
        else => @compileError("cannot randomize " ++ @typeName(T)),
    }
}

/// A configuration in which each tile is, with probability `density`, filled
/// with random codes and left zero otherwise. Low densities are the
/// interesting ones: they are what makes the emitter split and skip frames.
fn randomConfig(model: DeviceModel, rand: std.Random, density: f32) Configuration {
    var c = Configuration.init(model, alloc);
    if (rand.float(f32) < density)
        randomize(Configuration.Global, rand, &c.global);
    inline for (.{ "switches", "logic", "bram", "bram_data", "dsp", "io" }) |name| {
        for (@field(c, name)) |*tile| {
            if (rand.float(f32) < density)
                randomize(@TypeOf(tile.*), rand, tile);
        }
    }
    return c;
}

test "property: a configuration survives the binary round trip" {
    // Sparse through fully dense on the small device, plus a sparse case on
    // each of the larger two, so the index formulas see all three layouts.
    for ([_]struct { model: DeviceModel, density: f32 }{
        .{ .model = .mica1s, .density = 0.01 },
        .{ .model = .mica1s, .density = 0.3 },
        .{ .model = .mica1s, .density = 1.0 },
        .{ .model = .mica1m, .density = 0.01 },
        .{ .model = .mica1l, .density = 0.002 },
    }, 1..) |case, seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        var c = randomConfig(case.model, prng.random(), case.density);
        defer c.deinit(alloc);

        const bin = BinaryEmitter.emit(&c, alloc);
        defer alloc.free(bin);
        try checkBitstream(&case.model, bin, null);

        const r = try parseBinary(bin);
        defer r.deinit(alloc);
        try expectEqualConfigs(&c, &r.c.?);

        // Emission is a function of the configuration alone, so re-emitting
        // what we just parsed must reproduce the file byte for byte.
        const again = BinaryEmitter.emit(&r.c.?, alloc);
        defer alloc.free(again);
        try std.testing.expectEqualSlices(u8, bin, again);

        // Skipping zero-filled tiles is the point of the frame design: a
        // one-percent configuration must not cost anything like the 962720
        // bits of a full Mica-1/S image.
        if (case.density <= 0.01) {
            var total: u32 = 0;
            for (0..7) |s| total += sectionTiles(&case.model, @intCast(s)) * section_bits[s];
            try std.testing.expect(bin.len * 8 < total / 10);
        }
    }
}

test "property: a configuration survives the text round trip" {
    // Text is far bulkier than the packed form, so this stays on the small
    // device at densities where the output is a few hundred kilobytes.
    for ([_]f32{ 0.005, 0.05 }, 11..) |density, seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        var c = randomConfig(.mica1s, prng.random(), density);
        defer c.deinit(alloc);

        // Random codes name plenty of wires that run off the grid, so warnings
        // are expected here; the text still has to parse back exactly.
        const t = TextEmitter.emit(&c, alloc);
        defer t.deinit(alloc);

        const r = try parseText(t.text);
        defer r.deinit(alloc);
        try expectEqualConfigs(&c, &r.c.?);

        // §"Textual format": the representation is unique, so emitting the
        // parsed configuration has to give back the same text.
        const again = TextEmitter.emit(&r.c.?, alloc);
        defer again.deinit(alloc);
        try std.testing.expectEqualStrings(t.text, again.text);
    }
}

// -------------------------------------------------------------------------
// Malformed input
// -------------------------------------------------------------------------

const RawFrame = struct {
    section: u8,
    offset: u32,
    /// The SIZE field. Data is `ALIGN(8, size)/8` bytes, zeros when null.
    size: u32,
    data: ?[]const u8 = null,
};

const BuildOptions = struct {
    magic: []const u8 = "MICA",
    version: u32 = 1,
    model_id: []const u8 = "M1/S",
    /// Frame count to write, when it should disagree with the frames given.
    frame_count: ?u32 = null,
    valid_crc: bool = true,
};

/// Assembles a bitstream from an explicit frame table, so tests can build
/// files an emitter would never produce.
fn buildBitstream(frames: []const RawFrame, options: BuildOptions) []u8 {
    var w: std.Io.Writer.Allocating = .init(alloc);
    defer w.deinit();
    const out = &w.writer;

    out.writeAll(options.magic) catch @panic("OOM");
    out.writeInt(u32, 0, .big) catch @panic("OOM"); // CRC, patched below
    out.writeInt(u32, options.version, .big) catch @panic("OOM");
    out.writeAll(options.model_id) catch @panic("OOM");
    out.writeInt(u32, options.frame_count orelse @intCast(frames.len), .big) catch @panic("OOM");

    for (frames) |f| {
        out.writeByte(f.section) catch @panic("OOM");
        out.writeInt(u32, f.offset, .big) catch @panic("OOM");
        out.writeInt(u32, f.size, .big) catch @panic("OOM");
        if (f.data) |data|
            out.writeAll(data) catch @panic("OOM")
        else
            out.splatByteAll(0, (f.size + 7) / 8) catch @panic("OOM");
    }

    const bytes = w.toOwnedSlice() catch @panic("OOM");
    var crc = std.hash.Crc32.init();
    crc.update(bytes[8..]);
    std.mem.writeInt(u32, bytes[4..8], crc.final() +% @intFromBool(!options.valid_crc), .big);
    return bytes;
}

const Case = struct {
    frames: []const RawFrame = &.{},
    options: BuildOptions = .{},
    /// Raw file contents, for what a frame table cannot express.
    raw: ?[]const u8 = null,
    /// Substring of the message the parser is expected to produce.
    expect: []const u8,
};

const io_tiles = DeviceModel.mica1s.tile_counts.get(.io);

test "binary: input that must be rejected" {
    // §"Binary format": a bad header, a frame that runs off the end of the
    // file, one that starts mid-tile, or one that leaves its section.
    for ([_]Case{
        .{ .raw = "", .expect = "0x0: File must be at least 20 bytes" },
        .{ .options = .{ .magic = "MIKA" }, .expect = "0x4: Malformed bitstream file" },
        .{ .options = .{ .version = 2 }, .expect = "0xC: Unknown bitstream file version: 2" },
        .{ .options = .{ .model_id = "M9/X" }, .expect = "0x10: Unknown device model: 'M9/X'" },
        .{
            .options = .{ .frame_count = 1 },
            .expect = "0x14: Unexpected EOF when trying to read frame header",
        },
        .{
            .frames = &.{.{ .section = 2, .offset = 0, .size = 103, .data = "\x00" }},
            .expect = "Unexpected EOF when trying to read frame data (103 bits, 13 bytes)",
        },
        .{
            .frames = &.{.{ .section = 2, .offset = 50, .size = 103 }},
            .expect = "Logic frame must start at a multiple of 103, not at 50",
        },
        .{
            .frames = &.{.{ .section = 0, .offset = 16, .size = 16 }},
            .expect = "Global frame must start at 0, not at 16",
        },
        .{ // Starting past the last tile of the section.
            .frames = &.{.{ .section = 5, .offset = io_tiles * 35, .size = 35 }},
            .expect = "IO frame overflow",
        },
        .{ // Starting inside the section but running off its end.
            .frames = &.{.{ .section = 5, .offset = (io_tiles - 1) * 35, .size = 70 }},
            .expect = "IO frame overflow",
        },
    }) |case| try expectMessage(case, .fatal);
}

test "binary: malformations that are only warnings" {
    // §"Binary format": an invalid CRC, SIZE = 0, SECTION > 6 and non-zero
    // padding are all illegal but still convertible to text, as are frames out
    // of order or overlapping.
    for ([_]Case{
        .{ .options = .{ .valid_crc = false }, .expect = "0x8: File specifies CRC " },
        .{
            .frames = &.{.{ .section = 0, .offset = 0, .size = 0 }},
            .expect = "Frame with SIZE = 0 is illegal",
        },
        .{
            .frames = &.{.{ .section = 7, .offset = 0, .size = 8 }},
            .expect = "Unknown section 7",
        },
        .{
            .frames = &.{.{ .section = 5, .offset = 0, .size = 35, .data = "\x00\x00\x00\x00\x1f" }},
            .expect = "Padding of the frame isn't 0, it's 00011111",
        },
        .{
            .frames = &.{
                .{ .section = 2, .offset = 103, .size = 103 },
                .{ .section = 2, .offset = 0, .size = 103 },
            },
            .expect = "Frames should be in increasing (SECTION, OFFSET) order!",
        },
        .{
            .frames = &.{
                .{ .section = 1, .offset = 0, .size = 288 },
                .{ .section = 1, .offset = 144, .size = 144 },
            },
            .expect = "Frames should not overlap!",
        },
    }) |case| try expectMessage(case, .warning);
}

fn expectMessage(case: Case, kind: enum { fatal, warning }) !void {
    const bytes = case.raw orelse buildBitstream(case.frames, case.options);
    defer if (case.raw == null) alloc.free(bytes);

    const r = BinaryParser.parse(bytes, alloc);
    defer r.deinit(alloc);

    switch (kind) {
        .fatal => {
            const e = r.err orelse {
                std.debug.print("expected a failure containing '{s}'\n", .{case.expect});
                return error.TestExpectedError;
            };
            if (std.mem.containsAtLeast(u8, e, 1, case.expect)) return;
            std.debug.print("expected '{s}', got error '{s}'\n", .{ case.expect, e });
        },
        .warning => {
            for (r.warnings) |w| {
                if (std.mem.containsAtLeast(u8, w, 1, case.expect)) return;
            }
            std.debug.print("expected a warning containing '{s}', got:\n", .{case.expect});
            for (r.warnings) |w| std.debug.print("  {s}\n", .{w});
            if (r.err) |e| std.debug.print("  (and error {s})\n", .{e});
        },
    }
    return error.TestUnexpectedMessage;
}

test "binary: a frame may cover several tiles, or stop inside one" {
    // §"Binary format": a frame need not correspond to specific tiles, as long
    // as it starts on one. Three IO tiles in a single 105-bit frame, the
    // packing §"Worked examples" uses for the inverter.
    const bytes = buildBitstream(&.{.{
        .section = 5,
        .offset = 50 * 35,
        .size = 105,
        .data = &(.{0x10} ++ .{0} ** 9 ++ .{ 0x28, 0x40, 0, 0 }),
    }}, .{});
    defer alloc.free(bytes);

    const r = try parseBinary(bytes);
    defer r.deinit(alloc);
    try std.testing.expect(r.c.?.getIo(.{ .row = 0, .col = 2 }).pulldown);
    try std.testing.expectEqual(
        std.mem.zeroes(Configuration.Io),
        r.c.?.getIo(.{ .row = 49, .col = 2 }).*,
    );
    try std.testing.expectEqual(5, r.c.?.getIo(.{ .row = 0, .col = 3 }).inputs.get(.o));

    // A frame that stops mid-tile leaves the rest of that tile zero.
    const short = buildBitstream(&.{.{
        .section = 5,
        .offset = 50 * 35,
        .size = 40,
        .data = &.{ 0x10, 0, 0, 0, 0x10 },
    }}, .{});
    defer alloc.free(short);

    const r2 = try parseBinary(short);
    defer r2.deinit(alloc);
    try std.testing.expect(r2.c.?.getIo(.{ .row = 0, .col = 2 }).pulldown);
    try std.testing.expect(r2.c.?.getIo(.{ .row = 49, .col = 2 }).reg_i);
}

test "text: errors are reported with a line and column" {
    for ([_]struct { text: []const u8, err: []const u8 }{
        .{ .text = "", .err = "1:0: Expected a word, but got end of file" },
        .{ .text = "format 2;\n", .err = "1:8: Expected 'format 1', but got 'format 2'" },
        .{
            .text = "format 1;\ndevice \"M1/S\";\nnonsense {}\n",
            .err = "3:10: Unknown block 'nonsense'",
        },
        .{
            .text = "format 1;\ndevice \"M1/S\";\nlogic (1, 9) {}\n",
            .err = "3:14: Tile (1, 9) is bram, not logic",
        },
        .{
            .text = "format 1;\ndevice \"M1/S\";\nlogic (1, 1) { in ZZ = 1; }\n",
            .err = "3:22: No such input 'ZZ' for logic tile",
        },
        .{
            .text = "format 1;\ndevice \"M1/S\";\nlogic (1, 1) { in A1 = N[U].L1[0]; }\n",
            .err = "3:29: Wrong direction N[U], for the side N only right and left are possible",
        },
        .{
            .text = "format 1;\ndevice \"M1/S\";\nswitch (0, 2) { N.L1[0] = NE.O1A; }\n",
            .err = "3:35: Trying to access output O1A, but tile (0,2).NE is io, not logic",
        },
        .{
            .text = "format 1;\ndevice \"M1/S\";\nbram (1, 9) { data { 000: 1; } }\n",
            .err = "3:20: In BRAM block, WIDTH must be specified before data",
        },
    }) |case| {
        const r = TextParser.parse(case.text, alloc);
        defer r.deinit(alloc);
        const e = r.err orelse {
            std.debug.print("expected '{s}' to fail parsing\n", .{case.text});
            return error.TestExpectedError;
        };
        try std.testing.expectEqualStrings(case.err, e);
    }
}

test "text: comments, free-form whitespace and number bases" {
    const r = try parseText(
        \\// a comment before everything
        \\format 1; device "M1/S"; // trailing comment
        \\global { RESERVED = 0b1010; }
        \\logic(1,2){LUT1=0b1111_1111_0000_0000;LUT2=65_535;in A1=N[L].L1[0];in B1=code 0x0F;}
        \\// and one at the end
    );
    defer r.deinit(alloc);

    try std.testing.expectEqual(0b1010, r.c.?.global.reserved);
    const logic = r.c.?.getLogic(.{ .row = 1, .col = 2 });
    try std.testing.expectEqual(0xFF00, logic.lut1);
    try std.testing.expectEqual(0xFFFF, logic.lut2);
    try std.testing.expectEqual(15, logic.inputs.get(.a1));
    try std.testing.expectEqual(15, logic.inputs.get(.b1));
}
