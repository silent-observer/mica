const std = @import("std");
const Indexes = @import("Indexes.zig");
const Netlist = @import("Netlist.zig");
const Meta = @import("Meta.zig");

pub const Net = @This();

name: BaseId,
indexes: Indexes,
kind: Kind,
/// Span of `netlist.route_edges` holding this net's routing.
route_start: u32 = 0,
route_len: u16 = 0,
period_ps: ?u32 = null,
/// Global clock or reset network number. The netlist spells this as a plain
/// number where the bitstream writes `CLK0`/`RST0`.
network: ?u3 = null,
pin: ?u16 = null,
meta: Meta.List = .{},

pub const Kind = enum { net, clock, reset };

pub const BaseId = enum(u32) { _ };
/// A net index, or a sentinel for an unbound port (`.none`) or a constant
/// driver (`.zero`/`.one`), so either costs the same four bytes.
pub const Ref = enum(u32) {
    none = 0xFFFF_FFFF,
    zero = 0xFFFF_FFFE,
    one = 0xFFFF_FFFD,
    _, // A net index

    /// Formats any ref, including the sentinels `Netlist.getNet` asserts on.
    pub fn fmt(ref: Ref, netlist: *const Netlist) Printable {
        return switch (ref) {
            .none => Printable{ .name = "<none>", .indexes = .empty },
            .zero => Printable{ .name = "0", .indexes = .empty },
            .one => Printable{ .name = "1", .indexes = .empty },
            else => netlist.getNet(ref).fmt(netlist),
        };
    }
};

pub const Printable = struct {
    name: []const u8,
    indexes: Indexes,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("{s}{f}", .{ self.name, self.indexes });
    }
};

pub fn fmt(n: *const Net, netlist: *const Netlist) Printable {
    return Printable{
        .name = netlist.net_base_names.get(n.name),
        .indexes = n.indexes,
    };
}
