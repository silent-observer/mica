const std = @import("std");
const common = @import("../common.zig");
const Indexes = @import("Indexes.zig");
const ports = @import("ports.zig");
const cell_type = @import("cell_type.zig");
const Netlist = @import("Netlist.zig");
const NetIndex = @import("NetIndex.zig");
const Net = @import("Net.zig");
const Cell = @import("Cell.zig");
const DeviceModel = @import("../DeviceModel.zig");

pub const PinSite = union(enum) {
    input: TileInput,
    output: TileOutput,
    dedicated: void,
    carry_in: void,
};

pub const TileInput = union(common.TileType) {
    inert: void,
    logic: common.LogicInput,
    bram: common.BramInput,
    dsp: common.DspInput,
    io: common.IoInput,
};

pub const TileOutput = struct {
    idx: u2,
    tile_offset: u2 = 0,
    any: bool = false,
};

const Mapping = union(enum) {
    dedicated: void,

    fixed_in: TileInput,
    per_slot_in: [2]common.LogicInput,
    indexed_in: *const fn (u16) TileInput,
    carry_in: void,

    fixed_out: TileOutput,
    per_slot_out: [2]common.LogicOutput,
    per_slot_out4: [4]common.LogicOutput,
    indexed_out: *const fn (u16) TileOutput,
};

const CellMapping = struct {
    mappings: []const Mapping,
};

const mapping_table: std.EnumArray(cell_type.Physical, CellMapping) = .init(.{
    .lut4 = CellMapping{
        .mappings = &.{
            Mapping{ .per_slot_in = .{ .a1, .a2 } }, // A
            Mapping{ .per_slot_in = .{ .b1, .b2 } }, // B
            Mapping{ .per_slot_in = .{ .c1, .c2 } }, // C
            Mapping{ .per_slot_in = .{ .d1, .d2 } }, // D

            Mapping{ .per_slot_out = .{ .o1a, .o2a } }, // O
        },
    },
    .lut3 = CellMapping{
        .mappings = &.{
            Mapping{ .per_slot_in = .{ .b1, .b2 } }, // B
            Mapping{ .per_slot_in = .{ .c1, .c2 } }, // C
            Mapping{ .per_slot_in = .{ .d1, .d2 } }, // D

            Mapping{ .per_slot_out4 = .{ .o1a, .o1b, .o2a, .o2b } }, // O
        },
    },
    .ff = CellMapping{
        .mappings = &.{
            Mapping.dedicated, // D
            Mapping{ .per_slot_in = .{ .ce1, .ce2 } }, // E

            Mapping{ .per_slot_out = .{ .o1a, .o2a } }, // O
        },
    },
    .carry = CellMapping{
        .mappings = &.{
            Mapping{ .per_slot_in = .{ .b1, .b2 } }, // B
            Mapping{ .per_slot_in = .{ .c1, .c2 } }, // C
            Mapping{ .per_slot_in = .{ .d1, .d2 } }, // D
            Mapping.carry_in, // CIN

            Mapping{ .per_slot_out = .{ .o1a, .o2a } }, // S
            Mapping{ .per_slot_out = .{ .o1b, .o2b } }, // G
            Mapping.dedicated, // COUT
        },
    },
    .mem = CellMapping{
        .mappings = &.{
            Mapping{ .indexed_in = memAddrPortToInput }, // ADDR
            Mapping{ .fixed_in = .{ .logic = .c2 } }, // DI
            Mapping{ .fixed_in = .{ .logic = .ce1 } }, // WE

            Mapping{ .fixed_out = .{ .idx = @intFromEnum(common.LogicOutput.o1a) } }, // DO
        },
    },
    .mem_dual = CellMapping{
        .mappings = &.{
            Mapping{ .indexed_in = memAddrPortToInput }, // ADDR
            Mapping{ .indexed_in = memDiPortToInput }, // DI
            Mapping{ .fixed_in = .{ .logic = .ce1 } }, // WE

            Mapping{ .indexed_out = memDoPortToOutput }, // DO
        },
    },
    .bram = CellMapping{
        .mappings = &.{
            Mapping{ .indexed_in = bramAddr1PortToInput }, // ADDR
            Mapping{ .indexed_in = bramDiPortToInput }, // DI
            Mapping{ .fixed_in = .{ .bram = .we1 } }, // WE

            Mapping{ .indexed_out = bramDoPortToOutput }, // DO
        },
    },
    .bram_dual = CellMapping{
        .mappings = &.{
            Mapping{ .indexed_in = bramAddr1PortToInput }, // ADDR1
            Mapping{ .indexed_in = bramAddr2PortToInput }, // ADDR2
            Mapping{ .indexed_in = bramDiPortToInput }, // DI1
            Mapping{ .indexed_in = bramDi2PortToInput }, // DI2
            Mapping{ .fixed_in = .{ .bram = .we1 } }, // WE1
            Mapping{ .fixed_in = .{ .bram = .we2 } }, // WE2

            Mapping{ .indexed_out = bramDoPortToOutput }, // DO
            Mapping{ .indexed_out = bramDo2PortToOutput }, // DO
        },
    },
    .dsp = CellMapping{
        .mappings = &.{
            Mapping{ .indexed_in = dspAPortToInput }, // A
            Mapping{ .indexed_in = dspBPortToInput }, // B

            Mapping{ .indexed_out = dspOPortToOutput }, // O
        },
    },
    .dsp_acc = CellMapping{
        .mappings = &.{
            Mapping{ .indexed_in = dspAPortToInput }, // A
            Mapping{ .indexed_in = dspBPortToInput }, // B
            Mapping{ .indexed_in = dspCPortToInput }, // C
            Mapping{ .fixed_in = .{ .dsp = .md } }, // MD
            Mapping{ .fixed_in = .{ .dsp = .ad } }, // AD
            Mapping{ .fixed_in = .{ .dsp = .we } }, // WE

            Mapping{ .indexed_out = dspOPortToOutput }, // O
        },
    },
    .io = CellMapping{
        .mappings = &.{
            Mapping{ .fixed_in = .{ .io = .o } }, // O
            Mapping{ .fixed_in = .{ .io = .e } }, // E
            Mapping{ .fixed_in = .{ .io = .ie } }, // IE
            Mapping{ .fixed_in = .{ .io = .oe } }, // OE
            Mapping{ .fixed_in = .{ .io = .ee } }, // EE

            Mapping{ .fixed_out = .{ .idx = 0, .any = true } }, // I
        },
    },
});

fn memAddrPortToInput(idx: u16) TileInput {
    std.debug.assert(idx < 5);
    return TileInput{ .logic = .fromIdx(@intCast(idx)) };
}
fn memDiPortToInput(idx: u16) TileInput {
    std.debug.assert(idx < 2);
    return TileInput{ .logic = if (idx == 0) .d2 else .c2 };
}
fn memDoPortToOutput(idx: u16) TileOutput {
    std.debug.assert(idx < 2);
    return if (idx == 0)
        TileOutput{ .idx = @intFromEnum(common.LogicOutput.o1a) }
    else
        TileOutput{ .idx = @intFromEnum(common.LogicOutput.o2a) };
}

fn bramAddr1PortToInput(idx: u16) TileInput {
    std.debug.assert(idx < 12);
    return TileInput{ .bram = .{ .a1 = @intCast(idx) } };
}
fn bramAddr2PortToInput(idx: u16) TileInput {
    std.debug.assert(idx < 12);
    return TileInput{ .bram = .{ .a2 = @intCast(idx) } };
}
fn bramDiPortToInput(idx: u16) TileInput {
    std.debug.assert(idx < 16);
    return TileInput{ .bram = .{ .di = @intCast(idx) } };
}
fn bramDi2PortToInput(idx: u16) TileInput {
    std.debug.assert(idx < 8);
    return TileInput{ .bram = .{ .di = @intCast(8 + idx) } };
}
fn bramDoPortToOutput(idx: u16) TileOutput {
    std.debug.assert(idx < 16);
    return TileOutput{
        .idx = @intCast(idx % 4),
        .tile_offset = @intCast(idx / 4),
    };
}
fn bramDo2PortToOutput(idx: u16) TileOutput {
    std.debug.assert(idx < 8);
    return TileOutput{
        .idx = @intCast(idx % 4),
        .tile_offset = @intCast(2 + idx / 4),
    };
}

fn dspAPortToInput(idx: u16) TileInput {
    std.debug.assert(idx < 8);
    return TileInput{ .dsp = .{ .a = @intCast(idx) } };
}
fn dspBPortToInput(idx: u16) TileInput {
    std.debug.assert(idx < 8);
    return TileInput{ .dsp = .{ .b = @intCast(idx) } };
}
fn dspCPortToInput(idx: u16) TileInput {
    std.debug.assert(idx < 16);
    return TileInput{ .dsp = .{ .c = @intCast(idx) } };
}
fn dspOPortToOutput(idx: u16) TileOutput {
    std.debug.assert(idx < 16);
    return TileOutput{
        .idx = @intCast(idx % 4),
        .tile_offset = @intCast(idx / 4),
    };
}

pub fn pinSite(cell: *const Cell, port: u16) PinSite {
    const ct = cell.cellType();
    std.debug.assert(ct == .physical);
    const cell_mapping = mapping_table.get(ct.physical);
    const lookup = ports.buildLookupTableCell(cell) catch unreachable;

    const s = lookup.find(port);
    const mapping = cell_mapping.mappings[s.entry_idx];
    const slot4: usize = switch (cell.slot) {
        .none => unreachable,
        .le1, .le1a => 0,
        .le1b => 1,
        .le2, .le2a => 2,
        .le2b => 3,
    };
    return switch (mapping) {
        .dedicated => .dedicated,

        .fixed_in => |in| .{ .input = in },
        .per_slot_in => |ins| .{ .input = .{ .logic = ins[slot4 / 2] } },
        .indexed_in => |f| .{ .input = f(s.sub_idx) },
        .carry_in => .carry_in,

        .fixed_out => |out| .{ .output = out },
        .per_slot_out => |outs| .{ .output = .{
            .idx = @intFromEnum(outs[slot4 / 2]),
        } },
        .per_slot_out4 => |outs| .{ .output = .{
            .idx = @intFromEnum(outs[slot4]),
        } },
        .indexed_out => |f| .{ .output = f(s.sub_idx) },
    };
}

pub fn resolveInputSite(
    nl: *const Netlist,
    idx: *const NetIndex,
    cell: *const Cell,
    port: u16,
) ?TileInput {
    const raw_pin_site = pinSite(cell, port);
    switch (raw_pin_site) {
        .dedicated => return null,
        .input => |in| return in,
        .output => unreachable,
        .carry_in => {
            const net_ref = nl.getCellPort(cell, port).*;
            if (!net_ref.isReal()) return null;
            const driver = idx.drivers[net_ref.int()];

            // Check if the driver is CARRY.COUT
            const driver_cell = nl.getCell(driver.cell);
            if (!std.meta.eql(
                driver_cell.cellType(),
                cell_type.Full{ .physical = .carry },
            )) return null;

            const driver_site = pinSite(driver_cell, driver.port);
            return if (driver_site == .dedicated) null else TileInput{ .logic = .a1 };
        },
    }
}

pub fn resolveOutputSite(
    cell: *const Cell,
    port: u16,
) ?TileOutput {
    const raw_pin_site = pinSite(cell, port);
    switch (raw_pin_site) {
        .dedicated => return null,
        .input, .carry_in => unreachable,
        .output => |out| return out,
    }
}
