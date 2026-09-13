//! Signal spellings: a name with optional `[i]` or `[a..b]` subscripts, plus
//! the source position where a bare `0` or `1` is a constant driver rather than
//! a net name. Names admit `_` and `/` beyond the usual alphanumerics.

const std = @import("std");

const NetlistParser = @import("NetlistParser.zig");
const Indexes = @import("Indexes.zig");

pub const SignalRange = struct {
    name: []const u8,
    indexes: Indexes.Range,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("{s}{f}", .{ self.name, self.indexes });
    }
};

pub const SignalSource = union(enum) {
    range: SignalRange,
    zero: void,
    one: void,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self) {
            .range => |r| try writer.print("{f}", .{r}),
            .zero => try writer.writeAll("0"),
            .one => try writer.writeAll("1"),
        }
    }
};

pub fn parseName(p: *NetlistParser) ![]const u8 {
    return try p.p.parseWordExtra("_/");
}
pub fn parseSignalRange(p: *NetlistParser) !SignalRange {
    const name = try parseName(p);
    var range: Indexes.Range = .empty;
    while (p.p.check('[')) {
        if (range.n >= Indexes.MAX_INDEXES)
            try p.p.err(
                "At most {}-dimensional wires are currently supported",
                .{Indexes.MAX_INDEXES},
            );

        try p.p.expect('[');
        const start = try p.p.parseNumber(u16);
        const end: u16 = if (p.p.check('.')) blk: {
            try p.p.expect('.');
            try p.p.expect('.');
            break :blk try p.p.parseNumber(u16);
        } else start;
        try p.p.expect(']');

        if (end < start)
            try p.p.err("Reverse ranges are not supported: '{}..{}'", .{ start, end });

        range.addStartEnd(start, end);
    }

    return .{
        .name = name,
        .indexes = range,
    };
}

pub fn parseSignalSource(p: *NetlistParser) !SignalSource {
    p.p.skipWhitespace();
    if (!p.p.eof() and std.ascii.isDigit(p.p.peek(0).?)) {
        const x = try p.p.parseNumber(u1);
        return switch (x) {
            0 => .zero,
            1 => .one,
        };
    } else {
        return .{ .range = try parseSignalRange(p) };
    }
}
