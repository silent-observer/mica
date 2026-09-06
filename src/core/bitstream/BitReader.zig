const std = @import("std");

const BitReader = @This();

data: []const u8,
bit_len: u32,
pos: u32,

pub fn init(data: []const u8, bit_len: u32) BitReader {
    return .{
        .data = data,
        .bit_len = bit_len,
        .pos = 0,
    };
}

pub fn readBit(r: *BitReader) ?u1 {
    if (r.pos >= r.bit_len) return null;
    const byte_idx = r.pos / 8;
    const bit_idx: u3 = @intCast(r.pos % 8);
    r.pos += 1;

    return @intCast((r.data[byte_idx] >> (7 - bit_idx)) & 1);
}

pub fn read(r: *BitReader, T: type) ?T {
    if (T == bool)
        return if (r.readBit()) |b| b > 0 else null;
    std.debug.assert(@typeInfo(T) == .int);
    std.debug.assert(@typeInfo(T).int.signedness == .unsigned);

    const bits = @typeInfo(T).int.bits;
    if (r.pos + bits > r.bit_len) return null;

    var x: T = 0;
    for (0..bits) |_| {
        x <<= 1;
        x |= r.readBit().?;
    }
    return x;
}
