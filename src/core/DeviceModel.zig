const std = @import("std");
const common = @import("common.zig");

pub const DeviceModel = @This();

model_id: []const u8,
grid: common.GridSize,
column_types: []const common.TileType,
switch_count: u32,
tile_counts: std.EnumArray(common.TileType, u32),

pub const mica1s = DeviceModel.build(
    "M1/S",
    50,
    66,
    "I 8L B 8L D 8L B 10L B 8L D 8L B 8L I",
);
pub const mica1m = DeviceModel.build(
    "M1/M",
    82,
    114,
    "I 9L B 9L D 9L B 9L D 9L B 12L B 9L D 9L B 9L D 9L B 9L I",
);
pub const mica1l = DeviceModel.build(
    "M1/L",
    130,
    178,
    "I 9L B 9L D 9L B 9L D 9L B 9L B 9L D 9L B 16L B 9L D 9L B 9L B 9L D 9L B 9L D 9L B 9L I",
);

fn build(
    comptime model_id: []const u8,
    comptime grid_rows: u32,
    comptime grid_cols: u32,
    comptime layout: []const u8,
) DeviceModel {
    // The largest layouts run well past the default comptime branch limit.
    @setEvalBranchQuota(100 * grid_cols);

    var columns: [grid_cols]common.TileType = undefined;
    var tile_counts: std.EnumArray(common.TileType, u32) = .initFill(0);

    {
        var i: usize = 0;
        var iter = std.mem.tokenizeScalar(u8, layout, ' ');
        while (iter.next()) |col_descr| {
            const num = if (std.ascii.isDigit(col_descr[0]))
                std.fmt.parseInt(usize, col_descr[0 .. col_descr.len - 1], 10) catch
                    @panic("Invalid layout format!")
            else
                1;

            const t = common.TileType.fromChar(col_descr[col_descr.len - 1]) orelse
                @panic("Invalid layout format!");

            for (0..num) |_| {
                columns[i] = t;
                i += 1;
            }

            const new_tiles = switch (t) {
                .logic => (grid_rows - 2) * num,
                .bram, .dsp => (grid_rows - 2) * num / common.BIG_TILE_HEIGHT,
                .io, .none => 0,
            };

            tile_counts.getPtr(t).* += new_tiles;
        }
    }

    tile_counts.getPtr(.none).* += 4;
    tile_counts.getPtr(.io).* += (grid_rows - 2) * 2 + (grid_cols - 2) * 2;

    const final_column_types = columns;

    return DeviceModel{
        .model_id = model_id,
        .grid = .{
            .rows = grid_rows,
            .cols = grid_cols,
        },
        .switch_count = (grid_rows - 1) * (grid_cols - 1),
        .column_types = &final_column_types,
        .tile_counts = tile_counts,
    };
}

pub fn pinCoord(m: *const DeviceModel, pin: usize) common.TileCoords {
    const hor_pins = m.grid.tileCols();
    const ver_pins = m.grid.tileRows();

    std.debug.assert(pin >= 1);
    std.debug.assert(pin <= m.tile_counts.get(.io));
    return if (pin <= hor_pins)
        common.TileCoords{
            .row = m.grid.northIo(),
            .col = @intCast(m.grid.westIo() + pin),
        }
    else if (pin <= hor_pins + ver_pins)
        common.TileCoords{
            .row = @intCast(m.grid.northIo() + pin - hor_pins),
            .col = m.grid.eastIo(),
        }
    else if (pin <= hor_pins * 2 + ver_pins)
        common.TileCoords{
            .row = m.grid.southIo(),
            .col = @intCast(m.grid.eastIo() - (pin - hor_pins - ver_pins)),
        }
    else if (pin <= hor_pins * 2 + ver_pins * 2)
        common.TileCoords{
            .row = @intCast(m.grid.southIo() - (pin - hor_pins * 2 - ver_pins)),
            .col = m.grid.westIo(),
        }
    else
        @panic("Invalid pin number!");
}

test "pinCoord" {
    const model = DeviceModel.mica1s;
    try std.testing.expectEqual(
        common.TileCoords{ .row = 0, .col = 1 },
        model.pinCoord(1),
    );
    try std.testing.expectEqual(
        common.TileCoords{ .row = 0, .col = 16 },
        model.pinCoord(16),
    );
    try std.testing.expectEqual(
        common.TileCoords{ .row = 0, .col = 32 },
        model.pinCoord(32),
    );
    try std.testing.expectEqual(
        common.TileCoords{ .row = 0, .col = 48 },
        model.pinCoord(48),
    );
    try std.testing.expectEqual(
        common.TileCoords{ .row = 26, .col = 65 },
        model.pinCoord(90),
    );
    try std.testing.expectEqual(
        common.TileCoords{ .row = 49, .col = 48 },
        model.pinCoord(129),
    );
    try std.testing.expectEqual(
        common.TileCoords{ .row = 49, .col = 16 },
        model.pinCoord(161),
    );
    try std.testing.expectEqual(
        common.TileCoords{ .row = 25, .col = 0 },
        model.pinCoord(200),
    );
}
