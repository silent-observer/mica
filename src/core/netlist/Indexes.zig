//! The `[3]` subscripts on a net or port name, and `Range` for the `[0..7]`
//! spelling that expands to several of them. Nets are scalar, so `data[0..3]`
//! is only sugar for four independent nets sharing a base name.

const std = @import("std");

const Indexes = @This();

pub const MAX_INDEXES = 4;

dims: [MAX_INDEXES]u16,
n: u8,

pub const empty = Indexes{
    .dims = std.mem.zeroes([MAX_INDEXES]u16),
    .n = 0,
};

pub inline fn slice(self: *const Indexes) []const u16 {
    return self.dims[0..self.n];
}

pub fn format(
    self: @This(),
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    for (self.slice()) |i|
        try writer.print("[{}]", .{i});
}

pub const Range = struct {
    dims: [MAX_INDEXES]Dim,
    n: u8,

    const Dim = struct { start: u16, len: u16 };

    pub const empty = Range{
        .dims = std.mem.zeroes([MAX_INDEXES]Dim),
        .n = 0,
    };

    pub inline fn base(self: Range) Indexes {
        var dims: [MAX_INDEXES]u16 = undefined;
        for (0..MAX_INDEXES) |i|
            dims[i] = self.dims[i].start;
        return .{ .dims = dims, .n = self.n };
    }

    pub inline fn add(self: *Range, start: u16, len: u16) void {
        std.debug.assert(self.n < MAX_INDEXES);
        self.dims[self.n] = .{ .start = start, .len = len };
        self.n += 1;
    }

    pub inline fn addStartEnd(self: *Range, start: u16, end: u16) void {
        std.debug.assert(start <= end);
        self.add(start, end - start + 1);
    }

    pub inline fn slice(self: *const Range) []const Dim {
        return self.dims[0..self.n];
    }

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        for (self.slice()) |dim| {
            if (dim.len <= 1)
                try writer.print("[{}]", .{dim.start})
            else {
                const end = dim.start + dim.len - 1;
                try writer.print("[{}..{}]", .{ dim.start, end });
            }
        }
    }

    pub fn count(self: Range) usize {
        var r: usize = 1;
        for (self.slice()) |dim|
            r *= dim.len;
        return r;
    }

    pub inline fn iterator(self: Range) Iterator {
        return .{ .r = self, .curr = self.base() };
    }

    pub const Iterator = struct {
        r: Range,
        curr: ?Indexes,

        pub fn next(iter: *Iterator) ?Indexes {
            if (iter.curr) |*curr| {
                const r = curr.*;
                var i = curr.n;
                while (i > 0) {
                    i -= 1;
                    curr.dims[i] += 1;
                    if (curr.dims[i] < iter.r.dims[i].start + iter.r.dims[i].len)
                        return r;

                    curr.dims[i] = iter.r.dims[i].start;
                }
                iter.curr = null;
                return r;
            } else return null;
        }
    };

    /// Flat position of `needle` inside `haystack`, last index varying
    /// fastest, or null if the dimensions differ or it falls outside.
    pub fn toIndex(haystack: Range, needle: Indexes) ?usize {
        if (haystack.n != needle.n) return null;
        var stride: usize = 1;
        var idx: usize = 0;
        var i = haystack.n;
        while (i > 0) {
            i -= 1;
            if (needle.dims[i] < haystack.dims[i].start) return null;
            if (needle.dims[i] >= haystack.dims[i].start + haystack.dims[i].len) return null;
            idx += stride * (needle.dims[i] - haystack.dims[i].start);
            stride *= haystack.dims[i].len;
        }
        return idx;
    }
};
