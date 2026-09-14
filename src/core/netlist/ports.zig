//! Turns a cell's port table into flat offsets into its `port_nets` span. A
//! logical cell's widths are `Dim`s naming its own parameters, so its table
//! cannot be built until those are known - hence the `ParamMissing` error and
//! the rule that parameters precede ports.

const std = @import("std");
const Indexes = @import("Indexes.zig");
const port_tables = @import("port_tables.zig");
const cell_type = @import("cell_type.zig");
const Cell = @import("Cell.zig");

pub const Dim = union(enum) {
    fixed: u16,
    param: []const u8, // A[0..width-1]
    pow2: []const u8, // OUT[0..2^depth-1]
    twice: []const u8, // O[0..2*width-1]
};

pub const CellEntry = struct {
    clk: bool = false,
    rst: bool = false,
    entries: []const Entry,
};

pub const Entry = struct {
    kind: Cell.PortKind,
    name: []const u8,
    width: []const Dim = &.{},

    /// Fails if the port's width names a cell parameter that is still unset.
    pub fn range(
        comptime e: Entry,
        p: anytype,
    ) error{ParamMissing}!Indexes.Range {
        var r: Indexes.Range = .empty;
        inline for (e.width) |d| {
            switch (d) {
                .fixed => |n| r.add(0, n),
                .param => |width_name| {
                    const width: u16 = @field(p, width_name) orelse
                        return error.ParamMissing;
                    r.add(0, width);
                },
                .pow2 => |depth_name| {
                    const depth: u4 = @field(p, depth_name) orelse
                        return error.ParamMissing;
                    const n = @as(u16, 1) << depth;
                    r.add(0, n);
                },
                .twice => |width_name| {
                    const width: u16 = @field(p, width_name) orelse
                        return error.ParamMissing;
                    r.add(0, 2 * width);
                },
            }
        }
        return r;
    }
};

const MAX_PORT_ENTRIES = blk: {
    var curr: usize = 0;
    for (&port_tables.physical_cells.values) |e|
        curr = @max(curr, e.entries.len);
    for (&port_tables.logical_cells.values) |e|
        curr = @max(curr, e.entries.len);
    break :blk curr;
};

/// Flat port offsets for one cell, mapping each port's indexes to a position
/// in the cell's `port_nets` span.
pub const LookupTable = struct {
    total: u16,
    total_ins: u16,
    entries: u8,
    ports: [MAX_PORT_ENTRIES]PerPort, // Same order as in CellEntry entries

    pub const PerPort = struct {
        base: u16,
        full_range: Indexes.Range,
        count: u16,
    };

    pub fn isInput(lookup: *const LookupTable, port_idx: usize) bool {
        return port_idx < lookup.total_ins;
    }

    pub fn find(lookup: *const LookupTable, port_idx: usize) struct { entry_idx: u8, sub_idx: u16 } {
        var x = port_idx;
        std.debug.assert(x < lookup.total);
        for (lookup.ports[0..lookup.entries], 0..) |per_port, entry_idx| {
            if (x < per_port.count)
                return .{
                    .entry_idx = @intCast(entry_idx),
                    .sub_idx = @intCast(x),
                };
            x -= per_port.count;
        }
        unreachable;
    }
};

pub fn buildLookupTable(comptime entry: CellEntry, p: anytype) error{ParamMissing}!LookupTable {
    var total: u16 = 0;
    var total_ins: u16 = 0;
    var ports: [MAX_PORT_ENTRIES]LookupTable.PerPort = undefined;
    inline for (entry.entries, 0..) |e, i| {
        ports[i].base = total;
        ports[i].full_range = try e.range(p);
        ports[i].count = @intCast(ports[i].full_range.count());
        total += ports[i].count;
        if (e.kind == .in)
            total_ins += ports[i].count;
    }

    return LookupTable{
        .total = total,
        .total_ins = total_ins,
        .entries = @intCast(entry.entries.len),
        .ports = ports,
    };
}

const physical_lookups: std.EnumArray(cell_type.Physical, LookupTable) = blk: {
    var result: std.EnumArray(cell_type.Physical, LookupTable) = .initUndefined();
    for (std.enums.values(cell_type.Physical)) |ct| {
        result.set(
            ct,
            buildLookupTable(port_tables.physical_cells.get(ct), {}) catch unreachable,
        );
    }
    break :blk result;
};

pub fn buildLookupTableCell(cell: *const Cell) error{ParamMissing}!LookupTable {
    return switch (cell.params) {
        .physical => |params_union| physical_lookups.get(std.meta.activeTag(params_union)),
        .logical => |params_union| switch (params_union) {
            inline else => |params, lt| try buildLookupTable(
                port_tables.logical_cells.get(lt),
                params,
            ),
        },
    };
}

pub fn cellEntry(t: cell_type.Full) CellEntry {
    return switch (t) {
        .physical => |pt| port_tables.physical_cells.get(pt),
        .logical => |lt| port_tables.logical_cells.get(lt),
    };
}
