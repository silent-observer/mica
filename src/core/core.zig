const std = @import("std");
const Io = std.Io;

pub const common = @import("common.zig");
pub const DeviceModel = @import("DeviceModel.zig");
pub const Fabric = @import("Fabric.zig");

test "core tests" {
    std.testing.refAllDecls(@This());
}
