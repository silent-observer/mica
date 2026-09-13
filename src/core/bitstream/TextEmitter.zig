//! `Configuration` to `.mica` text. Never fails - the spec guarantees every
//! binary bitstream has a textual form, so problems go to `warn()` and emission
//! continues. Zero-valued blocks are omitted, except that a wire some sink
//! reads is printed even when its driver code is 0, which is what the
//! `read_wires`/`read_boxes` pre-pass over the whole configuration is for.

const std = @import("std");

const common = @import("../common.zig");
const wire_codes = @import("../wire_codes.zig");
const routing = @import("../routing.zig");
const Configuration = @import("../Configuration.zig");
const DeviceModel = @import("../DeviceModel.zig");
const blocks = @import("blocks.zig");

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
        wire.track,
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
            e.collectSwitchSinkRead(sw, side, .l1, .track(@intCast(track)), code);
        for (&side_entry.value.l4, 0..) |code, track|
            e.collectSwitchSinkRead(sw, side, .l4, .track(@intCast(track)), code);
        e.collectSwitchSinkRead(sw, side, .l16, .track(0), side_entry.value.l16);
    }
}

fn collectSwitchSinkRead(
    e: *TextEmitter,
    sw: common.SwitchCoords,
    side: common.Side,
    class: common.WireClass,
    track: common.SwitchTrack,
    code: u4,
) void {
    if (code == 0) return;
    const src = wire_codes.decodeSwitchSink(.{
        .side = side,
        .class = class,
        .track = track,
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
        .dir = side.outDir(),
        .class = wire.class,
        .track = wire.track,
    });
}

fn collectTileReads(e: *TextEmitter, comptime t: common.TileType, tile: common.TileCoords) void {
    if (!t.carriesConfig(tile)) return;

    const config = e.config.get(t, tile);
    const cxt = e.config.model.inputCxt(t, tile);

    for (0..t.Input().TOTAL) |idx| {
        const in = t.Input().fromIdx(@intCast(idx));
        const code: u5 = @intCast(Configuration.getInput(config, in));
        if (code == 0) continue;
        const wire = switch (wire_codes.decodeInput(t, in, cxt, code)) {
            .wire => |w| w,
            else => continue,
        };
        const channel = if (comptime t.big())
            tile.bigChannel(wire.side, e.config.model.grid)
        else
            tile.channel(wire.side, e.config.model.grid) orelse continue;

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

    for (0..model.grid.rows) |row| {
        for (0..model.grid.cols) |col| {
            const tile = common.TileCoords{
                .row = @intCast(row),
                .col = @intCast(col),
            };

            const actual_t = model.tileType(tile);
            inline for (common.TileType.configurable) |t| {
                if (actual_t == t) {
                    e.collectTileReads(t, tile);
                }
            }
        }
    }
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
    track: common.SwitchTrack,
    code: u4,
) !void {
    // A code-0 wire is parked on T[0] rather than driven by it, unless
    // something downstream actually reads it.
    if (code == 0 and !e.read_wires.contains(.{
        .start = sw,
        .dir = side.outDir(),
        .class = class,
        .track = track,
    })) return;
    const w = &e.w.writer;

    const sink = common.SwitchWire{
        .side = side,
        .class = class,
        .track = track,
    };
    const src = wire_codes.resolveSwitchSink(sw, sink, code, e.config.model.grid);
    if (src == .code)
        e.warn(
            "switch ({},{}) {f}: code {} names a wire that does not exist here",
            .{ sw.row, sw.col, sink, code },
        );

    try w.print(
        "    {f} = {f};\n",
        .{ sink, src.plusSwitch(sw, &e.config.model) },
    );
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
            try e.emitSwitchSink(sw, side, .l1, .track(@intCast(track)), code);
        for (&side_entry.value.l4, 0..) |code, track|
            try e.emitSwitchSink(sw, side, .l4, .track(@intCast(track)), code);
        try e.emitSwitchSink(sw, side, .l16, .track(0), side_entry.value.l16);
    }

    try w.writeAll("}\n\n");
}

fn emitCommands(
    e: *TextEmitter,
    comptime meta: blocks.Metadata,
    comptime indent: []const u8,
    tile: common.TileCoords,
    cfg: *const meta.Config,
) !void {
    const w = &e.w.writer;
    try w.writeAll("{\n");

    inline for (meta.table) |f| {
        if (f.kind == .reg) {
            for (0..2) |i| {
                const reg: *const Configuration.Logic.Reg = &cfg.*.regs[i];
                if (std.meta.eql(reg.*, std.mem.zeroes(Configuration.Logic.Reg)))
                    continue;
                try w.print("    reg {} ", .{i + 1});
                try e.emitCommands(
                    blocks.reg,
                    "    ",
                    tile,
                    reg,
                );
            }
        } else if (f.kind == .data) blk: {
            const data = e.config.getBramData(tile);
            if (std.mem.allEqual(u16, &data.data, 0))
                break :blk;
            try w.writeAll("    data {\n");
            const data_width: u16 = switch (cfg.width) {
                .w1, .w2, .w4, .w8, .w16 => cfg.width.int(),
                else => 16,
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
            for (0..f.width) |index| {
                const v = if (f.width != 1)
                    @field(cfg.*, f.field)[index]
                else
                    @field(cfg.*, f.field);

                // WIDTH has to precede `data {}` (see "Textual format"), so a
                // width of 1 - which encodes as 0 - is written out anyway when
                // the tile has data that it decides how to read.
                const zero_is_meaningful = if (f.kind == .width)
                    !std.mem.allEqual(u16, &e.config.getBramData(tile).data, 0)
                else
                    false;
                if (!zero_is_meaningful and std.meta.eql(v, std.mem.zeroes(@TypeOf(v))))
                    continue;

                try w.writeAll(indent ++ "    " ++ f.word);
                if (f.width != 1)
                    try w.print("[{}]", .{index});
                try w.writeAll(" = ");

                switch (f.kind) {
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
                        .w1, .w2, .w4, .w8, .w16 => try w.print("{}", .{v.int()}),
                        else => try w.print("code {}", .{@intFromEnum(v)}),
                    },
                }
                try w.writeAll(";\n");
            }
        }
    }

    if (meta.tile) |t| {
        for (0..t.Input().TOTAL) |idx| {
            const in = t.Input().fromIdx(@intCast(idx));
            const code = Configuration.getInput(cfg, in);
            if (code == 0) continue;
            const cxt = e.config.model.inputCxt(t, tile);
            const src = wire_codes.resolveInput(t, tile, in, cxt, code, e.config.model.grid);
            if (src == .code)
                e.warn(
                    @tagName(t) ++ " ({},{}) in {f}: code {} names a wire that does not exist here",
                    .{ tile.row, tile.col, in, code },
                );

            try w.print(indent ++ "    in {f} = {f};\n", .{ in, src });
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
        blocks.global,
        "",
        undefined,
        &e.config.global,
    );
    try w.writeAll("\n");
}

fn emitTileBlock(e: *TextEmitter, comptime meta: blocks.Metadata, tile: common.TileCoords) !void {
    const t = meta.tile.?;
    if (!t.carriesConfig(tile)) return;

    const cfg = e.config.get(t, tile);
    const config_empty = std.meta.eql(cfg.*, std.mem.zeroes(meta.Config));
    const data_empty = if (t == .bram)
        std.mem.allEqual(u16, &e.config.getBramData(tile).data, 0)
    else
        true;
    if (config_empty and data_empty)
        return;
    const w = &e.w.writer;
    try w.print("{s} ({}, {}) ", .{ @tagName(t), tile.row, tile.col });
    try e.emitCommands(meta, "", tile, cfg);
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

            const actual_t = config.model.tileType(tile);
            inline for (common.TileType.configurable) |t| {
                if (actual_t == t)
                    e.emitTileBlock(blocks.forTile(t), tile) catch common.oom();
            }
        }
    }

    for (1..1 + config.model.tile_counts.get(.io)) |pin| {
        const tile = config.model.pinCoord(pin);
        std.debug.assert(config.model.tileType(tile) == .io);
        e.emitTileBlock(blocks.forTile(.io), tile) catch common.oom();
    }

    return .{
        .text = e.finish(),
        .warnings = e.warnings.toOwnedSlice(e.alloc) catch common.oom(),
    };
}
