const std = @import("std");
const common = @import("common.zig");
const DeviceModel = @import("DeviceModel.zig");

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
    index: u8,
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
                f.generateSwitchL1(sw, s);
                f.generateSwitchL4(sw, s);
                f.generateSwitchL16(sw, s);
            }
        }
    }
}

fn tryConnectWire(f: *Fabric, key: TrackKey, code: u8, sink_idx: u32, sw: common.SwitchCoords) void {
    if (f.wire_map.get(key)) |src_idx| {
        f.in_conns.append(f.alloc, .{
            .code = code,
            .sink = .{ .id = sink_idx, .kind = .wire },
            .source = .{ .id = src_idx, .kind = .wire },
            .switchCoord = sw,
        }) catch common.oom();
    }
}

const L4L16Template = struct {
    l1code: u8,
    l4code: u8,
    l16code: u8,
    l1off: u8,
};

fn generateSwitchL1(f: *Fabric, sw: common.SwitchCoords, s: common.Side) void {
    const c_out = sw.channelSide(s, f.grid) orelse return;

    const templates: [3]L4L16Template = .{
        .{ .l1code = 4, .l4code = 7, .l16code = 13, .l1off = 0 },
        .{ .l1code = 5, .l4code = 9, .l16code = 14, .l1off = 1 },
        .{ .l1code = 6, .l4code = 11, .l16code = 15, .l1off = 2 },
    };

    for (0..L1_TRACKS) |i| {
        const tk = TrackKey{
            .channel = c_out,
            .class = .l1,
            .dir = s.outDir(),
            .track = @intCast(i),
        };
        const sink_idx = f.wire_map.get(tk) orelse continue;

        f.wires.items(.in_start)[sink_idx] = @intCast(f.in_conns.len);

        // Codes 0,1,2,3
        for (std.enums.values(common.Corner), 0..4) |corner, code| {
            const tk_src_o = TileKey{
                .tile = sw.tile(corner),
                .index = @intCast((i + s.int() + code) % 4),
            };

            if (f.sources_map.get(tk_src_o)) |src_idx| {
                f.in_conns.append(f.alloc, .{
                    .code = @intCast(code),
                    .sink = .{ .id = sink_idx, .kind = .wire },
                    .source = .{ .id = src_idx, .kind = .source },
                    .switchCoord = sw,
                }) catch common.oom();
            }
        }

        const sides: [3]common.Side = .{ s.straight(), s.left(), s.right() };
        for (sides, templates) |in_s, template| {
            const in_c = sw.channelSide(in_s, f.grid) orelse continue;

            // L1
            f.tryConnectWire(
                TrackKey{
                    .channel = in_c,
                    .class = .l1,
                    .dir = in_s.inDir(),
                    .track = @intCast((i + template.l1off) % L1_TRACKS),
                },
                template.l1code,
                sink_idx,
                sw,
            );

            // L4
            for (0..L4_TRACKS_PER_SW) |u| {
                if (f.incomingTrack(sw, in_s, .l4, u)) |in_track|
                    f.tryConnectWire(
                        TrackKey{
                            .channel = in_c,
                            .class = .l4,
                            .dir = in_s.inDir(),
                            .track = in_track,
                        },
                        @intCast(template.l4code + u),
                        sink_idx,
                        sw,
                    );
            }

            // L16
            if (f.incomingTrack(sw, in_s, .l16, 0)) |in_track|
                f.tryConnectWire(
                    TrackKey{
                        .channel = in_c,
                        .class = .l16,
                        .dir = in_s.inDir(),
                        .track = in_track,
                    },
                    template.l16code,
                    sink_idx,
                    sw,
                );
        }

        f.wires.items(.in_end)[sink_idx] = @intCast(f.in_conns.len);
    }
}

fn generateSwitchL4(f: *Fabric, sw: common.SwitchCoords, s: common.Side) void {
    const c_out = sw.channelSide(s, f.grid) orelse return;
    const n = switch (s.outDir().orientation()) {
        .vertical => sw.row,
        .horizontal => sw.col,
    };

    const templates: [3]L4L16Template = .{
        .{ .l1code = 13, .l4code = 4, .l16code = 10, .l1off = 0 },
        .{ .l1code = 14, .l4code = 6, .l16code = 11, .l1off = 1 },
        .{ .l1code = 15, .l4code = 8, .l16code = 12, .l1off = 2 },
    };

    // L4
    for (0..L4_TRACKS_PER_SW) |u_1| {
        const track = 2 * (n % 4) + u_1;
        const tk = TrackKey{
            .channel = c_out,
            .class = .l4,
            .dir = s.outDir(),
            .track = @intCast(track),
        };
        const sink_idx = f.wire_map.get(tk) orelse continue;

        f.wires.items(.in_start)[sink_idx] = @intCast(f.in_conns.len);

        // Codes 0,1,2,3
        for (std.enums.values(common.Corner), 0..4) |corner, code| {
            const tk_src_o = TileKey{
                .tile = sw.tile(corner),
                .index = @intCast((u_1 + s.int() + code) % 4),
            };

            if (f.sources_map.get(tk_src_o)) |src_idx| {
                f.in_conns.append(f.alloc, .{
                    .code = @intCast(code),
                    .sink = .{ .id = sink_idx, .kind = .wire },
                    .source = .{ .id = src_idx, .kind = .source },
                    .switchCoord = sw,
                }) catch common.oom();
            }
        }

        const sides: [3]common.Side = .{ s.straight(), s.left(), s.right() };
        for (sides, templates) |in_s, template| {
            const in_c = sw.channelSide(in_s, f.grid) orelse continue;

            // L1
            f.tryConnectWire(
                TrackKey{
                    .channel = in_c,
                    .class = .l1,
                    .dir = in_s.inDir(),
                    .track = @intCast(3 * u_1 + template.l1off),
                },
                template.l1code,
                sink_idx,
                sw,
            );

            // L4
            for (0..L4_TRACKS_PER_SW) |u| {
                if (f.incomingTrack(sw, in_s, .l4, u)) |in_track|
                    f.tryConnectWire(
                        TrackKey{
                            .channel = in_c,
                            .class = .l4,
                            .dir = in_s.inDir(),
                            .track = in_track,
                        },
                        @intCast(template.l4code + u),
                        sink_idx,
                        sw,
                    );
            }

            // L16
            if (f.incomingTrack(sw, in_s, .l16, 0)) |in_track|
                f.tryConnectWire(
                    TrackKey{
                        .channel = in_c,
                        .class = .l16,
                        .dir = in_s.inDir(),
                        .track = in_track,
                    },
                    template.l16code,
                    sink_idx,
                    sw,
                );
        }

        f.wires.items(.in_end)[sink_idx] = @intCast(f.in_conns.len);
    }
}

fn generateSwitchL16(f: *Fabric, sw: common.SwitchCoords, s: common.Side) void {
    const c_out = sw.channelSide(s, f.grid) orelse return;
    const sink_n = switch (s.outDir().orientation()) {
        .vertical => sw.row,
        .horizontal => sw.col,
    };

    if (sink_n % 4 != 0) return;

    const templates: [3]L4L16Template = .{
        .{ .l1code = 13, .l4code = 7, .l16code = 4, .l1off = 4 },
        .{ .l1code = 14, .l4code = 9, .l16code = 5, .l1off = 5 },
        .{ .l1code = 15, .l4code = 11, .l16code = 6, .l1off = 5 },
    };

    // L16
    const sink_track = (sink_n / 4) % L16_TRACKS;
    const tk = TrackKey{
        .channel = c_out,
        .class = .l16,
        .dir = s.outDir(),
        .track = @intCast(sink_track),
    };
    const sink_idx = f.wire_map.get(tk) orelse return;

    f.wires.items(.in_start)[sink_idx] = @intCast(f.in_conns.len);

    // Codes 0,1,2,3
    for (std.enums.values(common.Corner), 0..4) |corner, code| {
        const tk_src_o = TileKey{
            .tile = sw.tile(corner),
            .index = @intCast((s.int() + code) % 4),
        };

        if (f.sources_map.get(tk_src_o)) |src_idx| {
            f.in_conns.append(f.alloc, .{
                .code = @intCast(code),
                .sink = .{ .id = sink_idx, .kind = .wire },
                .source = .{ .id = src_idx, .kind = .source },
                .switchCoord = sw,
            }) catch common.oom();
        }
    }

    const sides: [3]common.Side = .{ s.straight(), s.left(), s.right() };
    for (sides, templates) |in_s, template| {
        const in_c = sw.channelSide(in_s, f.grid) orelse continue;

        // L1
        f.tryConnectWire(
            TrackKey{
                .channel = in_c,
                .class = .l1,
                .dir = in_s.inDir(),
                .track = template.l1off,
            },
            template.l1code,
            sink_idx,
            sw,
        );

        // L4
        for (0..L4_TRACKS_PER_SW) |u| {
            if (f.incomingTrack(sw, in_s, .l4, u)) |in_track|
                f.tryConnectWire(
                    TrackKey{
                        .channel = in_c,
                        .class = .l4,
                        .dir = in_s.inDir(),
                        .track = in_track,
                    },
                    @intCast(template.l4code + u),
                    sink_idx,
                    sw,
                );
        }

        // L16
        if (f.incomingTrack(sw, in_s, .l16, 0)) |in_track|
            f.tryConnectWire(
                TrackKey{
                    .channel = in_c,
                    .class = .l16,
                    .dir = in_s.inDir(),
                    .track = in_track,
                },
                template.l16code,
                sink_idx,
                sw,
            );
    }

    f.wires.items(.in_end)[sink_idx] = @intCast(f.in_conns.len);
}

fn trackWindow(
    channel: common.Channel,
    dir: common.Direction,
    parity: usize,
    d: usize,
    idx: usize,
) TrackKey {
    const i = (d + idx) % 9;
    const track: u8 = switch (i) {
        0, 1, 2 => @intCast(parity),
        3, 4, 7 => @intCast(2 + parity),
        5, 6 => @intCast(4 + parity),
        8 => @intCast(6 + parity),
        else => unreachable,
    };
    const class: common.WireClass = switch (i) {
        0, 3, 6 => .l1,
        1, 4, 5, 8 => .l4,
        2, 7 => .l16,
        else => unreachable,
    };

    return TrackKey{
        .channel = channel,
        .dir = dir,
        .class = class,
        .track = track,
    };
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
        const p: usize = switch (in) {
            .a1, .b1, .c1, .d1, .ce1 => 0,
            .a2, .b2, .c2, .d2, .ce2 => 1,
        };

        const sink_idx: u32 = @intCast(f.sinks.len);
        const in_start: u32 = @intCast(f.in_conns.len);

        switch (in) {
            // ABCD inputs
            .a1, .a2, .b1, .b2, .c1, .c2, .d1, .d2 => {
                const primary_side: common.Side = switch (in) {
                    .a1 => .n,
                    .b1 => .e,
                    .c1 => .s,
                    .d1 => .w,

                    .a2 => .s,
                    .b2 => .w,
                    .c2 => .n,
                    .d2 => .e,
                    else => unreachable,
                };
                const primary_c = tile.channel(primary_side, f.grid).?;
                const secondary_side = primary_side.straight();
                const secondary_c = tile.channel(secondary_side, f.grid).?;
                const secondary_p = 1 - p;
                const secondary_dir: common.Direction = switch (in) {
                    .a1, .b1, .c1, .d1 => secondary_side.turnDir(.cw),
                    .a2, .b2, .c2, .d2 => secondary_side.turnDir(.ccw),
                    else => unreachable,
                };

                // Codes 2..5
                for (0..4) |i| {
                    // std.debug.print("{} {}\n", .{ tile, i });
                    const src_idx = f.sources_map.get(.{
                        .tile = tile,
                        .index = @intCast(i),
                    }).?;

                    f.in_conns.append(f.alloc, .{
                        .code = @intCast(2 + i),
                        .sink = .{ .id = sink_idx, .kind = .sink },
                        .source = .{ .id = src_idx, .kind = .source },
                        .switchCoord = null,
                    }) catch common.oom();
                }

                // Codes 6..23
                for (std.enums.values(common.WireClass)) |class| {
                    const count: usize = switch (class) {
                        .l1 => 3,
                        .l4 => 4,
                        .l16 => 2,
                    };
                    const code_start: u8 = switch (class) {
                        .l1 => 6,
                        .l4 => 12,
                        .l16 => 20,
                    };
                    for (std.enums.values(common.TurnOrientation), 0..2) |to, to_idx| {
                        const dir = primary_side.turnDir(to);
                        for (0..count) |j| {
                            const key = TrackKey{
                                .channel = primary_c,
                                .class = class,
                                .dir = dir,
                                .track = @intCast(2 * j + p),
                            };
                            const code: u8 = @intCast(code_start + to_idx * count + j);

                            if (f.wire_map.get(key)) |src_idx| {
                                f.in_conns.append(f.alloc, .{
                                    .code = code,
                                    .sink = .{ .id = sink_idx, .kind = .sink },
                                    .source = .{ .id = src_idx, .kind = .wire },
                                    .switchCoord = null,
                                }) catch common.oom();
                            }
                        }
                    }
                }

                // Codes 24..31
                for (0..8) |i| {
                    const key = trackWindow(
                        secondary_c,
                        secondary_dir,
                        secondary_p,
                        1,
                        i,
                    );

                    if (f.wire_map.get(key)) |src_idx| {
                        f.in_conns.append(f.alloc, .{
                            .code = @intCast(24 + i),
                            .sink = .{ .id = sink_idx, .kind = .sink },
                            .source = .{ .id = src_idx, .kind = .wire },
                            .switchCoord = null,
                        }) catch common.oom();
                    }
                }
            },
            // CE inputs
            .ce1, .ce2 => {
                // Codes 2..3
                for (&[2]u8{ 1, 3 }, &[2]u8{ 2, 3 }) |i, code| {
                    const src_idx = f.sources_map.get(.{
                        .tile = tile,
                        .index = i,
                    }).?;

                    f.in_conns.append(f.alloc, .{
                        .code = code,
                        .sink = .{ .id = sink_idx, .kind = .sink },
                        .source = .{ .id = src_idx, .kind = .source },
                        .switchCoord = null,
                    }) catch common.oom();
                }

                // Codes 4..31
                for (std.enums.values(common.Side), 0..4) |side, s_idx| {
                    // CW
                    for (0..4) |j| {
                        const key = trackWindow(
                            tile.channel(side, f.grid).?,
                            side.turnDir(.cw),
                            p,
                            4,
                            j,
                        );
                        const code: u8 = @intCast(4 + s_idx * 7 + j);

                        if (f.wire_map.get(key)) |src_idx| {
                            f.in_conns.append(f.alloc, .{
                                .code = code,
                                .sink = .{ .id = sink_idx, .kind = .sink },
                                .source = .{ .id = src_idx, .kind = .wire },
                                .switchCoord = null,
                            }) catch common.oom();
                        }
                    }

                    // CCW
                    for (0..3) |j| {
                        const key = trackWindow(
                            tile.channel(side, f.grid).?,
                            side.turnDir(.ccw),
                            p,
                            6,
                            j,
                        );
                        const code: u8 = @intCast(4 + s_idx * 7 + j + 4);

                        if (f.wire_map.get(key)) |src_idx| {
                            f.in_conns.append(f.alloc, .{
                                .code = code,
                                .sink = .{ .id = sink_idx, .kind = .sink },
                                .source = .{ .id = src_idx, .kind = .wire },
                                .switchCoord = null,
                            }) catch common.oom();
                        }
                    }
                }
            },
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
    // A1, A2, DI
    for (0..3) |tag_idx| {
        const width: usize = switch (tag_idx) {
            0, 1 => 12,
            2 => 16,
            else => unreachable,
        };

        for (0..width) |bus_idx| {
            const in = switch (tag_idx) {
                0 => common.BramInput{ .a1 = @intCast(bus_idx) },
                1 => common.BramInput{ .a2 = @intCast(bus_idx) },
                2 => common.BramInput{ .di = @intCast(bus_idx) },
                else => unreachable,
            };

            const sink_idx: u32 = @intCast(f.sinks.len);
            const in_start: u32 = @intCast(f.in_conns.len);

            const primary_edge: common.BigEdge = switch (in) {
                .a1 => |x| switch (x) {
                    0, 1 => .h0,
                    2 => .w0,
                    3 => .e0,
                    4 => .w1,
                    5 => .e1,
                    6 => .w2,
                    7 => .e2,
                    8 => .w3,
                    9 => .e3,
                    10, 11 => .h4,
                    else => unreachable,
                },
                .a2 => |x| switch (x) {
                    0, 1 => .h0,
                    2 => .w0,
                    3 => .e0,
                    4 => .w1,
                    5 => .e1,
                    6 => .w2,
                    7 => .e2,
                    8 => .w3,
                    9 => .e3,
                    10, 11 => .h4,
                    else => unreachable,
                },
                .di => |x| switch (x) {
                    0, 1 => .w0,
                    2, 3 => .e0,
                    4, 5 => .w1,
                    6, 7 => .e1,
                    8, 9 => .w2,
                    10, 11 => .e2,
                    12, 13 => .w3,
                    14, 15 => .e3,
                },
                .we1, .we2 => unreachable,
            };
            const primary_channel = tile.bigChannel(primary_edge, f.grid);

            const secondary_edge: common.BigEdge = switch (primary_edge) {
                .h0, .w0, .e0 => .h1,
                .w1, .e1, .w2, .e2 => .h2,
                .h4, .w3, .e3 => .h3,
                .h1, .h2, .h3 => unreachable,
            };
            const secondary_channel = tile.bigChannel(secondary_edge, f.grid);

            const d: usize = switch (primary_edge) {
                .h0, .w1, .w3 => 0,
                .w0, .e1, .e3 => 2,
                .e0, .w2, .h4 => 4,
                .e2 => 6,
                .h1, .h2, .h3 => unreachable,
            };

            const slot: u2 = switch (in) {
                .a1 => |x| switch (x) {
                    0 => 0,
                    1 => 2,
                    2, 3 => 0,
                    4, 5 => 1,
                    6, 7 => 2,
                    8, 9 => 3,
                    10 => 0,
                    11 => 2,
                    else => unreachable,
                },
                .a2 => |x| switch (x) {
                    0 => 1,
                    1 => 3,
                    2, 3 => 1,
                    4, 5 => 2,
                    6, 7 => 3,
                    8, 9 => 0,
                    10 => 1,
                    11 => 3,
                    else => unreachable,
                },
                .di => |x| switch (x) {
                    0, 2 => 2,
                    1, 3 => 3,
                    4, 6 => 3,
                    5, 7 => 0,
                    8, 10 => 0,
                    9, 11 => 1,
                    12, 14 => 1,
                    13, 15 => 2,
                },
                .we1, .we2 => unreachable,
            };

            const p: usize = switch (slot) {
                0, 1 => 0,
                2, 3 => 1,
            };

            const primary_dir: common.Direction = switch (slot) {
                0, 2 => primary_edge.side().?.turnDir(.cw),
                1, 3 => primary_edge.side().?.turnDir(.ccw),
            };
            const secondary_dir: common.Direction = switch (slot) {
                0, 2 => .right,
                1, 3 => .left,
            };

            // Codes 2..10
            for (std.enums.values(common.WireClass)) |class| {
                const count: usize = switch (class) {
                    .l1 => 3,
                    .l4 => 4,
                    .l16 => 2,
                };
                const code_start: u8 = switch (class) {
                    .l1 => 2,
                    .l4 => 5,
                    .l16 => 9,
                };

                for (0..count) |j| {
                    const key = TrackKey{
                        .channel = primary_channel,
                        .class = class,
                        .dir = primary_dir,
                        .track = @intCast(2 * j + p),
                    };
                    const code: u8 = @intCast(code_start + j);

                    if (f.wire_map.get(key)) |src_idx| {
                        f.in_conns.append(f.alloc, .{
                            .code = code,
                            .sink = .{ .id = sink_idx, .kind = .sink },
                            .source = .{ .id = src_idx, .kind = .wire },
                            .switchCoord = null,
                        }) catch common.oom();
                    }
                }
            }

            // Codes 11..15
            for (0..5) |j| {
                const key = trackWindow(
                    secondary_channel,
                    secondary_dir,
                    1 - p,
                    d,
                    j,
                );
                const code: u8 = @intCast(11 + j);

                if (f.wire_map.get(key)) |src_idx| {
                    f.in_conns.append(f.alloc, .{
                        .code = code,
                        .sink = .{ .id = sink_idx, .kind = .sink },
                        .source = .{ .id = src_idx, .kind = .wire },
                        .switchCoord = null,
                    }) catch common.oom();
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

    // WE1, WE2
    for (&[2]common.BramInput{ .we1, .we2 }) |in| {
        const p: usize = switch (in) {
            .a1, .a2, .di => unreachable,
            .we1 => 0,
            .we2 => 1,
        };

        const sink_idx: u32 = @intCast(f.sinks.len);
        const in_start: u32 = @intCast(f.in_conns.len);

        // Codes 2..31
        for (&[3]common.BigEdge{ .h1, .h2, .h3 }, 0..3) |be, be_idx| {
            for (&[2]common.Direction{ .left, .right }, 0..2) |dir, dir_idx| {
                for (0..5) |j| {
                    const key = trackWindow(
                        tile.bigChannel(be, f.grid),
                        dir,
                        p,
                        7,
                        j,
                    );
                    const code: u8 = @intCast(2 + 10 * be_idx + 5 * dir_idx + j);

                    if (f.wire_map.get(key)) |src_idx| {
                        f.in_conns.append(f.alloc, .{
                            .code = code,
                            .sink = .{ .id = sink_idx, .kind = .sink },
                            .source = .{ .id = src_idx, .kind = .wire },
                            .switchCoord = null,
                        }) catch common.oom();
                    }
                }
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
    // A, B, C
    for (0..3) |tag_idx| {
        const width: usize = switch (tag_idx) {
            0, 1 => 8,
            2 => 16,
            else => unreachable,
        };

        for (0..width) |bus_idx| {
            const in = switch (tag_idx) {
                0 => common.DspInput{ .a = @intCast(bus_idx) },
                1 => common.DspInput{ .b = @intCast(bus_idx) },
                2 => common.DspInput{ .c = @intCast(bus_idx) },
                else => unreachable,
            };

            const sink_idx: u32 = @intCast(f.sinks.len);
            const in_start: u32 = @intCast(f.in_conns.len);

            const primary_edge: common.BigEdge = switch (in) {
                .a => |x| switch (x) {
                    0 => .w0,
                    1 => .e0,
                    2 => .w1,
                    3 => .e1,
                    4 => .w2,
                    5 => .e2,
                    6 => .w3,
                    7 => .e3,
                },
                .b => |x| switch (x) {
                    0 => .w0,
                    1 => .e0,
                    2 => .w1,
                    3 => .e1,
                    4 => .w2,
                    5 => .e2,
                    6 => .w3,
                    7 => .e3,
                },
                .c => |x| switch (x) {
                    0, 1 => .w0,
                    2, 3 => .e0,
                    4, 5 => .w1,
                    6, 7 => .e1,
                    8, 9 => .w2,
                    10, 11 => .e2,
                    12, 13 => .w3,
                    14, 15 => .e3,
                },
                .ad, .md, .we => unreachable,
            };
            const primary_channel = tile.bigChannel(primary_edge, f.grid);

            const kind: u2 = switch (in) {
                .a => |x| switch (x) {
                    0 => 0,
                    1 => 3,
                    2 => 2,
                    3 => 1,
                    4 => 0,
                    5 => 3,
                    6 => 2,
                    7 => 1,
                },
                .b => |x| switch (x) {
                    0 => 2,
                    1 => 1,
                    2 => 0,
                    3 => 3,
                    4 => 2,
                    5 => 1,
                    6 => 0,
                    7 => 3,
                },
                .c => |x| switch (x) {
                    0, 4, 8, 12 => 1,
                    1, 5, 9, 13 => 3,
                    2, 6, 10, 14 => 0,
                    3, 7, 11, 15 => 2,
                },
                .ad, .md, .we => unreachable,
            };

            const p: usize = switch (kind) {
                0, 1 => 0,
                2, 3 => 1,
            };

            const secondary_edge: common.BigEdge = switch (kind) {
                0, 2 => switch (primary_edge) {
                    .w0, .e0 => .h0,
                    .w1, .e1 => .h1,
                    .w2, .e2 => .h2,
                    .w3, .e3 => .h3,
                    .h0, .h1, .h2, .h3, .h4 => unreachable,
                },
                1, 3 => switch (primary_edge) {
                    .w0, .e0 => .h1,
                    .w1, .e1 => .h2,
                    .w2, .e2 => .h3,
                    .w3, .e3 => .h4,
                    .h0, .h1, .h2, .h3, .h4 => unreachable,
                },
            };
            const secondary_channel = tile.bigChannel(secondary_edge, f.grid);
            const d: usize = switch (kind) {
                0, 2 => switch (primary_edge) {
                    .w0 => 0,
                    .e0, .w1, .w2, .w3 => 4,
                    .e1, .e2, .e3 => 6,
                    .h0, .h1, .h2, .h3, .h4 => unreachable,
                },
                1, 3 => switch (primary_edge) {
                    .w0, .w1, .w2, .w3 => 0,
                    .e0, .e1, .e2 => 2,
                    .e3 => 4,
                    .h0, .h1, .h2, .h3, .h4 => unreachable,
                },
            };

            // Codes 2..19
            for (std.enums.values(common.WireClass)) |class| {
                const count: usize = switch (class) {
                    .l1 => 3,
                    .l4 => 4,
                    .l16 => 2,
                };
                const code_start: u8 = switch (class) {
                    .l1 => 2,
                    .l4 => 8,
                    .l16 => 16,
                };
                for (std.enums.values(common.TurnOrientation), 0..2) |to, to_idx| {
                    const dir = primary_edge.side().?.turnDir(to);
                    for (0..count) |j| {
                        const key = TrackKey{
                            .channel = primary_channel,
                            .class = class,
                            .dir = dir,
                            .track = @intCast(2 * j + p),
                        };
                        const code: u8 = @intCast(code_start + to_idx * count + j);

                        if (f.wire_map.get(key)) |src_idx| {
                            f.in_conns.append(f.alloc, .{
                                .code = code,
                                .sink = .{ .id = sink_idx, .kind = .sink },
                                .source = .{ .id = src_idx, .kind = .wire },
                                .switchCoord = null,
                            }) catch common.oom();
                        }
                    }
                }
            }

            // Codes 20..31
            for (&[2]common.Direction{ .left, .right }, 0..2) |dir, dir_idx| {
                for (0..6) |j| {
                    const key = trackWindow(
                        secondary_channel,
                        dir,
                        1 - p,
                        d,
                        j,
                    );
                    const code: u8 = @intCast(20 + 6 * dir_idx + j);

                    if (f.wire_map.get(key)) |src_idx| {
                        f.in_conns.append(f.alloc, .{
                            .code = code,
                            .sink = .{ .id = sink_idx, .kind = .sink },
                            .source = .{ .id = src_idx, .kind = .wire },
                            .switchCoord = null,
                        }) catch common.oom();
                    }
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

    // MD, AD, DE
    for (&[3]common.DspInput{ .md, .ad, .we }) |in| {
        const sink_idx: u32 = @intCast(f.sinks.len);
        const in_start: u32 = @intCast(f.in_conns.len);

        // Codes 2..31
        for (&[3]common.BigEdge{ .h1, .h2, .h3 }, 0..3) |be, be_idx| {
            for (&[2]common.Direction{ .left, .right }, 0..2) |dir, dir_idx| {
                for (0..5) |j| {
                    const key = trackWindow(
                        tile.bigChannel(be, f.grid),
                        dir,
                        0,
                        7,
                        j,
                    );
                    const code: u8 = @intCast(2 + 10 * be_idx + 5 * dir_idx + j);

                    if (f.wire_map.get(key)) |src_idx| {
                        f.in_conns.append(f.alloc, .{
                            .code = code,
                            .sink = .{ .id = sink_idx, .kind = .sink },
                            .source = .{ .id = src_idx, .kind = .wire },
                            .switchCoord = null,
                        }) catch common.oom();
                    }
                }
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
        const p: usize = switch (in) {
            .o, .ie, .ee => 0,
            .e, .oe => 1,
        };

        const d: usize = switch (in) {
            .o, .e => 0,
            .ie => 3,
            .oe => 4,
            .ee => 6,
        };

        const sink_idx: u32 = @intCast(f.sinks.len);
        const in_start: u32 = @intCast(f.in_conns.len);

        // Codes 2..19
        for (std.enums.values(common.WireClass)) |class| {
            const count: usize = switch (class) {
                .l1 => 3,
                .l4 => 4,
                .l16 => 2,
            };
            const code_start: u8 = switch (class) {
                .l1 => 2,
                .l4 => 8,
                .l16 => 16,
            };
            for (std.enums.values(common.TurnOrientation), 0..2) |to, to_idx| {
                const dir = side.turnDir(to);
                for (0..count) |j| {
                    const key = TrackKey{
                        .channel = channel,
                        .class = class,
                        .dir = dir,
                        .track = @intCast(2 * j + p),
                    };
                    const code: u8 = @intCast(code_start + to_idx * count + j);

                    if (f.wire_map.get(key)) |src_idx| {
                        f.in_conns.append(f.alloc, .{
                            .code = code,
                            .sink = .{ .id = sink_idx, .kind = .sink },
                            .source = .{ .id = src_idx, .kind = .wire },
                            .switchCoord = null,
                        }) catch common.oom();
                    }
                }
            }
        }

        // Codes 20..31
        for (std.enums.values(common.TurnOrientation), 0..2) |to, to_idx| {
            const dir = side.turnDir(to);
            for (0..6) |j| {
                const code: u8 = @intCast(20 + to_idx * 6 + j);

                const key = trackWindow(channel, dir, @intCast(1 - p), d, j);
                if (f.wire_map.get(key)) |src_idx| {
                    f.in_conns.append(f.alloc, .{
                        .code = code,
                        .sink = .{ .id = sink_idx, .kind = .sink },
                        .source = .{ .id = src_idx, .kind = .wire },
                        .switchCoord = null,
                    }) catch common.oom();
                }
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
