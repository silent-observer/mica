//! Pure wire geometry, with no code tables in it. A segment is addressed two
//! ways - by *local track*, invariant along the segment and used by
//! switchboxes, and by *edge track*, its position in one channel and used by
//! connection boxes - and this file is the conversion between them.

const std = @import("std");
const common = @import("common.zig");

/// A wire segment, named by the switchbox that drives it. Local track numbering
/// is invariant along a segment, so this key is the same at both ends.
pub const WireKey = struct {
    start: common.SwitchCoords,
    dir: common.Direction,
    class: common.WireClass,
    track: common.SwitchTrack,
};

/// Edge track of the segment leaving `sw` on side `s`. Null when no such
/// segment starts here, which only happens for off-phase L16.
pub fn outgoingTrack(
    sw: common.SwitchCoords,
    s: common.Side,
    class: common.WireClass,
    switch_track: common.SwitchTrack,
) ?common.EdgeTrack {
    const n = switch (s.outDir().orientation()) {
        .horizontal => sw.col,
        .vertical => sw.row,
    };
    switch (class) {
        .l1 => return common.EdgeTrack.track(switch_track.int()),
        .l4 => return common.EdgeTrack.track(@intCast(2 * (n % 4) + switch_track.int())),
        .l16 => {
            if (n % 4 != 0) return null;
            return common.EdgeTrack.track(@intCast((n / 4) % 4));
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
    switch_track: common.SwitchTrack,
    grid: common.GridSize,
) ?common.EdgeTrack {
    const start = incomingStart(sw, s, class, grid) orelse return null;
    return outgoingTrack(start, s.opposite(), class, switch_track);
}

/// Inverse of `outgoingTrack`: the segment occupying `edge_track` of `channel`
/// travelling in `dir`. Connection boxes address wires by edge track, so this
/// is how a tile input resolves to the segment it taps.
pub fn segmentStart(
    channel: common.Channel,
    dir: common.Direction,
    class: common.WireClass,
    edge_track: common.EdgeTrack,
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
    const et: u32 = edge_track.int();

    // Residue the driving box must have for `outgoingTrack` to yield `edge_track`.
    const modulus: u32, const target: u32, const switch_track: u8 = switch (class) {
        .l1 => .{ 1, 0, edge_track.int() },
        .l4 => .{ 4, et / 2, edge_track.int() % 2 },
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
        .track = .track(switch_track),
    };
}

test "segmentStart inverts outgoingTrack along the whole span" {
    const grid = common.GridSize{ .rows = 50, .cols = 66 };
    for (std.enums.values(common.Direction)) |dir| {
        for (std.enums.values(common.WireClass)) |class| {
            for (0..grid.vertexRows()) |row| {
                for (0..grid.vertexCols()) |col| {
                    const start = common.SwitchCoords{
                        .row = @intCast(row),
                        .col = @intCast(col),
                    };
                    for (0..class.tracksPerSwitch()) |switch_track| {
                        const edge_track = outgoingTrack(
                            start,
                            dir.side(),
                            class,
                            .track(@intCast(switch_track)),
                        ) orelse continue;

                        const expected = WireKey{
                            .start = start,
                            .dir = dir,
                            .class = class,
                            .track = .track(@intCast(switch_track)),
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
            for (0..grid.vertexRows()) |row| {
                for (0..grid.vertexCols()) |col| {
                    const sw = common.SwitchCoords{
                        .row = @intCast(row),
                        .col = @intCast(col),
                    };
                    for (0..class.tracksPerSwitch()) |switch_track| {
                        const incoming = incomingTrack(
                            sw,
                            side,
                            class,
                            .track(@intCast(switch_track)),
                            grid,
                        ) orelse continue;
                        const start = incomingStart(sw, side, class, grid).?;

                        try std.testing.expectEqual(
                            incoming,
                            outgoingTrack(start, side.opposite(), class, .track(@intCast(switch_track))).?,
                        );
                    }
                }
            }
        }
    }
}
