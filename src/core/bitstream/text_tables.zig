const std = @import("std");
const common = @import("../common.zig");
const wire_codes = @import("../wire_codes.zig");

pub const ValueKind = union(enum) {
    bit: void,
    dec: type,
    bin: type,
    hex: type,
    clk: void,
    rst: void,
    cin_src: void,
    reg: void,
    data: void,
    width: void,
};

pub const global_table = .{
    .{ "CLK_PIN_ENABLE", 8, "clk_enable", ValueKind.bit },
    .{ "RST_PIN_ENABLE", 4, "rst_enable", ValueKind.bit },
    .{ "RESERVED", 0, "reserved", ValueKind{ .bin = u4 } },
};

pub const logic_table = .{
    .{ "CARRY", 0, "carry", ValueKind.bit },
    .{ "MEM", 0, "mem", ValueKind.bit },
    .{ "MEM_DUAL", 0, "mem_dual", ValueKind.bit },
    .{ "CIN_SRC", 0, "cin_src", ValueKind.cin_src },
    .{ "FRAC1", 0, "frac1", ValueKind.bit },
    .{ "FRAC2", 0, "frac2", ValueKind.bit },
    .{ "LUT1", 0, "lut1", ValueKind{ .hex = u16 } },
    .{ "LUT2", 0, "lut2", ValueKind{ .hex = u16 } },
    .{ "reg", 0, "regs", ValueKind.reg },
};

pub const logic_inputs_table = .{
    .{ "A1", 0, "inputs", "a1" },
    .{ "B1", 0, "inputs", "b1" },
    .{ "C1", 0, "inputs", "c1" },
    .{ "D1", 0, "inputs", "d1" },
    .{ "CE1", 0, "inputs", "ce1" },
    .{ "A2", 0, "inputs", "a2" },
    .{ "B2", 0, "inputs", "b2" },
    .{ "C2", 0, "inputs", "c2" },
    .{ "D2", 0, "inputs", "d2" },
    .{ "CE2", 0, "inputs", "ce2" },
};

pub const reg_table = .{
    .{ "REG", 0, "reg", ValueKind.bit },
    .{ "CLK", 0, "clk", ValueKind.clk },
    .{ "RST_EN", 0, "rst_en", ValueKind.bit },
    .{ "RST", 0, "clk", ValueKind.rst },
};

pub const bram_table = .{
    .{ "WIDTH", 0, "width", ValueKind.width },
    .{ "CLK", 0, "clk", ValueKind.clk },
    .{ "data", 0, "data", ValueKind.data },
};

pub const bram_inputs_table = .{
    .{ "A1", 12, "a1", "a1" },
    .{ "A2", 12, "a2", "a2" },
    .{ "DI", 16, "di", "di" },
    .{ "WE1", 0, "we1", "we1" },
    .{ "WE2", 0, "we2", "we2" },
};

pub const dsp_table = .{
    .{ "SIGNED_A", 0, "signed_a", ValueKind.bit },
    .{ "SIGNED_B", 0, "signed_b", ValueKind.bit },
    .{ "ACC", 0, "acc", ValueKind.bit },
    .{ "CLK", 0, "clk", ValueKind.clk },
    .{ "RST_EN", 0, "rst_en", ValueKind.bit },
    .{ "RST", 0, "clk", ValueKind.rst },
};

pub const dsp_inputs_table = .{
    .{ "A", 8, "a", "a" },
    .{ "B", 8, "b", "b" },
    .{ "C", 16, "c", "c" },
    .{ "MD", 0, "md", "md" },
    .{ "AD", 0, "ad", "ad" },
    .{ "WE", 0, "we", "we" },
};

pub const io_table = .{
    .{ "REG_I", 0, "reg_i", ValueKind.bit },
    .{ "REG_O", 0, "reg_o", ValueKind.bit },
    .{ "PULLUP", 0, "pullup", ValueKind.bit },
    .{ "PULLDOWN", 0, "pulldown", ValueKind.bit },
    .{ "CLK", 0, "clk", ValueKind.clk },
    .{ "RST_EN", 0, "rst_en", ValueKind.bit },
    .{ "RST", 0, "clk", ValueKind.rst },
};

pub const io_inputs_table = .{
    .{ "O", 0, "inputs", "o" },
    .{ "E", 0, "inputs", "e" },
    .{ "IE", 0, "inputs", "ie" },
    .{ "OE", 0, "inputs", "oe" },
    .{ "EE", 0, "inputs", "ee" },
};
