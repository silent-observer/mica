const std = @import("std");
const Io = std.Io;

pub const common = @import("common.zig");
pub const DeviceModel = @import("DeviceModel.zig");
pub const Fabric = @import("Fabric.zig");
pub const routing = @import("routing.zig");
const wire_codes = @import("wire_codes.zig");
pub const TextParser = @import("bitstream/TextParser.zig");
pub const TextEmitter = @import("bitstream/TextEmitter.zig");
pub const BinaryParser = @import("bitstream/BinaryParser.zig");
pub const BinaryEmitter = @import("bitstream/BinaryEmitter.zig");

test "core tests" {
    std.testing.refAllDecls(@This());
}
