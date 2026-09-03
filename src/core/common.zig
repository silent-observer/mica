const std = @import("std");

pub const TileType = enum {
    none,
    logic,
    bram,
    dsp,
    io,

    pub fn fromChar(c: u8) ?TileType {
        return switch (c) {
            'L' => .logic,
            'B' => .bram,
            'D' => .dsp,
            'I' => .io,
            else => null,
        };
    }
};

pub const Orientation = enum(u1) {
    vertical = 0,
    horizontal = 1,

    pub fn int(s: Orientation) u1 {
        return @intFromEnum(s);
    }

    pub fn dirAsc(o: Orientation) Direction {
        return switch (o) {
            .horizontal => .right,
            .vertical => .down,
        };
    }

    pub fn dirDesc(o: Orientation) Direction {
        return switch (o) {
            .horizontal => .left,
            .vertical => .up,
        };
    }
};

pub const TurnOrientation = enum(u1) {
    cw = 0,
    ccw = 1,

    pub fn int(s: TurnOrientation) u1 {
        return @intFromEnum(s);
    }
};

pub const Side = enum(u2) {
    n = 0,
    e = 1,
    s = 2,
    w = 3,

    pub fn int(s: Side) u2 {
        return @intFromEnum(s);
    }

    pub fn outDir(s: Side) Direction {
        return switch (s) {
            .n => .up,
            .e => .right,
            .s => .down,
            .w => .left,
        };
    }

    pub fn inDir(s: Side) Direction {
        return switch (s) {
            .n => .down,
            .e => .left,
            .s => .up,
            .w => .right,
        };
    }

    pub fn turnDir(s: Side, to: TurnOrientation) Direction {
        return switch (to) {
            .cw => switch (s) {
                .n => .right,
                .e => .down,
                .s => .left,
                .w => .up,
            },
            .ccw => switch (s) {
                .n => .left,
                .e => .up,
                .s => .right,
                .w => .down,
            },
        };
    }

    pub fn straight(s: Side) Side {
        return @enumFromInt(s.int() +% 2);
    }

    pub fn right(s: Side) Side {
        return @enumFromInt(s.int() +% 1);
    }

    pub fn left(s: Side) Side {
        return @enumFromInt(s.int() +% 3);
    }
};

pub const Corner = enum(u2) {
    nw = 0,
    ne = 1,
    se = 2,
    sw = 3,

    pub fn int(s: Corner) u2 {
        return @intFromEnum(s);
    }
};

pub const Direction = enum(u2) {
    up = 0,
    right = 1,
    down = 2,
    left = 3,

    pub fn int(s: Direction) u2 {
        return @intFromEnum(s);
    }

    pub fn orientation(s: Direction) Orientation {
        return switch (s) {
            .up, .down => .vertical,
            .left, .right => .horizontal,
        };
    }

    pub fn side(s: Direction) Side {
        return switch (s) {
            .up => .n,
            .right => .e,
            .down => .s,
            .left => .w,
        };
    }
};

pub const GridSize = struct {
    rows: u32,
    cols: u32,

    pub inline fn tileRows(grid: GridSize) u32 {
        return grid.rows - 2;
    }

    pub inline fn vertexRows(grid: GridSize) u32 {
        return grid.rows - 1;
    }

    pub inline fn tileCols(grid: GridSize) u32 {
        return grid.cols - 2;
    }

    pub inline fn vertexCols(grid: GridSize) u32 {
        return grid.cols - 1;
    }

    pub inline fn northIo(_: GridSize) u32 {
        return 0;
    }

    pub inline fn southIo(grid: GridSize) u32 {
        return grid.rows - 1;
    }

    pub inline fn westIo(_: GridSize) u32 {
        return 0;
    }

    pub inline fn eastIo(grid: GridSize) u32 {
        return grid.cols - 1;
    }

    pub inline fn edgeCount(grid: GridSize) u32 {
        return grid.tileRows() * grid.vertexCols() + grid.vertexRows() * grid.tileCols();
    }
};

pub const Channel = struct {
    orientation: Orientation,
    // Either tile coord or switch coord, depending on orientation
    row: u32,
    col: u32,

    // Two switches this channel connects, in ascending coordinate order
    pub fn switches(channel: Channel) [2]SwitchCoords {
        return switch (channel.orientation) {
            .vertical => .{
                SwitchCoords{
                    .row = channel.row - 1,
                    .col = channel.col,
                },
                SwitchCoords{
                    .row = channel.row,
                    .col = channel.col,
                },
            },
            .horizontal => .{
                SwitchCoords{
                    .row = channel.row,
                    .col = channel.col - 1,
                },
                SwitchCoords{
                    .row = channel.row,
                    .col = channel.col,
                },
            },
        };
    }

    // Two tiles this channel borders, in ascending coordinate order
    pub fn tiles(channel: Channel) [2]TileCoords {
        return switch (channel.orientation) {
            .vertical => .{
                TileCoords{
                    .row = channel.row,
                    .col = channel.col,
                },
                TileCoords{
                    .row = channel.row,
                    .col = channel.col + 1,
                },
            },
            .horizontal => .{
                TileCoords{
                    .row = channel.row,
                    .col = channel.col,
                },
                TileCoords{
                    .row = channel.row + 1,
                    .col = channel.col,
                },
            },
        };
    }
};

pub const WireClass = enum {
    l1,
    l4,
    l16,

    pub fn len(class: WireClass) u32 {
        return switch (class) {
            .l1 => 1,
            .l4 => 4,
            .l16 => 16,
        };
    }
};

pub const TileCoords = struct {
    row: u32, // 0 to grid.rows - 1
    col: u32, // 0 to grid.cols - 1

    pub fn channel(tile: TileCoords, side: Side, grid: GridSize) ?Channel {
        return switch (side) {
            .n => if (tile.row == 0) null else Channel{
                .orientation = .horizontal,
                .row = tile.row - 1,
                .col = tile.col,
            },
            .e => if (tile.col >= grid.cols - 1) null else Channel{
                .orientation = .vertical,
                .row = tile.row,
                .col = tile.col,
            },
            .s => if (tile.row >= grid.rows - 1) null else Channel{
                .orientation = .horizontal,
                .row = tile.row,
                .col = tile.col,
            },
            .w => if (tile.col == 0) null else Channel{
                .orientation = .vertical,
                .row = tile.row,
                .col = tile.col - 1,
            },
        };
    }

    pub fn bigChannel(tile0: TileCoords, be: BigEdge, grid: GridSize) Channel {
        std.debug.assert(tile0.row + 4 <= grid.rows - 1);
        const tile1 = TileCoords{
            .row = tile0.row + 1,
            .col = tile0.col,
        };
        const tile2 = TileCoords{
            .row = tile0.row + 2,
            .col = tile0.col,
        };
        const tile3 = TileCoords{
            .row = tile0.row + 3,
            .col = tile0.col,
        };

        return switch (be) {
            .h0 => tile0.channel(.n, grid).?,
            .h1 => tile1.channel(.n, grid).?,
            .h2 => tile2.channel(.n, grid).?,
            .h3 => tile3.channel(.n, grid).?,
            .h4 => tile3.channel(.s, grid).?,

            .w0 => tile0.channel(.w, grid).?,
            .w1 => tile1.channel(.w, grid).?,
            .w2 => tile2.channel(.w, grid).?,
            .w3 => tile3.channel(.w, grid).?,

            .e0 => tile0.channel(.e, grid).?,
            .e1 => tile1.channel(.e, grid).?,
            .e2 => tile2.channel(.e, grid).?,
            .e3 => tile3.channel(.e, grid).?,
        };
    }
};

pub const SwitchCoords = struct {
    row: u32, // 0 to grid.rows - 2
    col: u32, // 0 to grid.cols - 2

    pub fn channel(sw: SwitchCoords, d: Direction, grid: GridSize) ?Channel {
        return switch (d) {
            .up => if (sw.row == 0) null else Channel{
                .orientation = .vertical,
                .row = sw.row,
                .col = sw.col,
            },
            .right => if (sw.col >= grid.vertexCols() - 1) null else Channel{
                .orientation = .horizontal,
                .row = sw.row,
                .col = sw.col + 1,
            },
            .down => if (sw.row >= grid.vertexRows() - 1) null else Channel{
                .orientation = .vertical,
                .row = sw.row + 1,
                .col = sw.col,
            },
            .left => if (sw.col == 0) null else Channel{
                .orientation = .horizontal,
                .row = sw.row,
                .col = sw.col,
            },
        };
    }

    pub fn channelSide(sw: SwitchCoords, s: Side, grid: GridSize) ?Channel {
        // Always use outDir, because Channels are undirected
        return sw.channel(s.outDir(), grid);
    }

    pub fn tile(sw: SwitchCoords, corner: Corner) TileCoords {
        return switch (corner) {
            .nw => TileCoords{
                .row = sw.row,
                .col = sw.col,
            },
            .ne => TileCoords{
                .row = sw.row,
                .col = sw.col + 1,
            },
            .sw => TileCoords{
                .row = sw.row + 1,
                .col = sw.col,
            },
            .se => TileCoords{
                .row = sw.row + 1,
                .col = sw.col + 1,
            },
        };
    }

    pub fn move(sw: SwitchCoords, dir: Direction, grid: GridSize, step: u32) ?SwitchCoords {
        return switch (dir) {
            .up => if (sw.row < step) null else SwitchCoords{
                .row = sw.row - step,
                .col = sw.col,
            },
            .down => if (sw.row + step >= grid.vertexRows()) null else SwitchCoords{
                .row = sw.row + step,
                .col = sw.col,
            },
            .left => if (sw.col < step) null else SwitchCoords{
                .row = sw.row,
                .col = sw.col - step,
            },
            .right => if (sw.col + step >= grid.vertexCols()) null else SwitchCoords{
                .row = sw.row,
                .col = sw.col + step,
            },
        };
    }
};

pub const IoInput = enum(u8) {
    o = 0,
    e = 1,
    ie = 2,
    oe = 3,
    ee = 4,

    pub fn idx(in: IoInput) u8 {
        return @intFromEnum(in);
    }

    pub const TOTAL = 5;
};

pub const LogicInput = enum(u8) {
    a1 = 0,
    b1 = 1,
    c1 = 2,
    d1 = 3,
    ce1 = 4,
    a2 = 5,
    b2 = 6,
    c2 = 7,
    d2 = 8,
    ce2 = 9,

    pub fn idx(in: LogicInput) u8 {
        return @intFromEnum(in);
    }

    pub const TOTAL = 10;
};

pub const BramInput = union(enum) {
    a1: u4,
    a2: u4,
    di: u4,
    we1: void,
    we2: void,

    pub fn idx(in: BramInput) u8 {
        return switch (in) {
            .a1 => |i| @as(u8, i),
            .a2 => |i| @as(u8, i) + 12,
            .di => |i| @as(u8, i) + 24,
            .we1 => 40,
            .we2 => 41,
        };
    }

    pub const TOTAL = 12 + 12 + 16 + 2;
};

pub const DspInput = union(enum) {
    a: u3,
    b: u3,
    c: u4,
    md: void,
    ad: void,
    we: void,

    pub fn idx(in: DspInput) u8 {
        return switch (in) {
            .a => |i| @as(u8, i),
            .b => |i| @as(u8, i) + 8,
            .c => |i| @as(u8, i) + 16,
            .md => 32,
            .ad => 33,
            .we => 34,
        };
    }

    pub const TOTAL = 8 + 8 + 16 + 3;
};

pub const BIG_TILE_HEIGHT = 4;

pub const BigEdge = enum {
    h0,
    w0,
    e0,
    h1,
    w1,
    e1,
    h2,
    w2,
    e2,
    h3,
    w3,
    e3,
    h4,

    pub fn side(be: BigEdge) ?Side {
        return switch (be) {
            .h0 => .n,
            .w0, .w1, .w2, .w3 => .w,
            .e0, .e1, .e2, .e3 => .e,
            .h4 => .s,
            .h1, .h2, .h3 => null,
        };
    }
};

pub fn oom() noreturn {
    @panic("Out of memory!");
}
