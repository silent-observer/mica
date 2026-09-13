const std = @import("std");
const common = @import("common.zig");
const DeviceModel = @import("DeviceModel.zig");

pub const Configuration = @This();

model: DeviceModel,
global: Global,
switches: []Switch,
logic: []Logic,
bram: []Bram,
bram_data: []Bram.Data,
dsp: []Dsp,
io: []Io,

pub const Global = struct {
    clk_enable: [8]bool,
    rst_enable: [4]bool,
    reserved: u4,
};

pub const Logic = struct {
    carry: bool,
    mem: bool,
    mem_dual: bool,
    cin_src: CinSource,
    frac1: bool,
    frac2: bool,
    lut1: u16,
    lut2: u16,
    regs: [2]Reg,

    inputs: std.EnumArray(common.LogicInput, u5),

    pub const CinSource = enum(u2) {
        zero,
        one,
        input,
        above,
    };

    pub const Reg = struct {
        reg: bool,
        clk: u3,
        rst_en: bool,
        rst: u2,
    };
};

pub const Bram = struct {
    width: common.BramWidth,
    clk: u3,

    a1: [12]u4,
    a2: [12]u4,
    di: [16]u4,
    we1: u5,
    we2: u5,

    pub const Data = struct {
        data: [256]u16,

        pub fn get(data: *const Data, comptime T: type, addr: usize) T {
            if (T == u16)
                return data.data[addr];

            std.debug.assert(@typeInfo(T) == .int);
            const bit_width = @typeInfo(T).int.bits;
            const mask: u16 = (@as(u16, 1) << bit_width) - 1;

            const word_idx = (addr * bit_width) / 16;
            const bit_idx: u4 = @intCast(16 - bit_width - (addr * bit_width) % 16);
            return @intCast((data.data[word_idx] >> bit_idx) & mask);
        }

        pub fn set(data: *Data, comptime T: type, addr: usize, x: T) void {
            if (T == u16) {
                data.data[addr] = x;
                return;
            }

            std.debug.assert(@typeInfo(T) == .int);
            const bit_width = @typeInfo(T).int.bits;
            const mask: u16 = (@as(u16, 1) << bit_width) - 1;

            const word_idx = (addr * bit_width) / 16;
            const bit_idx: u4 = @intCast(16 - bit_width - (addr * bit_width) % 16);

            const old = data.data[word_idx] & ~(mask << bit_idx);
            const new = @as(u16, x) << bit_idx;
            data.data[word_idx] = old | new;
        }

        /// Sink for `CommonParser.parseRamData`. The entries arrive in
        /// big-endian byte slots and get packed back down to `data_width`
        /// bits, which is the whole difference between this and the netlist's
        /// `MemData`: a BRAM tile is 4096 bits however it is divided up.
        ///
        /// `width` is the plain 1/2/4/8/16, not a `BramWidth`, because an
        /// out-of-range `WIDTH = code N;` leaves the enum holding a raw code
        /// while the data is still read as 16 bits wide.
        pub fn sink(data: *Data, width: u8) Sink {
            return .{ .data = data, .width = width };
        }

        pub const Sink = struct {
            data: *Data,
            width: u8,

            /// Always false: the bitstream's `data {}` has no union rule, a
            /// repeated address simply overwrites.
            pub fn setSlot(s: Sink, addr: u32, bytes: []const u8) bool {
                const x = std.mem.readVarInt(u16, bytes, .big);
                switch (s.width) {
                    1 => s.data.set(u1, addr, @intCast(x)),
                    2 => s.data.set(u2, addr, @intCast(x)),
                    4 => s.data.set(u4, addr, @intCast(x)),
                    8 => s.data.set(u8, addr, @intCast(x)),
                    16 => s.data.set(u16, addr, x),
                    else => unreachable,
                }
                return false;
            }
        };

        pub fn getChunk(
            data: *const Data,
            offset: usize,
            comptime T: type,
            comptime n: usize,
        ) [n]T {
            var result: [n]T = undefined;
            for (0..n) |i|
                result[i] = data.get(T, offset + i);
            return result;
        }
    };
};

pub const Dsp = struct {
    signed_a: bool,
    signed_b: bool,
    acc: bool,
    clk: u3,
    rst_en: bool,
    rst: u2,

    a: [8]u5,
    b: [8]u5,
    c: [16]u5,
    md: u5,
    ad: u5,
    we: u5,
};

pub const Io = struct {
    reg_i: bool,
    reg_o: bool,
    pullup: bool,
    pulldown: bool,
    clk: u3,
    rst_en: bool,
    rst: u2,

    inputs: std.EnumArray(common.IoInput, u5),
};

pub const Switch = struct {
    sides: std.EnumArray(common.Side, PerSide),

    pub const PerSide = struct {
        l1: [6]u4,
        l4: [2]u4,
        l16: u4,
    };
};

pub fn init(model: DeviceModel, alloc: std.mem.Allocator) Configuration {
    const switches = alloc.alloc(Switch, model.switch_count) catch common.oom();
    const logic = alloc.alloc(Logic, model.tile_counts.get(.logic)) catch common.oom();
    const bram = alloc.alloc(Bram, model.tile_counts.get(.bram)) catch common.oom();
    const bram_data = alloc.alloc(Bram.Data, model.tile_counts.get(.bram)) catch common.oom();
    const dsp = alloc.alloc(Dsp, model.tile_counts.get(.dsp)) catch common.oom();
    const io = alloc.alloc(Io, model.tile_counts.get(.io)) catch common.oom();

    @memset(switches, std.mem.zeroes(Switch));
    @memset(logic, std.mem.zeroes(Logic));
    @memset(bram, std.mem.zeroes(Bram));
    @memset(bram_data, std.mem.zeroes(Bram.Data));
    @memset(dsp, std.mem.zeroes(Dsp));
    @memset(io, std.mem.zeroes(Io));

    return Configuration{
        .model = model,
        .global = std.mem.zeroes(Global),
        .switches = switches,
        .logic = logic,
        .bram = bram,
        .bram_data = bram_data,
        .dsp = dsp,
        .io = io,
    };
}

pub fn deinit(c: Configuration, alloc: std.mem.Allocator) void {
    alloc.free(c.switches);
    alloc.free(c.logic);
    alloc.free(c.bram);
    alloc.free(c.bram_data);
    alloc.free(c.dsp);
    alloc.free(c.io);
}

pub fn For(comptime t: common.TileType) type {
    return switch (t) {
        .inert => @compileError("inert tiles carry no configuration"),
        .logic => Logic,
        .bram => Bram,
        .dsp => Dsp,
        .io => Io,
    };
}

// The two tile-input storage shapes, in one place because the parser and the
// emitter have to agree on them: LogicInput / IoInput index a flat EnumArray,
// while BramInput / DspInput name one field per tag with the array index in
// the payload.
pub fn getInput(cfg: anytype, in: anytype) u5 {
    switch (@typeInfo(@TypeOf(in))) {
        .@"enum" => return cfg.inputs.get(in),
        .@"union" => switch (in) {
            inline else => |idx, tag| {
                const f = &@field(cfg, @tagName(tag));
                if (@TypeOf(idx) == void)
                    return f.*
                else
                    return f[idx];
            },
        },
        else => @compileError("bad Input type: " ++ @typeName(@TypeOf(in))),
    }
}

pub fn setInput(cfg: anytype, in: anytype, code: u5) void {
    switch (@typeInfo(@TypeOf(in))) {
        .@"enum" => cfg.inputs.set(in, code),
        .@"union" => switch (in) {
            inline else => |idx, tag| {
                const f = &@field(cfg, @tagName(tag));
                if (@TypeOf(idx) == void)
                    f.* = @intCast(code)
                else
                    f[idx] = @intCast(code);
            },
        },
        else => @compileError("bad Input type: " ++ @typeName(@TypeOf(in))),
    }
}

pub fn getSwitch(c: *const Configuration, sw: common.SwitchCoords) *Switch {
    const idx = sw.row + sw.col * c.model.grid.vertexRows();
    return &c.switches[idx];
}

pub fn getBramData(c: *const Configuration, tile: common.TileCoords) *Bram.Data {
    const row = (tile.row - 1) / 4;
    const col = c.model.column_indexes[tile.col];
    const idx = row + col * c.model.grid.tileRows() / 4;
    return &c.bram_data[idx];
}

pub fn get(c: *const Configuration, comptime t: common.TileType, tile: common.TileCoords) *For(t) {
    return switch (t) {
        .inert => @compileError("inert tiles carry no configuration"),
        .logic => c.getLogic(tile),
        .bram => c.getBram(tile),
        .dsp => c.getDsp(tile),
        .io => c.getIo(tile),
    };
}

pub fn getLogic(c: *const Configuration, tile: common.TileCoords) *Logic {
    const row = tile.row - 1;
    const col = c.model.column_indexes[tile.col];
    const idx = row + col * c.model.grid.tileRows();
    return &c.logic[idx];
}

pub fn getBram(c: *const Configuration, tile: common.TileCoords) *Bram {
    const row = (tile.row - 1) / 4;
    const col = c.model.column_indexes[tile.col];
    const idx = row + col * c.model.grid.tileRows() / 4;
    return &c.bram[idx];
}

pub fn getDsp(c: *const Configuration, tile: common.TileCoords) *Dsp {
    const row = (tile.row - 1) / 4;
    const col = c.model.column_indexes[tile.col];
    const idx = row + col * c.model.grid.tileRows() / 4;
    return &c.dsp[idx];
}

pub fn getIo(c: *const Configuration, tile: common.TileCoords) *Io {
    const idx =
        if (tile.col == c.model.grid.westIo())
            tile.row - 1
        else if (tile.row == c.model.grid.northIo())
            c.model.grid.tileRows() + (tile.col - 1) * 2
        else if (tile.row == c.model.grid.southIo())
            c.model.grid.tileRows() + (tile.col - 1) * 2 + 1
        else if (tile.col == c.model.grid.eastIo())
            c.model.grid.tileRows() + 2 * c.model.grid.tileCols() + (tile.row - 1)
        else
            unreachable;

    return &c.io[idx];
}
