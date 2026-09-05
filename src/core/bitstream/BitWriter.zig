const std = @import("std");

const BitWriter = @This();

w: std.Io.Writer.Allocating,
in_progress_byte: u8,
bit_cursor: u3,

pub fn init(alloc: std.mem.Allocator) BitWriter {
    return .{
        .w = .init(alloc),
        .in_progress_byte = 0,
        .bit_cursor = 7,
    };
}

pub fn deinit(w: *BitWriter) void {
    w.w.deinit();
}

pub fn writeBit(w: *BitWriter, bit: u1) void {
    w.in_progress_byte |= @as(u8, bit) << w.bit_cursor;
    if (w.bit_cursor == 0) {
        w.w.writer.writeByte(w.in_progress_byte) catch unreachable;
        w.in_progress_byte = 0;
        w.bit_cursor = 7;
    } else w.bit_cursor -= 1;
}

pub fn write(w: *BitWriter, T: type, val: T) void {
    std.debug.assert(@typeInfo(T) == .int);
    std.debug.assert(@typeInfo(T).int.signedness == .unsigned);

    const bits = @typeInfo(T).int.bits;
    var i = bits;
    while (i > 0) {
        i -= 1;
        const bit = (val >> @intCast(i)) & 1;
        w.writeBit(@intCast(bit));
    }
}

pub fn reset(w: *BitWriter) void {
    w.w.clearRetainingCapacity();
    w.in_progress_byte = 0;
    w.bit_cursor = 7;
}

pub fn bitLen(w: *BitWriter) u32 {
    return @intCast(8 * w.w.written().len + (7 - w.bit_cursor));
}

pub fn finish(w: *BitWriter) []const u8 {
    if (w.bit_cursor != 7)
        w.w.writer.writeByte(w.in_progress_byte) catch unreachable;
    return w.w.written();
}
