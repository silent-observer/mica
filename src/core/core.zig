const std = @import("std");
const Io = std.Io;

pub const common = @import("common.zig");
pub const DeviceModel = @import("DeviceModel.zig");
pub const Fabric = @import("Fabric.zig");
pub const routing = @import("routing.zig");
pub const wire_codes = @import("wire_codes.zig");
pub const TextParser = @import("bitstream/TextParser.zig");
pub const TextEmitter = @import("bitstream/TextEmitter.zig");
pub const BinaryParser = @import("bitstream/BinaryParser.zig");
pub const BinaryEmitter = @import("bitstream/BinaryEmitter.zig");

pub const Configuration = @import("Configuration.zig");
pub const Netlist = @import("netlist/Netlist.zig");
pub const NetlistParser = @import("netlist/NetlistParser.zig");
pub const NetlistEmitter = @import("netlist/NetlistEmitter.zig");

test "core tests" {
    std.testing.refAllDecls(@This());
    // refAllDecls only reaches pub decls, so test-only files have to be pulled
    // in by hand.
    _ = @import("bitstream/tests.zig");
    _ = @import("netlist/tests.zig");
}
