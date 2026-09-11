const std = @import("std");

const Indexes = @This();

pub const MAX_INDEXES = 4;

idx: [MAX_INDEXES]u16,
len: u8,

pub const empty = Indexes{
    .idx = std.mem.zeroes([MAX_INDEXES]u16),
    .len = 0,
};

pub inline fn add(self: *Indexes, i: u16) void {
    std.debug.assert(self.len < MAX_INDEXES);
    self.idx[self.len] = i;
    self.len += 1;
}

pub inline fn sliceMut(self: *Indexes) []u16 {
    return self.idx[0..self.len];
}

pub inline fn slice(self: *const Indexes) []const u16 {
    return self.idx[0..self.len];
}

pub fn format(
    self: @This(),
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    for (self.slice()) |i|
        try writer.print("[{}]", .{i});
}

pub const Range = struct {
    lens: [MAX_INDEXES]u16,
    base: Indexes,

    pub const empty = Range{
        .lens = std.mem.zeroes([MAX_INDEXES]u16),
        .base = .empty,
    };

    pub inline fn len(self: Range) u16 {
        return self.base.len;
    }

    pub inline fn add(self: *Range, start: u16, length: u16) void {
        std.debug.assert(self.base.len < MAX_INDEXES);
        self.base.idx[self.base.len] = start;
        self.lens[self.base.len] = length;
        self.base.len += 1;
    }

    pub inline fn addStartEnd(self: *Range, start: u16, end: u16) void {
        self.add(start, end - start + 1);
    }

    pub inline fn make1(a: [2]u16) Range {
        var r: Range = .empty;
        r.addStartEnd(a[0], a[1]);
        return r;
    }

    pub inline fn make2(a: [2]u16, b: [2]u16) Range {
        var r: Range = .empty;
        r.addStartEnd(a[0], a[1]);
        r.addStartEnd(b[0], b[1]);
        return r;
    }

    pub inline fn lensSlice(self: *const Range) []const u16 {
        return self.lens[0..self.base.len];
    }

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        for (self.base.slice(), self.lensSlice()) |start, length| {
            if (length <= 1)
                try writer.print("[{}]", .{start})
            else {
                const end = start + length - 1;
                try writer.print("[{}..{}]", .{ start, end });
            }
        }
    }

    pub fn count(self: Range) usize {
        var r: usize = 1;
        for (self.lensSlice()) |length|
            r *= length;
        return r;
    }

    pub inline fn iterator(self: Range) Iterator {
        return .{ .r = self, .curr = self.base };
    }

    pub const Iterator = struct {
        r: Range,
        curr: ?Indexes,

        pub fn next(iter: *Iterator) ?Indexes {
            if (iter.curr) |*curr| {
                const r = curr.*;
                var i = curr.len;
                while (i > 0) {
                    i -= 1;
                    curr.idx[i] += 1;
                    if (curr.idx[i] < iter.r.base.idx[i] + iter.r.lens[i])
                        return r;

                    curr.idx[i] = iter.r.base.idx[i];
                }
                iter.curr = null;
                return r;
            } else return null;
        }
    };

    pub fn toIndex(haystack: Range, needle: Indexes) ?usize {
        std.debug.assert(haystack.len() == needle.len);
        var stride: usize = 1;
        var idx: usize = 0;
        var i = haystack.len();
        while (i > 0) {
            i -= 1;
            if (needle.idx[i] < haystack.base.idx[i]) return null;
            if (needle.idx[i] >= haystack.base.idx[i] + haystack.lens[i]) return null;
            idx += stride * (needle.idx[i] - haystack.base.idx[i]);
            stride *= haystack.lens[i];
        }
        return idx;
    }
};
