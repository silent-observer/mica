const std = @import("std");

pub const TileType = enum {
    inert,
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

    pub fn big(t: TileType) bool {
        return switch (t) {
            .inert, .logic, .io => false,
            .bram, .dsp => true,
        };
    }

    pub fn carriesConfig(t: TileType, tile: TileCoords) bool {
        return !t.big() or (tile.row - 1) % 4 == 0;
    }

    pub fn Input(t: TileType) type {
        return switch (t) {
            .inert => @compileError("inert tiles carry no configuration"),
            .logic => LogicInput,
            .bram => BramInput,
            .dsp => DspInput,
            .io => IoInput,
        };
    }

    pub const configurable = [_]TileType{ .logic, .bram, .dsp, .io };
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

    pub const opposite = straight;
    pub fn straight(s: Side) Side {
        return @enumFromInt(s.int() +% 2);
    }

    pub fn right(s: Side) Side {
        return @enumFromInt(s.int() +% 1);
    }

    pub fn left(s: Side) Side {
        return @enumFromInt(s.int() +% 3);
    }

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self) {
            .n => try writer.writeAll("N"),
            .e => try writer.writeAll("E"),
            .s => try writer.writeAll("S"),
            .w => try writer.writeAll("W"),
        }
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

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self) {
            .nw => try writer.writeAll("NW"),
            .ne => try writer.writeAll("NE"),
            .se => try writer.writeAll("SE"),
            .sw => try writer.writeAll("SW"),
        }
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

    pub fn opposite(s: Direction) Direction {
        return @enumFromInt(s.int() +% 2);
    }

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self) {
            .up => try writer.writeAll("U"),
            .right => try writer.writeAll("R"),
            .down => try writer.writeAll("D"),
            .left => try writer.writeAll("L"),
        }
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

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self) {
            .l1 => try writer.writeAll("L1"),
            .l4 => try writer.writeAll("L4"),
            .l16 => try writer.writeAll("L16"),
        }
    }

    pub fn tracksPerSwitch(class: WireClass) u8 {
        return switch (class) {
            .l1 => 6,
            .l4 => 2,
            .l16 => 1,
        };
    }
    pub fn tracksPerEdge(class: WireClass) u8 {
        return switch (class) {
            .l1 => 6,
            .l4 => 8,
            .l16 => 4,
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

/// Track number from the perspective of a switchbox
pub const SwitchTrack = enum(u8) {
    _,
    pub fn int(t: SwitchTrack) u8 {
        return @intFromEnum(t);
    }
    pub fn track(i: u8) SwitchTrack {
        return @enumFromInt(i);
    }
};
/// Track number from the perspective of an edge, input connection boxes use this
pub const EdgeTrack = enum(u8) {
    _,
    pub fn int(t: EdgeTrack) u8 {
        return @intFromEnum(t);
    }
    pub fn track(i: u8) EdgeTrack {
        return @enumFromInt(i);
    }
};

pub const SwitchWire = struct {
    side: Side,
    class: WireClass,
    track: SwitchTrack,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print(
            "{f}.{f}[{}]",
            .{ self.side, self.class, self.track.int() },
        );
    }
};

pub const DirectionalWire1x1 = struct {
    side: Side,
    dir: Direction,
    class: WireClass,
    track: EdgeTrack,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print(
            "{f}[{f}].{f}[{}]",
            .{ self.side, self.dir, self.class, self.track.int() },
        );
    }
};

pub const DirectionalWire4x1 = struct {
    side: BigEdge,
    dir: Direction,
    class: WireClass,
    track: EdgeTrack,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print(
            "{f}[{f}].{f}[{}]",
            .{ self.side, self.dir, self.class, self.track.int() },
        );
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

    pub fn fromIdx(i: u8) IoInput {
        return @enumFromInt(i);
    }

    // Need to know the wired edge side to fully place the inputs
    pub const Cxt = Side;
    pub const WIDTHS: std.EnumArray(IoInput, usize) = .init(.{
        .o = 1,
        .e = 1,
        .ie = 1,
        .oe = 1,
        .ee = 1,
    });
    pub const TOTAL = 5;

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self) {
            .o => try writer.writeAll("O"),
            .e => try writer.writeAll("E"),
            .ie => try writer.writeAll("IE"),
            .oe => try writer.writeAll("OE"),
            .ee => try writer.writeAll("EE"),
        }
    }
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

    pub fn fromIdx(i: u8) LogicInput {
        return @enumFromInt(i);
    }

    pub const Cxt = void;
    pub const WIDTHS: std.EnumArray(LogicInput, usize) = .init(.{
        .a1 = 1,
        .b1 = 1,
        .c1 = 1,
        .d1 = 1,
        .ce1 = 1,
        .a2 = 1,
        .b2 = 1,
        .c2 = 1,
        .d2 = 1,
        .ce2 = 1,
    });
    pub const TOTAL = 10;

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self) {
            .a1 => try writer.writeAll("A1"),
            .b1 => try writer.writeAll("B1"),
            .c1 => try writer.writeAll("C1"),
            .d1 => try writer.writeAll("D1"),
            .ce1 => try writer.writeAll("CE1"),
            .a2 => try writer.writeAll("A2"),
            .b2 => try writer.writeAll("B2"),
            .c2 => try writer.writeAll("C2"),
            .d2 => try writer.writeAll("D2"),
            .ce2 => try writer.writeAll("CE2"),
        }
    }
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

    pub fn fromIdx(i: u8) BramInput {
        return switch (i) {
            0...11 => .{ .a1 = @intCast(i) },
            12...23 => .{ .a2 = @intCast(i - 12) },
            24...39 => .{ .di = @intCast(i - 24) },
            40 => .we1,
            41 => .we2,
            else => @panic("BramInput index out of range!"),
        };
    }

    pub fn A1(x: u4) BramInput {
        return .{ .a1 = x };
    }
    pub fn A2(x: u4) BramInput {
        return .{ .a2 = x };
    }
    pub fn DI(x: u4) BramInput {
        return .{ .di = x };
    }

    pub const Cxt = void;
    pub const WIDTHS: std.EnumArray(std.meta.Tag(BramInput), usize) = .init(.{
        .a1 = 12,
        .a2 = 12,
        .di = 16,
        .we1 = 1,
        .we2 = 1,
    });
    pub const TOTAL = 12 + 12 + 16 + 1 + 1;

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self) {
            .a1 => |x| try writer.print("A1[{}]", .{x}),
            .a2 => |x| try writer.print("A2[{}]", .{x}),
            .di => |x| try writer.print("DI[{}]", .{x}),
            .we1 => try writer.writeAll("WE1"),
            .we2 => try writer.writeAll("WE2"),
        }
    }
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

    pub fn fromIdx(i: u8) DspInput {
        return switch (i) {
            0...7 => .{ .a = @intCast(i) },
            8...15 => .{ .b = @intCast(i - 8) },
            16...31 => .{ .c = @intCast(i - 16) },
            32 => .md,
            33 => .ad,
            34 => .we,
            else => @panic("DspInput index out of range!"),
        };
    }

    pub fn A(x: u3) DspInput {
        return .{ .a = x };
    }
    pub fn B(x: u3) DspInput {
        return .{ .b = x };
    }
    pub fn C(x: u4) DspInput {
        return .{ .c = x };
    }

    pub const Cxt = void;
    pub const WIDTHS: std.EnumArray(std.meta.Tag(DspInput), usize) = .init(.{
        .a = 8,
        .b = 8,
        .c = 16,
        .md = 1,
        .ad = 1,
        .we = 1,
    });
    pub const TOTAL = 8 + 8 + 16 + 3;

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self) {
            .a => |x| try writer.print("A[{}]", .{x}),
            .b => |x| try writer.print("B[{}]", .{x}),
            .c => |x| try writer.print("C[{}]", .{x}),
            .md => try writer.writeAll("MD"),
            .ad => try writer.writeAll("AD"),
            .we => try writer.writeAll("WE"),
        }
    }
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

    pub fn orientation(be: BigEdge) Orientation {
        return switch (be) {
            .h0, .h1, .h2, .h3, .h4 => .horizontal,
            .w0, .w1, .w2, .w3, .e0, .e1, .e2, .e3 => .vertical,
        };
    }

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self) {
            .h0 => try writer.writeAll("H0"),
            .h1 => try writer.writeAll("H1"),
            .h2 => try writer.writeAll("H2"),
            .h3 => try writer.writeAll("H3"),
            .h4 => try writer.writeAll("H4"),

            .w0 => try writer.writeAll("W0"),
            .w1 => try writer.writeAll("W1"),
            .w2 => try writer.writeAll("W2"),
            .w3 => try writer.writeAll("W3"),

            .e0 => try writer.writeAll("E0"),
            .e1 => try writer.writeAll("E1"),
            .e2 => try writer.writeAll("E2"),
            .e3 => try writer.writeAll("E3"),
        }
    }
};

pub fn oom() noreturn {
    @panic("Out of memory!");
}
