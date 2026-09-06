const std = @import("std");

const common = @import("../common.zig");
const wire_codes = @import("../wire_codes.zig");
const routing = @import("../routing.zig");
const Configuration = @import("../Configuration.zig");
const DeviceModel = @import("../DeviceModel.zig");
const text_tables = @import("text_tables.zig");

const TextEmitter = @This();

config: *const Configuration,
alloc: std.mem.Allocator,
w: std.Io.Writer.Allocating,

// Segments some configured sink selects, and the boxes driving them. Code 0
// never names a wire, so these are built purely from non-zero codes.
read_wires: std.AutoHashMapUnmanaged(routing.WireKey, void),
read_boxes: std.AutoHashMapUnmanaged(common.SwitchCoords, void),

warnings: std.ArrayList([]const u8),

pub const Result = struct {
    text: []const u8,
    warnings: []const []const u8,

    pub fn deinit(r: Result, alloc: std.mem.Allocator) void {
        alloc.free(r.text);
        for (r.warnings) |warning|
            alloc.free(warning);
        alloc.free(r.warnings);
    }
};

fn init(config: *const Configuration, alloc: std.mem.Allocator) TextEmitter {
    return .{
        .w = .init(alloc),
        .alloc = alloc,
        .config = config,
        .read_wires = .empty,
        .read_boxes = .empty,
        .warnings = .empty,
    };
}

fn deinit(e: *TextEmitter) void {
    e.read_wires.deinit(e.alloc);
    e.read_boxes.deinit(e.alloc);
}

fn finish(e: *TextEmitter) []const u8 {
    return e.w.toOwnedSlice() catch common.oom();
}

/// Records a problem with the configuration without abandoning the conversion:
/// the spec guarantees every binary bitstream has a textual form, however
/// broken the configuration it describes.
fn warn(e: *TextEmitter, comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.allocPrint(e.alloc, fmt, args) catch common.oom();
    e.warnings.append(e.alloc, msg) catch common.oom();
}

fn markRead(e: *TextEmitter, key: routing.WireKey) void {
    e.read_wires.put(e.alloc, key, {}) catch common.oom();
    e.read_boxes.put(e.alloc, key.start, {}) catch common.oom();
}

fn markChannelRead(
    e: *TextEmitter,
    channel: common.Channel,
    wire: anytype,
) void {
    const key = routing.segmentStart(
        channel,
        wire.dir,
        wire.class,
        wire.local_track,
        e.config.model.grid,
    ) orelse return;
    e.markRead(key);
}

fn collectSwitchReads(e: *TextEmitter, sw: common.SwitchCoords) void {
    const config = e.config.getSwitch(sw);
    if (std.meta.eql(config.*, std.mem.zeroes(Configuration.Switch)))
        return;

    var side_iter = config.sides.iterator();
    while (side_iter.next()) |side_entry| {
        const side = side_entry.key;
        for (&side_entry.value.l1, 0..) |code, track|
            e.collectSwitchSinkRead(sw, side, .l1, @intCast(track), code);
        for (&side_entry.value.l4, 0..) |code, track|
            e.collectSwitchSinkRead(sw, side, .l4, @intCast(track), code);
        e.collectSwitchSinkRead(sw, side, .l16, 0, side_entry.value.l16);
    }
}

fn collectSwitchSinkRead(
    e: *TextEmitter,
    sw: common.SwitchCoords,
    side: common.Side,
    class: common.WireClass,
    track: u3,
    code: u4,
) void {
    if (code == 0) return;
    const src = wire_codes.decodeSwitchSink(.{
        .side = side,
        .class = class,
        .dir = side.outDir(),
        .local_track = track,
    }, code);
    const wire = switch (src) {
        .wire => |w| w,
        .out, .code => return,
    };

    // Switchbox sources are already in local numbering, so only the driving
    // box has to be found.
    const start = routing.incomingStart(
        sw,
        wire.side,
        wire.class,
        e.config.model.grid,
    ) orelse return;
    e.markRead(.{
        .start = start,
        .dir = wire.dir,
        .class = wire.class,
        .local_track = wire.local_track,
    });
}

fn collectLogicReads(e: *TextEmitter, tile: common.TileCoords) void {
    const config = e.config.getLogic(tile);
    for (std.enums.values(common.LogicInput)) |in| {
        const code = config.inputs.get(in);
        if (code == 0) continue;
        const wire = switch (wire_codes.decodeLogicInput(in, code)) {
            .wire => |w| w,
            else => continue,
        };
        const channel = tile.channel(wire.side, e.config.model.grid) orelse continue;
        e.markChannelRead(channel, wire);
    }
}

fn collectBramReads(e: *TextEmitter, tile: common.TileCoords) void {
    const config = e.config.getBram(tile);
    for (0..common.BramInput.TOTAL) |idx| {
        const in = common.BramInput.fromIdx(@intCast(idx));
        const code: u5 = switch (in) {
            .a1 => |i| config.a1[i],
            .a2 => |i| config.a2[i],
            .di => |i| config.di[i],
            .we1 => config.we1,
            .we2 => config.we2,
        };
        if (code == 0) continue;
        const wire = switch (wire_codes.decodeBramInput(in, code)) {
            .wire => |w| w,
            else => continue,
        };
        e.markChannelRead(tile.bigChannel(wire.side, e.config.model.grid), wire);
    }
}

fn collectDspReads(e: *TextEmitter, tile: common.TileCoords) void {
    const config = e.config.getDsp(tile);
    for (0..common.DspInput.TOTAL) |idx| {
        const in = common.DspInput.fromIdx(@intCast(idx));
        const code: u5 = switch (in) {
            .a => |i| config.a[i],
            .b => |i| config.b[i],
            .c => |i| config.c[i],
            .md => config.md,
            .ad => config.ad,
            .we => config.we,
        };
        if (code == 0) continue;
        const wire = switch (wire_codes.decodeDspInput(in, code)) {
            .wire => |w| w,
            else => continue,
        };
        e.markChannelRead(tile.bigChannel(wire.side, e.config.model.grid), wire);
    }
}

fn collectIoReads(e: *TextEmitter, tile: common.TileCoords) void {
    const config = e.config.getIo(tile);
    const side = e.config.model.ioWireSide(tile);
    for (std.enums.values(common.IoInput)) |in| {
        const code = config.inputs.get(in);
        if (code == 0) continue;
        const wire = switch (wire_codes.decodeIoInput(in, side, code)) {
            .wire => |w| w,
            else => continue,
        };
        const channel = tile.channel(wire.side, e.config.model.grid) orelse continue;
        e.markChannelRead(channel, wire);
    }
}

fn collectReads(e: *TextEmitter) void {
    const model = &e.config.model;

    for (0..model.grid.vertexRows()) |row| {
        for (0..model.grid.vertexCols()) |col| {
            e.collectSwitchReads(.{
                .row = @intCast(row),
                .col = @intCast(col),
            });
        }
    }

    for (1..1 + model.grid.tileRows()) |row| {
        for (1..1 + model.grid.tileCols()) |col| {
            const tile = common.TileCoords{
                .row = @intCast(row),
                .col = @intCast(col),
            };
            switch (model.tileType(tile)) {
                .inert, .io => unreachable,
                .logic => e.collectLogicReads(tile),
                .bram => if ((row - 1) % 4 == 0) e.collectBramReads(tile),
                .dsp => if ((row - 1) % 4 == 0) e.collectDspReads(tile),
            }
        }
    }

    for (1..1 + model.tile_counts.get(.io)) |pin|
        e.collectIoReads(model.pinCoord(pin));
}

fn emitHeader(e: *TextEmitter) !void {
    const w = &e.w.writer;
    try w.print("format 1;\ndevice \"{s}\";\n\n", .{e.config.model.model_id});
}

fn emitSwitchSink(
    e: *TextEmitter,
    sw: common.SwitchCoords,
    side: common.Side,
    class: common.WireClass,
    track: u3,
    code: u4,
) !void {
    // A code-0 wire is parked on T[0] rather than driven by it, unless
    // something downstream actually reads it.
    if (code == 0 and !e.read_wires.contains(.{
        .start = sw,
        .dir = side.outDir(),
        .class = class,
        .local_track = track,
    })) return;
    const w = &e.w.writer;

    const sink = wire_codes.DirectionalWire1x1{
        .side = side,
        .class = class,
        .dir = side.outDir(),
        .local_track = track,
    };
    const src = wire_codes.resolveSwitchSink(sw, sink, code, e.config.model.grid);
    if (src == .code)
        e.warn(
            "switch ({},{}) {f}.{f}[{}]: code {} names a wire that does not exist here",
            .{ sw.row, sw.col, side, class, track, code },
        );

    try w.print("    {f}.{f}[{}] = ", .{ side, class, track });

    switch (src) {
        .out => |ts| {
            try w.print("{f}.", .{ts.corner});
            const tile = sw.tile(ts.corner);
            switch (e.config.model.tileType(tile)) {
                .inert => try w.writeAll("ZERO"),
                .logic => try w.print(
                    "{f}",
                    .{@as(wire_codes.LogicOutput, @enumFromInt(ts.index))},
                ),
                .bram => {
                    const tile_idx = (tile.row - 1) % 4;
                    try w.print("DO[{}]", .{tile_idx * 4 + ts.index});
                },
                .dsp => {
                    const tile_idx = (tile.row - 1) % 4;
                    try w.print("O[{}]", .{tile_idx * 4 + ts.index});
                },
                .io => try w.writeAll("I"),
            }
        },
        .wire => |wire| try w.print("{f}.{f}[{}]", .{ wire.side, wire.class, wire.local_track }),
        .code => |c| try w.print("code {}", .{c}),
    }
    try w.writeAll(";\n");
}

fn emitSwitchBlock(e: *TextEmitter, sw: common.SwitchCoords) !void {
    const config = e.config.getSwitch(sw);
    if (std.meta.eql(config.*, std.mem.zeroes(Configuration.Switch)) and
        !e.read_boxes.contains(sw))
        return;

    const w = &e.w.writer;
    try w.print("switch ({}, {}) {{\n", .{ sw.row, sw.col });

    var side_iter = config.sides.iterator();
    while (side_iter.next()) |side_entry| {
        const side = side_entry.key;
        for (&side_entry.value.l1, 0..) |code, track|
            try e.emitSwitchSink(sw, side, .l1, @intCast(track), code);
        for (&side_entry.value.l4, 0..) |code, track|
            try e.emitSwitchSink(sw, side, .l4, @intCast(track), code);
        try e.emitSwitchSink(sw, side, .l16, 0, side_entry.value.l16);
    }

    try w.writeAll("}\n\n");
}

fn emitCommands(
    e: *TextEmitter,
    comptime table: anytype,
    comptime input_table: anytype,
    comptime T: type,
    comptime Input: type,
    comptime indent: []const u8,
    tile: common.TileCoords,
    t: *const T,
) !void {
    const w = &e.w.writer;
    try w.writeAll("{\n");

    inline for (table) |row| {
        const expected_word: []const u8 = row.@"0";
        const width: usize = row.@"1";
        const config_field: []const u8 = row.@"2";
        const value_kind: text_tables.ValueKind = row.@"3";

        if (value_kind == .reg) {
            for (0..2) |i| {
                const reg: *const Configuration.Logic.Reg = &t.*.regs[i];
                if (std.meta.eql(reg.*, std.mem.zeroes(Configuration.Logic.Reg)))
                    continue;
                try w.print("    reg {} ", .{i + 1});
                try e.emitCommands(
                    text_tables.reg_table,
                    .{},
                    Configuration.Logic.Reg,
                    common.LogicInput,
                    "    ",
                    tile,
                    reg,
                );
            }
        } else if (value_kind == .data) blk: {
            const data = e.config.getBramData(tile);
            if (std.mem.allEqual(u16, &data.data, 0))
                break :blk;
            try w.writeAll("    data {\n");
            const data_width: u16 = switch (t.*.width) {
                0 => 1,
                1 => 2,
                2 => 4,
                3 => 8,
                4 => 16,
                5...7 => 16,
            };
            const addr_depth = 4096 / data_width;
            inline for (
                &[5]type{ u1, u2, u4, u8, u16 },
                &[5][]const u8{ "{X:0>1}", "{X:0>1}", "{X:0>1}", "{X:0>2}", "{X:0>4}" },
                &[5][]const u8{ "{X:0>3}", "{X:0>3}", "{X:0>3}", "{X:0>3}", "{X:0>2}" },
            ) |IntType, data_fmt, addr_fmt| {
                if (@typeInfo(IntType).int.bits == data_width) {
                    for (0..addr_depth / 8) |row_start| {
                        const addr = row_start * 8;
                        const chunk: [8]IntType = data.getChunk(addr, IntType, 8);
                        if (std.mem.allEqual(IntType, &chunk, 0))
                            continue;

                        try w.print("        " ++ addr_fmt ++ ":", .{addr});
                        for (chunk) |x|
                            try w.print(" " ++ data_fmt, .{x});
                        try w.writeAll(";\n");
                    }
                }
            }
            try w.writeAll("    }\n");
        } else {
            for (0..@max(1, width)) |index| {
                const v = if (width != 0)
                    @field(t.*, config_field)[index]
                else
                    @field(t.*, config_field);

                // WIDTH has to precede `data {}` (§"Textual format"), so a
                // width of 1 - which encodes as 0 - is written out anyway when
                // the tile has data that it decides how to read.
                const zero_is_meaningful = if (value_kind == .width)
                    !std.mem.allEqual(u16, &e.config.getBramData(tile).data, 0)
                else
                    false;
                if (!zero_is_meaningful and std.meta.eql(v, std.mem.zeroes(@TypeOf(v))))
                    continue;

                try w.writeAll(indent ++ "    " ++ expected_word);
                if (width != 0)
                    try w.print("[{}]", .{index});
                try w.writeAll(" = ");

                switch (value_kind) {
                    .reg, .data => unreachable,
                    .bit => try w.print("{}", .{@intFromBool(v)}),
                    .bin => |IntType| {
                        std.debug.assert(IntType == u4);
                        try w.print("0b{b:0>4}", .{v});
                    },
                    .hex => |IntType| {
                        std.debug.assert(IntType == u16);
                        try w.print("0x{X:0>4}", .{v});
                    },
                    .cin_src => switch (v) {
                        .zero => try w.writeAll("0"),
                        .one => try w.writeAll("1"),
                        .input => try w.writeAll("A1"),
                        .above => try w.writeAll("above"),
                    },
                    .clk => try w.print("CLK{}", .{v}),
                    .rst => try w.print("RST{}", .{v}),
                    .width => switch (v) {
                        0 => try w.writeAll("1"),
                        1 => try w.writeAll("2"),
                        2 => try w.writeAll("4"),
                        3 => try w.writeAll("8"),
                        4 => try w.writeAll("16"),
                        5...7 => try w.print("code {}", .{v}),
                    },
                }
                try w.writeAll(";\n");
            }
        }
    }

    inline for (input_table) |row| {
        const expected_input_word: []const u8 = comptime row.@"0";
        const input_width: usize = comptime row.@"1";
        const config_field: []const u8 = comptime row.@"2";
        const input_variant: []const u8 = comptime row.@"3";
        for (0..@max(1, input_width)) |index| {
            const in = if (@typeInfo(Input) == .@"enum")
                @field(Input, input_variant)
            else if (input_width != 0)
                @unionInit(Input, input_variant, @intCast(index))
            else
                @unionInit(Input, input_variant, {});

            const code: u5 = if (input_width != 0)
                // Array
                @intCast(@field(t.*, config_field)[index])
            else if (@typeInfo(@TypeOf(@field(t.*, config_field))) == .int)
                // Plain code
                @field(t.*, config_field)
            else
                // Assume EnumArray
                @field(t.*, config_field).get(in);

            if (code == 0) continue;

            try w.writeAll(indent ++ "    in " ++ expected_input_word);
            if (input_width != 0)
                try w.print("[{}]", .{index});
            try w.writeAll(" = ");

            const grid = e.config.model.grid;
            const block_name = if (Input == common.LogicInput)
                "logic"
            else if (Input == common.BramInput)
                "bram"
            else if (Input == common.DspInput)
                "dsp"
            else if (Input == common.IoInput)
                "io"
            else
                @compileError("Incorrect Input type");

            const src = if (Input == common.LogicInput)
                wire_codes.resolveLogicInput(tile, in, code, grid)
            else if (Input == common.BramInput)
                wire_codes.resolveBramInput(tile, in, code, grid)
            else if (Input == common.DspInput)
                wire_codes.resolveDspInput(tile, in, code, grid)
            else
                wire_codes.resolveIoInput(
                    tile,
                    in,
                    e.config.model.ioWireSide(tile),
                    code,
                    grid,
                );

            if (src == .code)
                e.warn(
                    block_name ++ " ({},{}) in {f}: code {} names a wire that does not exist here",
                    .{ tile.row, tile.col, in, code },
                );

            try w.print("{f};\n", .{src});
        }
    }

    try w.writeAll(indent ++ "}\n");
}

fn emitGlobalBlock(e: *TextEmitter) !void {
    if (std.meta.eql(e.config.global, std.mem.zeroes(Configuration.Global)))
        return;
    const w = &e.w.writer;
    try w.writeAll("global ");
    try e.emitCommands(
        text_tables.global_table,
        .{},
        Configuration.Global,
        void,
        "",
        undefined,
        &e.config.global,
    );
    try w.writeAll("\n");
}

fn emitLogicBlock(e: *TextEmitter, tile: common.TileCoords) !void {
    if (std.meta.eql(e.config.getLogic(tile).*, std.mem.zeroes(Configuration.Logic)))
        return;
    const w = &e.w.writer;
    try w.print("logic ({}, {}) ", .{ tile.row, tile.col });
    try e.emitCommands(
        text_tables.logic_table,
        text_tables.logic_inputs_table,
        Configuration.Logic,
        common.LogicInput,
        "",
        tile,
        e.config.getLogic(tile),
    );
    try w.writeAll("\n");
}

fn emitBramBlock(e: *TextEmitter, tile: common.TileCoords) !void {
    if ((tile.row - 1) % 4 != 0) return;
    const bram = e.config.getBram(tile);
    const bram_data = e.config.getBramData(tile);
    if (std.meta.eql(bram.*, std.mem.zeroes(Configuration.Bram)) and
        std.mem.allEqual(u16, &bram_data.data, 0))
        return;
    const w = &e.w.writer;
    try w.print("bram ({}, {}) ", .{ tile.row, tile.col });
    try e.emitCommands(
        text_tables.bram_table,
        text_tables.bram_inputs_table,
        Configuration.Bram,
        common.BramInput,
        "",
        tile,
        e.config.getBram(tile),
    );
    try w.writeAll("\n");
}

fn emitDspBlock(e: *TextEmitter, tile: common.TileCoords) !void {
    if ((tile.row - 1) % 4 != 0) return;
    if (std.meta.eql(e.config.getDsp(tile).*, std.mem.zeroes(Configuration.Dsp)))
        return;
    const w = &e.w.writer;
    try w.print("dsp ({}, {}) ", .{ tile.row, tile.col });
    try e.emitCommands(
        text_tables.dsp_table,
        text_tables.dsp_inputs_table,
        Configuration.Dsp,
        common.DspInput,
        "",
        tile,
        e.config.getDsp(tile),
    );
    try w.writeAll("\n");
}

fn emitIoBlock(e: *TextEmitter, tile: common.TileCoords) !void {
    if (std.meta.eql(e.config.getIo(tile).*, std.mem.zeroes(Configuration.Io)))
        return;
    const w = &e.w.writer;
    try w.print("io ({}, {}) ", .{ tile.row, tile.col });
    try e.emitCommands(
        text_tables.io_table,
        text_tables.io_inputs_table,
        Configuration.Io,
        common.IoInput,
        "",
        tile,
        e.config.getIo(tile),
    );
    try w.writeAll("\n");
}

pub fn emit(config: *const Configuration, alloc: std.mem.Allocator) Result {
    var e = TextEmitter.init(config, alloc);
    defer e.deinit();
    e.collectReads();
    e.emitHeader() catch common.oom();
    e.emitGlobalBlock() catch common.oom();

    for (0..config.model.grid.vertexRows()) |row| {
        for (0..config.model.grid.vertexCols()) |col| {
            e.emitSwitchBlock(.{
                .row = @intCast(row),
                .col = @intCast(col),
            }) catch common.oom();
        }
    }

    for (1..1 + config.model.grid.tileRows()) |row| {
        for (1..1 + config.model.grid.tileCols()) |col| {
            const tile = common.TileCoords{
                .row = @intCast(row),
                .col = @intCast(col),
            };
            switch (config.model.tileType(tile)) {
                .inert, .io => unreachable,
                .logic => e.emitLogicBlock(tile) catch common.oom(),
                .bram => e.emitBramBlock(tile) catch common.oom(),
                .dsp => e.emitDspBlock(tile) catch common.oom(),
            }
        }
    }

    for (1..1 + config.model.tile_counts.get(.io)) |pin| {
        const tile = config.model.pinCoord(pin);
        std.debug.assert(config.model.tileType(tile) == .io);
        e.emitIoBlock(tile) catch common.oom();
    }

    return .{
        .text = e.finish(),
        .warnings = e.warnings.toOwnedSlice(e.alloc) catch common.oom(),
    };
}
