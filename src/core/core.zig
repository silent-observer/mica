const std = @import("std");
const Io = std.Io;

pub const common = @import("common.zig");
pub const DeviceModel = @import("DeviceModel.zig");
pub const Fabric = @import("Fabric.zig");
const wire_codes = @import("wire_codes.zig");

test "core tests" {
    std.testing.refAllDecls(@This());
}
