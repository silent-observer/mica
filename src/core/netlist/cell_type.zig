const std = @import("std");
const common = @import("../common.zig");

pub const Kind = enum { physical, logical };

pub const Full = union(Kind) {
    physical: Physical,
    logical: Logical,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self) {
            .physical => |t| try writer.writeAll(Physical.names.get(t)),
            .logical => |t| try writer.print("${s}", .{@tagName(t)}),
        }
    }
};

pub const Physical = enum {
    lut4,
    lut3,
    ff,
    carry,
    mem,
    mem_dual,
    bram,
    bram_dual,
    dsp,
    dsp_acc,
    io,

    pub const names = blk: {
        var r: std.EnumArray(Physical, []const u8) = .initUndefined();
        for (std.enums.values(Physical)) |t|
            r.set(t, common.upper(@tagName(t)));
        break :blk r;
    };

    pub const lookup: std.StaticStringMap(Physical) = .initComptime(blk: {
        const phys = std.enums.values(Physical);
        var entries: [phys.len]struct { []const u8, Physical } = undefined;
        for (phys, &entries) |t, *entry|
            entry.* = .{ names.get(t), t };
        break :blk entries;
    });

    pub const ParamsUnion = union(Physical) {
        lut4: struct { lut: ?u16 = null },
        lut3: struct { lut: ?u8 = null },
        ff: struct {},
        carry: struct { lut_p: ?u8 = null, lut_g: ?u8 = null },
        mem: struct { init: ?u32 = null },
        mem_dual: struct { init0: ?u16 = null, init1: ?u16 = null },
        bram: BramParams,
        bram_dual: BramParams,
        dsp: DspParams,
        dsp_acc: DspParams,
        io: struct { pin: ?u16 = null, pullup: ?bool = null, pulldown: ?bool = null },

        const BramParams = struct { width: ?common.BramWidth = null };
        const DspParams = struct { signed_a: ?bool = null, signed_b: ?bool = null };
    };
};

pub const Logical = enum {
    add,
    sub,
    mul,
    mux,
    decode,
    @"and",
    @"or",
    xor,
    not,
    and_all,
    or_all,
    xor_all,
    ff,
    rom,
    rom_dual,
    ram,
    ram_dual,

    pub const ParamsUnion = union(Logical) {
        add: WidthOnlyParams,
        sub: WidthOnlyParams,
        mul: struct { width: ?u16 = null, signed_a: ?bool = null, signed_b: ?bool = null },
        mux: struct { width: ?u16 = null, depth: ?u4 = null },
        decode: struct { depth: ?u4 = null },
        @"and": WidthOnlyParams,
        @"or": WidthOnlyParams,
        xor: WidthOnlyParams,
        not: WidthOnlyParams,
        and_all: NOnlyParams,
        or_all: NOnlyParams,
        xor_all: NOnlyParams,
        ff: WidthOnlyParams,
        rom: MemoryParams,
        rom_dual: MemoryParams,
        ram: MemoryParams,
        ram_dual: MemoryParams,

        const WidthOnlyParams = struct { width: ?u16 = null };
        const NOnlyParams = struct { n: ?u16 = null };
        const MemoryParams = struct { data_width: ?u16 = null, addr_width: ?u16 = null };
    };

    pub fn Params(comptime t: Logical) type {
        return @FieldType(ParamsUnion, @tagName(t));
    }

    pub const lookup: std.StaticStringMap(Logical) = .initComptime(blk: {
        const logi = std.enums.values(Logical);
        var entries: [logi.len]struct { []const u8, Logical } = undefined;
        for (logi, &entries) |t, *entry|
            entry.* = .{ @tagName(t), t };
        break :blk entries;
    });
};
