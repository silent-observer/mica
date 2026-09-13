const std = @import("std");
const common = @import("../common.zig");

/// Initial contents of a memory cell: `BRAM`/`BRAM_DUAL`, whose shape comes
/// from `WIDTH`, and the logical `$rom`/`$ram` family, whose shape comes from
/// `DATA_WIDTH`/`ADDR_WIDTH` and so is not bounded by any one tile.
///
/// Entries are stored one per `stride()`-byte slot rather than bit-packed the
/// way the bitstream's `Configuration.Bram.Data` is, which costs at most seven
/// bits an entry and buys three things: `slot()` is a multiply, entries wider
/// than any integer type still work, and a hex literal from `data {}` lands in
/// the slot unshifted because both are big-endian.
pub const MemData = @This();

/// Bits per entry, `1...common.mem_max_data_width`.
data_width: u16,
/// Entries, `1 << addr_width`.
depth: u32,
/// `depth * stride()` bytes. Entry `addr` occupies `slot(addr)`, big-endian
/// and zero-padded in the high bits of its first byte.
words: []u8,
/// One bit per entry: whether a `data {}` block has written this address.
/// Zeroed storage cannot tell "never written" from "written 0", and the
/// monotonic-union rule - restating a value is fine, contradicting it is not.
/// It also says which entries to emit.
present: std.DynamicBitSetUnmanaged,

pub const Error = error{MemoryTooLarge};

pub fn stride(m: MemData) u16 {
    return common.memStride(m.data_width);
}

/// `alloc` is expected to be the netlist's arena: nothing here is freed
/// individually, and `depth` makes that a decision worth being explicit about.
pub fn init(
    alloc: std.mem.Allocator,
    data_width: u16,
    addr_width: u8,
) Error!MemData {
    std.debug.assert(data_width > 0 and data_width <= common.mem_max_data_width);
    std.debug.assert(addr_width <= common.mem_max_addr_width);

    const depth = @as(u32, 1) << @intCast(addr_width);
    const bytes = @as(u64, depth) * common.memStride(data_width);
    if (bytes > common.mem_max_bytes) return error.MemoryTooLarge;

    const words = alloc.alloc(u8, @intCast(bytes)) catch common.oom();
    @memset(words, 0);

    return .{
        .data_width = data_width,
        .depth = depth,
        .words = words,
        .present = std.DynamicBitSetUnmanaged.initEmpty(alloc, depth) catch common.oom(),
    };
}

pub fn slot(m: *MemData, addr: u32) []u8 {
    std.debug.assert(addr < m.depth);
    return m.words[addr * m.stride() ..][0..m.stride()];
}

pub fn constSlot(m: *const MemData, addr: u32) []const u8 {
    std.debug.assert(addr < m.depth);
    return m.words[addr * m.stride() ..][0..m.stride()];
}

/// Whether `addr` was written by a `data {}` block. Unwritten entries read
/// back as zero, so this only matters for emission and conflict detection.
pub fn isSet(m: *const MemData, addr: u32) bool {
    std.debug.assert(addr < m.depth);
    return m.present.isSet(addr);
}

/// Entry `addr` as an integer. `T` has to be wide enough for `data_width`,
/// which is not a given here the way it is on the bitstream side - a `$rom`
/// may be 1024 bits wide, and those callers want `constSlot` instead.
pub fn get(m: *const MemData, comptime T: type, addr: u32) T {
    comptime std.debug.assert(@typeInfo(T) == .int);
    std.debug.assert(m.data_width <= 64 and @typeInfo(T).int.bits >= m.data_width);
    return @intCast(std.mem.readVarInt(u64, m.constSlot(addr), .big));
}

/// Sink for `CommonParser.parseRamData`. `bytes` is already in the stored
/// layout, so this is a copy plus the union check.
pub fn setSlot(m: *MemData, addr: u32, bytes: []const u8) bool {
    const dst = m.slot(addr);
    if (m.present.isSet(addr) and !std.mem.eql(u8, dst, bytes))
        return true;

    @memcpy(dst, bytes);
    m.present.set(addr);
    return false;
}
