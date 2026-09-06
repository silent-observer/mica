const std = @import("std");
const common = @import("common.zig");

/// A wire segment, named by the switchbox that drives it. Local track numbering
/// is invariant along a segment, so this key is the same at both ends.
pub const WireKey = struct {
    start: common.SwitchCoords,
    dir: common.Direction,
    class: common.WireClass,
    local_track: u8,
};

/// Edge track of the segment leaving `sw` on side `s`. Null when no such
/// segment starts here, which only happens for off-phase L16.
pub fn outgoingTrack(
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

/// Switchbox driving the segment that `sw` reads on side `s`. Null when that
/// box is off the grid, i.e. the segment is truncated and has no switchbox
/// connection at this end.
pub fn incomingStart(
    sw: common.SwitchCoords,
    s: common.Side,
    class: common.WireClass,
    grid: common.GridSize,
) ?common.SwitchCoords {
    return sw.move(s.outDir(), grid, class.len());
}

/// Edge track of the segment `sw` reads on side `s`.
pub fn incomingTrack(
    sw: common.SwitchCoords,
    s: common.Side,
    class: common.WireClass,
    local_track: usize,
    grid: common.GridSize,
) ?u8 {
    const start = incomingStart(sw, s, class, grid) orelse return null;
    return outgoingTrack(start, s.opposite(), class, local_track);
}

/// Inverse of `outgoingTrack`: the segment occupying `edge_track` of `channel`
/// travelling in `dir`. Connection boxes address wires by edge track, so this
/// is how a tile input resolves to the segment it taps.
pub fn segmentStart(
    channel: common.Channel,
    dir: common.Direction,
    class: common.WireClass,
    edge_track: u8,
    grid: common.GridSize,
) ?WireKey {
    const asc = dir == channel.orientation.dirAsc();

    // The box the segment passes through immediately before crossing `channel`.
    const first: common.SwitchCoords = switch (channel.orientation) {
        .vertical => blk: {
            if (asc and channel.row == 0) return null;
            break :blk .{
                .row = if (asc) channel.row - 1 else channel.row,
                .col = channel.col,
            };
        },
        .horizontal => blk: {
            if (asc and channel.col == 0) return null;
            break :blk .{
                .row = channel.row,
                .col = if (asc) channel.col - 1 else channel.col,
            };
        },
    };
    if (first.row >= grid.vertexRows() or first.col >= grid.vertexCols())
        return null;

    const n = switch (channel.orientation) {
        .vertical => first.row,
        .horizontal => first.col,
    };
    const et: u32 = edge_track;

    // Residue the driving box must have for `outgoingTrack` to yield `edge_track`.
    const modulus: u32, const target: u32, const local_track: u8 = switch (class) {
        .l1 => .{ 1, 0, edge_track },
        .l4 => .{ 4, et / 2, edge_track % 2 },
        .l16 => .{ 16, 4 * et, 0 },
    };

    // Stepping upstream lowers the coordinate for an ascending wire and raises
    // it for a descending one, so the two differ in sign.
    const back = if (asc)
        (n + modulus - target) % modulus
    else
        (target + modulus - n % modulus) % modulus;

    const start = first.move(dir.opposite(), grid, back) orelse return null;
    return WireKey{
        .start = start,
        .dir = dir,
        .class = class,
        .local_track = local_track,
    };
}

test "segmentStart inverts outgoingTrack along the whole span" {
    const grid = common.GridSize{ .rows = 50, .cols = 66 };
    for (std.enums.values(common.Direction)) |dir| {
        for (std.enums.values(common.WireClass)) |class| {
            const local_track_count: u8 = switch (class) {
                .l1 => 6,
                .l4 => 2,
                .l16 => 1,
            };
            for (0..grid.vertexRows()) |row| {
                for (0..grid.vertexCols()) |col| {
                    const start = common.SwitchCoords{
                        .row = @intCast(row),
                        .col = @intCast(col),
                    };
                    for (0..local_track_count) |local_track| {
                        const edge_track = outgoingTrack(
                            start,
                            dir.side(),
                            class,
                            local_track,
                        ) orelse continue;

                        const expected = WireKey{
                            .start = start,
                            .dir = dir,
                            .class = class,
                            .local_track = @intCast(local_track),
                        };

                        var sw = start;
                        for (0..class.len()) |_| {
                            const channel = sw.channel(dir, grid) orelse break;
                            try std.testing.expectEqual(
                                expected,
                                segmentStart(channel, dir, class, edge_track, grid).?,
                            );
                            sw = sw.move(dir, grid, 1) orelse break;
                        }
                    }
                }
            }
        }
    }
}

test "local track is invariant along a segment" {
    const grid = common.GridSize{ .rows = 50, .cols = 66 };
    for (std.enums.values(common.Side)) |side| {
        for (std.enums.values(common.WireClass)) |class| {
            const local_track_count: u8 = switch (class) {
                .l1 => 6,
                .l4 => 2,
                .l16 => 1,
            };
            for (0..grid.vertexRows()) |row| {
                for (0..grid.vertexCols()) |col| {
                    const sw = common.SwitchCoords{
                        .row = @intCast(row),
                        .col = @intCast(col),
                    };
                    for (0..local_track_count) |local_track| {
                        const incoming = incomingTrack(
                            sw,
                            side,
                            class,
                            local_track,
                            grid,
                        ) orelse continue;
                        const start = incomingStart(sw, side, class, grid).?;

                        try std.testing.expectEqual(
                            incoming,
                            outgoingTrack(start, side.opposite(), class, local_track).?,
                        );
                    }
                }
            }
        }
    }
}
