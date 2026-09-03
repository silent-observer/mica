const std = @import("std");
const common = @import("common.zig");
const DeviceModel = @import("DeviceModel.zig");
const wire_codes = @import("wire_codes.zig");

pub const Fabric = @This();

alloc: std.mem.Allocator,
grid: common.GridSize,
wires: std.MultiArrayList(WireNode),
sources: std.MultiArrayList(SourceNode),
sinks: std.MultiArrayList(SinkNode),

wire_map: std.AutoHashMapUnmanaged(TrackKey, u32),
sources_map: std.AutoHashMapUnmanaged(TileKey, u32),
sinks_map: std.AutoHashMapUnmanaged(TileKey, u32),

in_conns: std.MultiArrayList(Connection),

pub const RoutingNodeId = struct {
    kind: Kind,
    id: u32,

    pub const Kind = enum {
        wire,
        source,
        sink,
    };
};

pub const WireNode = struct {
    start: common.SwitchCoords,
    end: common.SwitchCoords,
    dir: common.Direction,
    class: common.WireClass,
    track: u8,

    in_start: u32 = 0,
    in_end: u32 = 0,
};

pub const TileKey = struct {
    tile: common.TileCoords,
    index: u2,
};

pub const TrackKey = struct {
    channel: common.Channel,
    dir: common.Direction,
    class: common.WireClass,
    track: u8,
};

pub const SourceNode = struct {
    tile: common.TileCoords,
    output: u8,
};

pub const SinkNode = struct {
    tile: common.TileCoords,
    input: u8,

    in_start: u32 = 0,
    in_end: u32 = 0,
};

pub const Connection = struct {
    switchCoord: ?common.SwitchCoords,
    source: RoutingNodeId,
    sink: RoutingNodeId,
    code: u8,
};

pub fn initEmpty(alloc: std.mem.Allocator, model: DeviceModel) Fabric {
    return Fabric{
        .alloc = alloc,
        .grid = model.grid,

        .wires = .empty,
        .sources = .empty,
        .sinks = .empty,
        .wire_map = .empty,
        .sources_map = .empty,
        .sinks_map = .empty,

        .in_conns = .empty,
    };
}

pub fn deinit(f: *Fabric) void {
    f.wires.deinit(f.alloc);
    f.sources.deinit(f.alloc);
    f.sinks.deinit(f.alloc);
    f.wire_map.deinit(f.alloc);
    f.sources_map.deinit(f.alloc);
    f.sinks_map.deinit(f.alloc);
    f.in_conns.deinit(f.alloc);
}

pub fn build(alloc: std.mem.Allocator, model: DeviceModel) Fabric {
    var f = Fabric.initEmpty(alloc, model);

    f.generateSources(model);
    f.generateWires();
    f.generateSwitches();
    f.generateSinks(model);

    return f;
}

fn generateSources(f: *Fabric, model: DeviceModel) void {
    const count = 4 * model.grid.rows * model.grid.cols;
    f.sources.ensureTotalCapacity(f.alloc, count) catch common.oom();
    f.sources_map.ensureTotalCapacity(f.alloc, count) catch common.oom();

    // IO tiles
    for (0..model.tile_counts.get(.io)) |i| {
        const tile = model.pinCoord(i + 1);
        for (0..4) |j|
            f.sources_map.putAssumeCapacity(
                .{ .tile = tile, .index = @intCast(j) },
                @intCast(f.sources.len),
            );
        f.sources.appendAssumeCapacity(.{
            .tile = tile,
            .output = 0,
        });
    }

    for (1..1 + f.grid.tileCols()) |col| {
        for (1..1 + f.grid.tileRows()) |row| {
            for (0..4) |j| {
                const tile = common.TileCoords{
                    .row = @intCast(row),
                    .col = @intCast(col),
                };
                f.sources_map.putAssumeCapacity(
                    .{ .tile = tile, .index = @intCast(j) },
                    @intCast(f.sources.len),
                );
                f.sources.appendAssumeCapacity(.{
                    .tile = tile,
                    .output = @intCast(j),
                });
            }
        }
    }
}

const L1_TRACKS = 6;
const L4_TRACKS = 8;
const L4_TRACKS_PER_SW = 2;
const L16_TRACKS = 4;

fn outgoingTrack(
    _: *const Fabric,
    sw: common.SwitchCoords,
    s: common.Side,
    class: common.WireClass,
    local_track: usize,
) ?u8 {
    const n = switch (s.outDir().orientation()) {
        .horizontal => sw.col,
        .vertical => sw.row,
    };
    switch (class) {
        .l1 => return @intCast(local_track),
        .l4 => return @intCast(2 * (n % 4) + local_track),
        .l16 => {
            if (n % 4 != 0) return null;
            return @intCast((n / 4) % 4);
        },
    }
}

fn incomingTrack(
    f: *const Fabric,
    sw: common.SwitchCoords,
    s: common.Side,
    class: common.WireClass,
    local_track: usize,
) ?u8 {
    const start_sw = sw.move(s.outDir(), f.grid, class.len()) orelse return null;
    const n = switch (s.inDir().orientation()) {
        .horizontal => start_sw.col,
        .vertical => start_sw.row,
    };
    switch (class) {
        .l1 => return @intCast(local_track),
        .l4 => return @intCast(2 * (n % 4) + local_track),
        .l16 => {
            if (n % 4 != 0) return null;
            return @intCast((n / 4) % 4);
        },
    }
}

fn generateWires(f: *Fabric) void {
    // Prepare space
    const l1_count = f.grid.edgeCount() * L1_TRACKS * 2;
    const l4_count = f.grid.edgeCount() * L4_TRACKS * 2;
    const l16_count = f.grid.edgeCount() * L16_TRACKS * 2;
    f.wires.ensureUnusedCapacity(
        f.alloc,
        l1_count + l4_count / 4 + l16_count / 16,
    ) catch common.oom();
    f.wire_map.ensureUnusedCapacity(
        f.alloc,
        l1_count + l4_count + l16_count,
    ) catch common.oom();

    for (std.enums.values(common.WireClass)) |class| {
        const local_track_count: usize = switch (class) {
            .l1 => L1_TRACKS,
            .l4 => L4_TRACKS_PER_SW,
            .l16 => 1,
        };
        for (std.enums.values(common.Direction)) |dir| {
            for (0..f.grid.vertexRows()) |sw_row| {
                for (0..f.grid.vertexCols()) |sw_col| {
                    const sw0 = common.SwitchCoords{
                        .row = @intCast(sw_row),
                        .col = @intCast(sw_col),
                    };
                    var len: usize = 0;
                    var channels: [16]common.Channel = undefined;
                    var last_sw = sw0;
                    for (0..class.len()) |_| {
                        if (last_sw.move(dir, f.grid, 1)) |new_sw| {
                            channels[len] = last_sw.channel(dir, f.grid).?;
                            last_sw = new_sw;
                            len += 1;
                        } else break;
                    }
                    if (len == 0) continue;

                    for (0..local_track_count) |local_track| {
                        const track = f.outgoingTrack(
                            sw0,
                            dir.side(),
                            class,
                            local_track,
                        ) orelse continue;

                        for (channels[0..len]) |c| {
                            f.wire_map.putAssumeCapacity(.{
                                .channel = c,
                                .class = class,
                                .dir = dir,
                                .track = track,
                            }, @intCast(f.wires.len));
                        }
                        f.wires.appendAssumeCapacity(.{
                            .class = class,
                            .dir = dir,
                            .start = sw0,
                            .end = last_sw,
                            .track = track,
                        });
                    }
                }
            }
        }
    }
}

fn generateSwitches(f: *Fabric) void {
    for (0..f.grid.vertexRows()) |row| {
        for (0..f.grid.vertexCols()) |col| {
            const sw = common.SwitchCoords{
                .row = @intCast(row),
                .col = @intCast(col),
            };
            for (std.enums.values(common.Side)) |s| {
                for (0..L1_TRACKS) |i| {
                    f.generateSwitchSink(sw, wire_codes.DirectionalWire1x1{
                        .class = .l1,
                        .side = s,
                        .dir = s.outDir(),
                        .local_track = @intCast(i),
                    });
                }
                for (0..L4_TRACKS_PER_SW) |u| {
                    f.generateSwitchSink(sw, wire_codes.DirectionalWire1x1{
                        .class = .l4,
                        .side = s,
                        .dir = s.outDir(),
                        .local_track = @intCast(u),
                    });
                }

                const n = switch (s.outDir().orientation()) {
                    .vertical => sw.row,
                    .horizontal => sw.col,
                };
                if (n % 4 == 0) {
                    f.generateSwitchSink(sw, wire_codes.DirectionalWire1x1{
                        .class = .l16,
                        .side = s,
                        .dir = s.outDir(),
                        .local_track = 0,
                    });
                }
            }
        }
    }
}

fn generateSwitchSink(f: *Fabric, sw: common.SwitchCoords, sink: wire_codes.DirectionalWire1x1) void {
    // Switchbox codes name tracks locally (the segments starting/ending at this box);
    // wire_map is keyed by the edge track number, so both ends need translating.
    const sink_track = f.outgoingTrack(sw, sink.side, sink.class, sink.local_track) orelse return;
    const sink_idx = f.wire_map.get(TrackKey{
        .channel = sw.channelSide(sink.side, f.grid) orelse return,
        .class = sink.class,
        .dir = sink.dir,
        .track = sink_track,
    }) orelse return;

    f.wires.items(.in_start)[sink_idx] = @intCast(f.in_conns.len);

    for (0..16) |code| {
        const src = wire_codes.decodeSwitchSink(sink, @intCast(code));
        switch (src) {
            .out => |ts| {
                const src_idx = f.sources_map.get(TileKey{
                    .tile = sw.tile(ts.corner),
                    .index = ts.index,
                }) orelse continue;

                f.in_conns.append(f.alloc, .{
                    .code = @intCast(code),
                    .sink = .{ .id = sink_idx, .kind = .wire },
                    .source = .{ .id = src_idx, .kind = .source },
                    .switchCoord = sw,
                }) catch common.oom();
            },
            .wire => |w| {
                // A missing incoming segment (grid edge, or an L16 that starts
                // elsewhere) makes the code illegal, so it gets no connection.
                const src_track = f.incomingTrack(sw, w.side, w.class, w.local_track) orelse continue;
                const src_idx = f.wire_map.get(TrackKey{
                    .channel = sw.channelSide(w.side, f.grid) orelse continue,
                    .class = w.class,
                    .dir = w.dir,
                    .track = src_track,
                }) orelse continue;

                f.in_conns.append(f.alloc, .{
                    .code = @intCast(code),
                    .sink = .{ .id = sink_idx, .kind = .wire },
                    .source = .{ .id = src_idx, .kind = .wire },
                    .switchCoord = sw,
                }) catch common.oom();
            },
        }
    }

    f.wires.items(.in_end)[sink_idx] = @intCast(f.in_conns.len);
}

fn generateSinks(f: *Fabric, model: DeviceModel) void {
    const count = model.tile_counts.get(.logic) * common.LogicInput.TOTAL +
        model.tile_counts.get(.bram) * common.BramInput.TOTAL +
        model.tile_counts.get(.dsp) * common.DspInput.TOTAL +
        model.tile_counts.get(.io) * common.IoInput.TOTAL;
    f.sinks.ensureTotalCapacity(f.alloc, count) catch common.oom();
    f.sinks_map.ensureTotalCapacity(f.alloc, count) catch common.oom();

    // IO tiles
    for (0..model.tile_counts.get(.io)) |i| {
        const tile = model.pinCoord(i + 1);
        f.generateIoSink(tile);
    }

    for (model.column_types, 0..) |t, col| {
        var row: u32 = 1;
        while (row < 1 + f.grid.tileRows()) {
            const tile = common.TileCoords{
                .row = row,
                .col = @intCast(col),
            };
            switch (t) {
                .none, .io => {
                    row += 1;
                },
                .logic => {
                    f.generateLogicSink(tile);
                    row += 1;
                },
                .bram => {
                    f.generateBramSink(tile);
                    row += 4;
                },
                .dsp => {
                    f.generateDspSink(tile);
                    row += 4;
                },
            }
        }
    }
}

fn generateLogicSink(f: *Fabric, tile: common.TileCoords) void {
    for (std.enums.values(common.LogicInput)) |in| {
        const sink_idx: u32 = @intCast(f.sinks.len);
        const in_start: u32 = @intCast(f.in_conns.len);

        for (0..32) |code| {
            const src = wire_codes.decodeLogicInput(in, @intCast(code));
            switch (src) {
                .code => unreachable,
                .zero, .one => {},
                .local => |lo| {
                    const src_idx = f.sources_map.get(.{
                        .tile = tile,
                        .index = @intFromEnum(lo),
                    }).?;

                    f.in_conns.append(f.alloc, .{
                        .code = @intCast(code),
                        .sink = .{ .id = sink_idx, .kind = .sink },
                        .source = .{ .id = src_idx, .kind = .source },
                        .switchCoord = null,
                    }) catch common.oom();
                },
                .wire => |w| {
                    const src_idx = f.wire_map.get(TrackKey{
                        .channel = tile.channel(w.side, f.grid) orelse continue,
                        .class = w.class,
                        .dir = w.dir,
                        .track = w.local_track,
                    }) orelse continue;

                    f.in_conns.append(f.alloc, .{
                        .code = @intCast(code),
                        .sink = .{ .id = sink_idx, .kind = .sink },
                        .source = .{ .id = src_idx, .kind = .wire },
                        .switchCoord = null,
                    }) catch common.oom();
                },
            }
        }

        const in_end: u32 = @intCast(f.in_conns.len);
        f.sinks.appendAssumeCapacity(.{
            .tile = tile,
            .input = in.idx(),
            .in_start = in_start,
            .in_end = in_end,
        });
    }
}

fn generateBramSink(f: *Fabric, tile: common.TileCoords) void {
    for (0..common.BramInput.TOTAL) |idx| {
        const in = common.BramInput.fromIdx(@intCast(idx));
        const max_codes: usize = switch (in) {
            .a1, .a2, .di => 16,
            .we1, .we2 => 32,
        };

        const sink_idx: u32 = @intCast(f.sinks.len);
        const in_start: u32 = @intCast(f.in_conns.len);
        for (0..max_codes) |code| {
            const src = wire_codes.decodeBramInput(in, @intCast(code));
            switch (src) {
                .code => unreachable,
                .zero, .one => {},
                .wire => |w| {
                    const src_idx = f.wire_map.get(TrackKey{
                        .channel = tile.bigChannel(w.side, f.grid),
                        .class = w.class,
                        .dir = w.dir,
                        .track = w.local_track,
                    }) orelse continue;

                    f.in_conns.append(f.alloc, .{
                        .code = @intCast(code),
                        .sink = .{ .id = sink_idx, .kind = .sink },
                        .source = .{ .id = src_idx, .kind = .wire },
                        .switchCoord = null,
                    }) catch common.oom();
                },
            }
        }

        const in_end: u32 = @intCast(f.in_conns.len);
        f.sinks.appendAssumeCapacity(.{
            .tile = tile,
            .input = in.idx(),
            .in_start = in_start,
            .in_end = in_end,
        });
    }
}

fn generateDspSink(f: *Fabric, tile: common.TileCoords) void {
    for (0..common.DspInput.TOTAL) |idx| {
        const in = common.DspInput.fromIdx(@intCast(idx));

        const sink_idx: u32 = @intCast(f.sinks.len);
        const in_start: u32 = @intCast(f.in_conns.len);
        for (0..32) |code| {
            const src = wire_codes.decodeDspInput(in, @intCast(code));
            switch (src) {
                .code => unreachable,
                .zero, .one => {},
                .wire => |w| {
                    const src_idx = f.wire_map.get(TrackKey{
                        .channel = tile.bigChannel(w.side, f.grid),
                        .class = w.class,
                        .dir = w.dir,
                        .track = w.local_track,
                    }) orelse continue;

                    f.in_conns.append(f.alloc, .{
                        .code = @intCast(code),
                        .sink = .{ .id = sink_idx, .kind = .sink },
                        .source = .{ .id = src_idx, .kind = .wire },
                        .switchCoord = null,
                    }) catch common.oom();
                },
            }
        }

        const in_end: u32 = @intCast(f.in_conns.len);
        f.sinks.appendAssumeCapacity(.{
            .tile = tile,
            .input = in.idx(),
            .in_start = in_start,
            .in_end = in_end,
        });
    }
}

fn generateIoSink(f: *Fabric, tile: common.TileCoords) void {
    const side: common.Side = if (tile.row == f.grid.northIo())
        .s
    else if (tile.row == f.grid.southIo())
        .n
    else if (tile.col == f.grid.westIo())
        .e
    else if (tile.col == f.grid.eastIo())
        .w
    else
        unreachable;

    const channel = tile.channel(side, f.grid).?;

    for (std.enums.values(common.IoInput)) |in| {
        const sink_idx: u32 = @intCast(f.sinks.len);
        const in_start: u32 = @intCast(f.in_conns.len);

        for (0..32) |code| {
            const src = wire_codes.decodeIoInput(in, side, @intCast(code));
            switch (src) {
                .code => unreachable,
                .zero, .one => {},
                .wire => |w| {
                    const src_idx = f.wire_map.get(TrackKey{
                        .channel = channel,
                        .class = w.class,
                        .dir = w.dir,
                        .track = w.local_track,
                    }) orelse continue;

                    f.in_conns.append(f.alloc, .{
                        .code = @intCast(code),
                        .sink = .{ .id = sink_idx, .kind = .sink },
                        .source = .{ .id = src_idx, .kind = .wire },
                        .switchCoord = null,
                    }) catch common.oom();
                },
            }
        }

        const in_end: u32 = @intCast(f.in_conns.len);

        f.sinks.appendAssumeCapacity(.{
            .tile = tile,
            .input = in.idx(),
            .in_start = in_start,
            .in_end = in_end,
        });
    }
}

pub fn writeNodes(f: *const Fabric, w: *std.Io.Writer) !void {
    try w.writeAll("id,x,y,color,class\n");
    const wire_slice = f.wires.slice();
    for (
        @as([]common.SwitchCoords, wire_slice.items(.start)),
        @as([]common.Direction, wire_slice.items(.dir)),
        @as([]common.WireClass, wire_slice.items(.class)),
        @as([]u8, wire_slice.items(.track)),
    ) |
        start,
        dir,
        class,
        track,
    | {
        const color = switch (class) {
            .l1 => switch (dir) {
                .up => "red",
                .right => "green",
                .down => "blue",
                .left => "yellow",
            },
            .l4 => "white",
            .l16 => "magenta",
        };
        try w.print("r{}c{}_{s}_{s}_{},{},{},{s},{s}\n", .{
            start.row,
            start.col,
            @tagName(dir),
            @tagName(class),
            track,
            start.col,
            start.row,
            color,
            @tagName(class),
        });
    }

    const source_slice = f.sources.slice();
    for (
        @as([]common.TileCoords, source_slice.items(.tile)),
        @as([]u8, source_slice.items(.output)),
    ) |tile, output| {
        const color = "orange";
        try w.print("r{}c{}_O{},{},{},{s},{s}\n", .{
            tile.row,
            tile.col,
            output,
            tile.col,
            tile.row,
            color,
            "source",
        });
    }

    const sink_slice = f.sinks.slice();
    for (
        @as([]common.TileCoords, sink_slice.items(.tile)),
        @as([]u8, sink_slice.items(.input)),
    ) |tile, input| {
        const color = "cyan";
        try w.print("r{}c{}_I{},{},{},{s},{s}\n", .{
            tile.row,
            tile.col,
            input,
            tile.col,
            tile.row,
            color,
            "source",
        });
    }
}

pub fn writeConnections(f: *const Fabric, w: *std.Io.Writer) !void {
    try w.writeAll("source,target,color,strength\n");
    const in_conns_slice = f.in_conns.slice();
    for (
        @as([]RoutingNodeId, in_conns_slice.items(.source)),
        @as([]RoutingNodeId, in_conns_slice.items(.sink)),
        @as([]u8, in_conns_slice.items(.code)),
    ) |source_id, sink_id, code| {
        var source_strength: f32 = 1;
        switch (source_id.kind) {
            .wire => {
                const source = f.wires.get(source_id.id);
                try w.print("r{}c{}_{s}_{s}_{},", .{
                    source.start.row,
                    source.start.col,
                    @tagName(source.dir),
                    @tagName(source.class),
                    source.track,
                });
                source_strength = switch (source.class) {
                    .l1 => 1,
                    .l4 => 1.0 / 4.0,
                    .l16 => 1.0 / 16.0,
                };
            },
            .source => {
                const source = f.sources.get(source_id.id);
                try w.print("r{}c{}_O{},", .{
                    source.tile.row,
                    source.tile.col,
                    source.output,
                });
            },
            .sink => unreachable,
        }

        var target_strength: f32 = 1;
        switch (sink_id.kind) {
            .wire => {
                const target = f.wires.get(sink_id.id);
                try w.print("r{}c{}_{s}_{s}_{},", .{
                    target.start.row,
                    target.start.col,
                    @tagName(target.dir),
                    @tagName(target.class),
                    target.track,
                });
                target_strength = switch (target.class) {
                    .l1 => 1,
                    .l4 => 1.0 / 4.0,
                    .l16 => 1.0 / 16.0,
                };
            },
            .sink => {
                const target = f.sinks.get(sink_id.id);
                try w.print("r{}c{}_I{},", .{
                    target.tile.row,
                    target.tile.col,
                    target.input,
                });
            },
            .source => unreachable,
        }

        const str: f32 = @min(source_strength, target_strength);
        try w.print("{},{}\n", .{ code, str * str });
    }
}
