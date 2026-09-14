//! One cell. Since the IR has no tile object, packing and placement live here
//! too, as `pack`/`slot`/`site`. Only inputs the tools cannot derive are
//! stored: `FRAC*`, `CARRY`, `MEM` and friends are computed at lowering.

const std = @import("std");
const common = @import("../common.zig");
const Net = @import("Net.zig");
const Meta = @import("Meta.zig");
const cell_type = @import("cell_type.zig");
const MemData = @import("MemData.zig");

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
/// Contents of a `data {}` block, for the cell types that can carry one. It
/// lives here rather than among the parameters because its shape is derived
/// from them, so it cannot be parsed until they are known.
data: ?MemData = null,
meta: Meta.List = .{},

pub const Ref = enum(u32) {
    none = 0xFFFF_FFFF,
    _, // A cell index

    pub fn int(ref: Ref) u32 {
        std.debug.assert(ref != .none);
        return @intFromEnum(ref);
    }
};
pub const SlotId = enum {
    none,
    le1,
    le2,
    le1a,
    le1b,
    le2a,
    le2b,

    pub const names: std.EnumArray(SlotId, []const u8) = blk: {
        var r: std.EnumArray(SlotId, []const u8) = .initUndefined();
        for (std.enums.values(SlotId)) |slot| {
            r.set(slot, common.upper(@tagName(slot)));
        }
        break :blk r;
    };

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("{s}", .{names.get(self)});
    }

    pub const lookup: std.StaticStringMap(SlotId) = blk: {
        const values = std.enums.values(SlotId);
        var entries: [values.len - 1]struct { []const u8, SlotId } = undefined;
        var i: usize = 0;
        for (values) |v| {
            if (v == .none) continue;
            entries[i] = .{ names.get(v), v };
            i += 1;
        }
        break :blk std.StaticStringMap(SlotId).initComptime(entries);
    };
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
