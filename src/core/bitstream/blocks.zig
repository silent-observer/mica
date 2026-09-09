const std = @import("std");
const common = @import("../common.zig");
const Configuration = @import("../Configuration.zig");

pub const Metadata = struct {
    tile: ?common.TileType = null,
    Config: type,
    table: []const Field,

    // Only actual tiles can have inputs
    pub fn hasInputs(m: Metadata) bool {
        return m.tile != null;
    }

    pub fn name(m: Metadata) []const u8 {
        if (m.tile) |t| return @tagName(t);

        return switch (m.Config) {
            Configuration.Global => "global",
            Configuration.Logic.Reg => "reg",
            else => @compileError("Invalid metadata with Config = " ++ @typeName(m.Config)),
        };
    }
};

pub const global = Metadata{
    .Config = Configuration.Global,
    .table = &global_table,
};
pub const reg = Metadata{
    .Config = Configuration.Logic.Reg,
    .table = &reg_table,
};

fn tableFor(comptime t: common.TileType) []const Field {
    return switch (t) {
        .logic => &logic_table,
        .bram => &bram_table,
        .dsp => &dsp_table,
        .io => &io_table,
        .inert => @compileError("inert tiles carry no configuration"),
    };
}

pub fn forTile(comptime t: common.TileType) Metadata {
    return .{
        .tile = t,
        .Config = Configuration.For(t),
        .table = tableFor(t),
    };
}

pub const ValueKind = union(enum) {
    bit: void,
    bin: type,
    hex: type,
    clk: void,
    rst: void,
    cin_src: void,
    reg: void,
    data: void,
    width: void,
};

pub const Field = struct {
    word: []const u8,
    width: usize = 1,
    field: []const u8,
    kind: ValueKind,
};

pub const global_table = [_]Field{
    .{
        .word = "CLK_PIN_ENABLE",
        .width = 8,
        .field = "clk_enable",
        .kind = .bit,
    },
    .{
        .word = "RST_PIN_ENABLE",
        .width = 4,
        .field = "rst_enable",
        .kind = .bit,
    },
    .{
        .word = "RESERVED",
        .field = "reserved",
        .kind = .{ .bin = u4 },
    },
};

pub const logic_table = [_]Field{
    .{
        .word = "CARRY",
        .field = "carry",
        .kind = .bit,
    },
    .{
        .word = "MEM",
        .field = "mem",
        .kind = .bit,
    },
    .{
        .word = "MEM_DUAL",
        .field = "mem_dual",
        .kind = .bit,
    },
    .{
        .word = "CIN_SRC",
        .field = "cin_src",
        .kind = .cin_src,
    },
    .{
        .word = "FRAC1",
        .field = "frac1",
        .kind = .bit,
    },
    .{
        .word = "FRAC2",
        .field = "frac2",
        .kind = .bit,
    },
    .{
        .word = "LUT1",
        .field = "lut1",
        .kind = .{ .hex = u16 },
    },
    .{
        .word = "LUT2",
        .field = "lut2",
        .kind = .{ .hex = u16 },
    },
    .{
        .word = "reg",
        .field = "regs",
        .kind = .reg,
    },
};

pub const reg_table = [_]Field{
    .{
        .word = "REG",
        .field = "reg",
        .kind = .bit,
    },
    .{
        .word = "CLK",
        .field = "clk",
        .kind = .clk,
    },
    .{
        .word = "RST_EN",
        .field = "rst_en",
        .kind = .bit,
    },
    .{
        .word = "RST",
        .field = "rst",
        .kind = .rst,
    },
};

pub const bram_table = [_]Field{
    .{
        .word = "WIDTH",
        .field = "width",
        .kind = .width,
    },
    .{
        .word = "CLK",
        .field = "clk",
        .kind = .clk,
    },
    .{
        .word = "data",
        .field = "data",
        .kind = .data,
    },
};

pub const dsp_table = [_]Field{
    .{
        .word = "SIGNED_A",
        .field = "signed_a",
        .kind = .bit,
    },
    .{
        .word = "SIGNED_B",
        .field = "signed_b",
        .kind = .bit,
    },
    .{
        .word = "ACC",
        .field = "acc",
        .kind = .bit,
    },
    .{
        .word = "CLK",
        .field = "clk",
        .kind = .clk,
    },
    .{
        .word = "RST_EN",
        .field = "rst_en",
        .kind = .bit,
    },
    .{
        .word = "RST",
        .field = "rst",
        .kind = .rst,
    },
};

pub const io_table = [_]Field{
    .{
        .word = "REG_I",
        .field = "reg_i",
        .kind = .bit,
    },
    .{
        .word = "REG_O",
        .field = "reg_o",
        .kind = .bit,
    },
    .{
        .word = "PULLUP",
        .field = "pullup",
        .kind = .bit,
    },
    .{
        .word = "PULLDOWN",
        .field = "pulldown",
        .kind = .bit,
    },
    .{
        .word = "CLK",
        .field = "clk",
        .kind = .clk,
    },
    .{
        .word = "RST_EN",
        .field = "rst_en",
        .kind = .bit,
    },
    .{
        .word = "RST",
        .field = "rst",
        .kind = .rst,
    },
};
