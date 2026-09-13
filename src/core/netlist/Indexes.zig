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

    pub inline fn single(indexes: Indexes) Range {
        var dims: [MAX_INDEXES]Dim = undefined;
        for (0..MAX_INDEXES) |i|
            dims[i] = .{
                .start = indexes.dims[i],
                .len = if (i < indexes.n) 1 else 0,
            };
        return .{ .dims = dims, .n = indexes.n };
    }

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

    /// The walk of `a` followed by the walk of `b` as one range, or null when
    /// no single range spells that sequence.
    pub fn concat(a: Range, b: Range) ?Range {
        if (a.n != b.n) return null;

        // Only legal when a and b have form:
        // a = [_:1][_:1]...[_:1][xK    :l1K][_:lK+1]...[_:lN-1]
        // b = [_:1][_:1]...[_:1][xK+l1K:l2K][_:lK+1]...[_:lN-1]
        //
        // The dimensions before the extended one have to be 1 long. The walk of
        // [0..1][0..3] followed by that of [0..1][4..7] is not the walk of
        // [0..1][0..7], which takes all eight of row 0 before starting row 1.

        var out: Range = a;

        var extended = false;
        for (0..a.n) |i| {
            const same = a.dims[i].start == b.dims[i].start and
                a.dims[i].len == b.dims[i].len;

            if (extended) {
                // Everything past the extended dimension has to agree
                if (!same) return null;
            } else if (same) {
                // A dimension left alone before the extended one has to be 1
                // long, or the two walks interleave
                if (a.dims[i].len != 1) return null;
            } else {
                // The ranges have to be adjacent
                if (b.dims[i].start != a.dims[i].start + a.dims[i].len) return null;
                out.dims[i].len += b.dims[i].len;
                extended = true;
            }
        }

        // Nothing to extend: either the two are the same single element, or
        // neither has indexes at all. Neither tiles with itself.
        if (!extended) return null;

        return out;
    }
};

/// `[start..start+len-1]`, for the tests below.
fn r1(start: u16, len: u16) Range {
    var range: Range = .empty;
    range.add(start, len);
    return range;
}

fn r2(start0: u16, len0: u16, start1: u16, len1: u16) Range {
    var range = r1(start0, len0);
    range.add(start1, len1);
    return range;
}

test "concat tiles two walks into one range" {
    const Case = struct { a: Range, b: Range, want: ?Range };
    for ([_]Case{
        // The ordinary case: one dimension, adjacent, any lengths.
        .{ .a = r1(0, 1), .b = r1(1, 1), .want = r1(0, 2) },
        .{ .a = r1(2, 2), .b = r1(4, 3), .want = r1(2, 5) },
        // Gaps, overlaps and the wrong order are all unspellable.
        .{ .a = r1(0, 1), .b = r1(2, 1), .want = null },
        .{ .a = r1(0, 3), .b = r1(2, 1), .want = null },
        .{ .a = r1(1, 1), .b = r1(0, 1), .want = null },
        // A range does not tile with itself, and neither do two index-less
        // ranges, which name one net each and so cannot be the same one.
        .{ .a = r1(0, 1), .b = r1(0, 1), .want = null },
        .{ .a = .empty, .b = .empty, .want = null },
        // Ranges of different rank never tile.
        .{ .a = r1(0, 1), .b = .empty, .want = null },
        .{ .a = r1(0, 1), .b = r2(0, 1, 1, 1), .want = null },
        // Two dimensions: the last one extends under any first one, the first
        // one only extends whole rows of the last.
        .{ .a = r2(3, 1, 0, 2), .b = r2(3, 1, 2, 2), .want = r2(3, 1, 0, 4) },
        .{ .a = r2(0, 1, 0, 4), .b = r2(1, 1, 0, 4), .want = r2(0, 2, 0, 4) },
        .{ .a = r2(0, 1, 0, 2), .b = r2(1, 1, 0, 4), .want = null },
        // Partial rows either side of the seam interleave, so they stay apart
        // even though the bounding box holds exactly their elements.
        .{ .a = r2(0, 2, 0, 1), .b = r2(0, 2, 1, 1), .want = null },
    }) |case| {
        const got = case.a.concat(case.b);
        if (case.want) |want| {
            try std.testing.expect(got != null);
            try std.testing.expect(sameRange(want, got.?));
        } else try std.testing.expect(got == null);
    }
}

test "concat accepts exactly the pairs the walks allow" {
    // Exhaustive over every range of rank 0, 1 and 2 with small starts and
    // lengths. If any range spells the walk of `a` followed by that of `b` it
    // can only be their bounding box, so that is the one candidate to check -
    // which makes this a test of the rejections too, not just of the joins.
    var space: [1 + 9 + 81]Range = undefined;
    var n: usize = 0;
    space[n] = .empty;
    n += 1;
    for (0..3) |s0| {
        for (1..4) |l0| {
            space[n] = r1(@intCast(s0), @intCast(l0));
            n += 1;
            for (0..3) |s1| {
                for (1..4) |l1| {
                    space[n] = r2(
                        @intCast(s0),
                        @intCast(l0),
                        @intCast(s1),
                        @intCast(l1),
                    );
                    n += 1;
                }
            }
        }
    }

    var a_buf: [64]Indexes = undefined;
    var b_buf: [64]Indexes = undefined;
    var box_buf: [64]Indexes = undefined;

    for (space[0..n]) |a| {
        for (space[0..n]) |b| {
            const got = a.concat(b);
            if (a.n != b.n) {
                try std.testing.expect(got == null);
                continue;
            }

            var box = a;
            for (0..a.n) |i| {
                const lo = @min(a.dims[i].start, b.dims[i].start);
                const hi = @max(
                    a.dims[i].start + a.dims[i].len,
                    b.dims[i].start + b.dims[i].len,
                );
                box.dims[i] = .{ .start = lo, .len = hi - lo };
            }

            const a_walk = walk(a, &a_buf);
            const b_walk = walk(b, &b_buf);
            const box_walk = walk(box, &box_buf);

            const tiles = a.n != 0 and
                box_walk.len == a_walk.len + b_walk.len and
                sameWalk(box_walk[0..a_walk.len], a_walk) and
                sameWalk(box_walk[a_walk.len..], b_walk);

            if (tiles) {
                try std.testing.expect(got != null);
                try std.testing.expect(sameRange(box, got.?));
            } else try std.testing.expect(got == null);
        }
    }
}

fn walk(range: Range, buf: []Indexes) []const Indexes {
    var i: usize = 0;
    var iter = range.iterator();
    while (iter.next()) |indexes| : (i += 1)
        buf[i] = indexes;
    return buf[0..i];
}

/// Compares only the dimensions in use: the ones past `n` are never read.
fn sameRange(a: Range, b: Range) bool {
    if (a.n != b.n) return false;
    for (a.slice(), b.slice()) |x, y|
        if (x.start != y.start or x.len != y.len) return false;
    return true;
}

fn sameWalk(a: []const Indexes, b: []const Indexes) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y|
        if (x.n != y.n or !std.mem.eql(u16, x.slice(), y.slice())) return false;
    return true;
}
