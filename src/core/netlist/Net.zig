const std = @import("std");
const Indexes = @import("Indexes.zig");
const Netlist = @import("Netlist.zig");

pub const Net = @This();

name: BaseId,
indexes: Indexes,
kind: Kind,
route_start: u32 = 0,
route_len: u16 = 0,
period_ps: ?u32 = null,
network: ?u3 = null,
pin: ?u16 = null,

pub const Kind = enum { net, clock, reset };

pub const BaseId = enum(u32) { _ };
pub const Ref = enum(u32) {
    none = 0xFFFF_FFFF,
    zero = 0xFFFF_FFFE,
    one = 0xFFFF_FFFD,
    _, // A net index

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
