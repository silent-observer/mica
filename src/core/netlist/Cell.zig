const std = @import("std");
const common = @import("../common.zig");
const Net = @import("Net.zig");
const Meta = @import("Meta.zig");
const cell_type = @import("cell_type.zig");

pub const Cell = @This();

params: union(cell_type.Kind) {
    physical: cell_type.Physical.ParamsUnion,
    logical: cell_type.Logical.ParamsUnion,
},
/// Span of `netlist.port_nets`, one entry per port bit in the order
/// `ports.LookupTable` assigns.
ports_start: u32 = 0,
ports_len: u16 = 0,
/// CLK and RST are not in the port table; they bind here instead.
clk: Net.Ref = .none,
rst: Net.Ref = .none,
pack: PackId = .none,
slot: SlotId = .none,
site: ?common.TileCoords = null,
meta: Meta.List = .{},

pub const Ref = enum(u32) {
    none = 0xFFFF_FFFF,
    _, // A cell index
};
pub const SlotId = enum {
    none,
    le1,
    le2,
    le1a,
    le1b,
    le2a,
    le2b,
};
pub const PackId = enum(u32) {
    none = 0xFFFF_FFFF,
    _, // A pack index
};

pub const PortKind = enum { in, out };

pub fn cellType(c: *const Cell) cell_type.Full {
    return switch (c.params) {
        .physical => |p| .{ .physical = std.meta.activeTag(p) },
        .logical => |l| .{ .logical = std.meta.activeTag(l) },
    };
}

pub fn init(t: cell_type.Full) Cell {
    return switch (t) {
        .physical => |p| Cell{
            .params = .{
                .physical = switch (p) {
                    inline else => |cp| @unionInit(
                        cell_type.Physical.ParamsUnion,
                        @tagName(cp),
                        .{},
                    ),
                },
            },
        },
        .logical => |l| Cell{
            .params = .{
                .logical = switch (l) {
                    inline else => |cl| @unionInit(
                        cell_type.Logical.ParamsUnion,
                        @tagName(cl),
                        .{},
                    ),
                },
            },
        },
    };
}
