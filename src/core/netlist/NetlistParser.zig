const std = @import("std");

const common = @import("../common.zig");
const wire_codes = @import("../wire_codes.zig");
const Netlist = @import("Netlist.zig");
const DeviceModel = @import("../DeviceModel.zig");
const CommonParser = @import("../CommonParser.zig");

const NetlistParser = @This();

p: CommonParser,
netlist: ?*Netlist,

fn init(input: []const u8, alloc: std.mem.Allocator) NetlistParser {
    return .{
        .p = .init(input, alloc),
        .netlist = null,
    };
}

inline fn nl(p: *NetlistParser) *Netlist {
    return p.netlist.?;
}

const passes: std.StaticStringMap(Netlist.Pass) = .initComptime(.{
    .{ "synth", .synth },
    .{ "opt", .opt },
    .{ "techmap", .techmap },
    .{ "pack", .pack },
    .{ "place", .place },
    .{ "route", .route },
});

fn parseHeader(p: *NetlistParser) !void {
    const format_word = try p.p.parseWord();
    if (!std.mem.eql(u8, format_word, "format"))
        try p.p.err("Expected 'format', but got '{s}'", .{format_word});

    const format_int = try p.p.parseNumber(u64);
    if (format_int != 1)
        try p.p.err("Expected 'format 1', but got 'format {}'", .{format_int});

    try p.p.expect(';');

    const device_word = try p.p.parseWord();
    if (!std.mem.eql(u8, device_word, "device"))
        try p.p.err("Expected 'device', but got '{s}'", .{device_word});

    const device_str = try p.p.parseDeviceName();
    try p.p.expect(';');

    const model: DeviceModel = for (&DeviceModel.models) |m| {
        if (std.mem.eql(u8, device_str, m.model_id))
            break m;
    } else try p.p.err("Unknown device model: '{s}'", .{device_str});

    const design_word = try p.p.parseWord();
    if (!std.mem.eql(u8, design_word, "design"))
        try p.p.err("Expected 'design', but got '{s}'", .{design_word});
    const design_str = try p.p.parseString();
    try p.p.expect(';');

    p.netlist = p.p.alloc.create(Netlist) catch common.oom();
    p.netlist.?.init(p.p.alloc, model, design_str);

    while (!p.p.checkEof()) {
        const m = p.p.mark();
        if (!std.mem.eql(u8, try p.p.parseWord(), "pass")) {
            p.p.reset(m);
            break;
        }

        const pass_word = try p.p.parseWord();
        const pass = passes.get(pass_word) orelse
            try p.p.err("Expected a pass name " ++
                "(one of 'synth', 'opt', 'techmap', 'pack', 'place', 'route'), " ++
                "but got '{s}'", .{pass_word});
        const str = try p.p.parseString();
        try p.p.expect(';');

        p.nl().passes.put(
            pass,
            p.nl().str_arena.allocator().dupe(u8, str) catch common.oom(),
        );
    }
}

fn parseBlock(p: *NetlistParser) !void {
    const block = try p.p.parseWord();
    if (std.mem.eql(u8, block, "net"))
        try p.parseNet()
    else if (std.mem.eql(u8, block, "cell"))
        try p.parseCell()
    else
        try p.p.err("Unknown block '{s}'", .{block});
}

fn parseName(p: *NetlistParser) ![]const u8 {
    return try p.p.parseWordExtra("_/");
}

const SignalName = struct {
    name: []const u8,
    starts: [Netlist.MAX_INDEXES]u16,
    lens: [Netlist.MAX_INDEXES]u16,
    len: u8,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.writeAll(self.name);
        for (
            self.starts[0..self.len],
            self.lens[0..self.len],
        ) |start, len| {
            if (len <= 1)
                try writer.print("[{}]", .{start})
            else {
                const end = start + len - 1;
                try writer.print("[{}..{}]", .{ start, end });
            }
        }
    }

    pub fn totalCount(self: @This()) usize {
        var r: usize = 1;
        for (self.lens[0..self.len]) |len| {
            r *= len;
        }
        return r;
    }
};

fn parseSignalName(p: *NetlistParser) !SignalName {
    const name = try p.parseName();
    var starts = std.mem.zeroes([Netlist.MAX_INDEXES]u16);
    var lens = std.mem.zeroes([Netlist.MAX_INDEXES]u16);
    var len: u8 = 0;
    while (p.p.check('[')) {
        if (len >= Netlist.MAX_INDEXES)
            try p.p.err(
                "At most {}-dimensional wires are currently supported",
                .{Netlist.MAX_INDEXES},
            );

        try p.p.expect('[');
        const start = try p.p.parseNumber(u16);
        const end: u16 = if (p.p.check('.')) blk: {
            try p.p.expect('.');
            try p.p.expect('.');
            break :blk try p.p.parseNumber(u16);
        } else start;
        try p.p.expect(']');

        starts[len] = start;
        lens[len] = end - start + 1;
        len += 1;
    }

    return .{
        .name = name,
        .starts = starts,
        .lens = lens,
        .len = len,
    };
}

fn parseNet(p: *NetlistParser) !void {
    // 'net' already parsed
    const name = try p.parseSignalName();
    const kind: Netlist.NetKind = if (p.p.check(':')) blk: {
        try p.p.expect(':');
        const word = try p.p.parseWord();

        if (std.mem.eql(u8, word, "clock"))
            break :blk .clock
        else if (std.mem.eql(u8, word, "reset"))
            break :blk .reset
        else
            try p.p.err("Unknown net type: '{s}'", .{word});
    } else .net;

    const net_name_id = p.nl().getNetNameId(name.name, kind);
    const old_kind = p.nl().getNetKind(net_name_id);
    if (kind != .net and kind != old_kind)
        try p.p.err(
            "Net redeclared with a different kind: was '{s}'', became '{s}'",
            .{ @tagName(old_kind), @tagName(kind) },
        );

    const net_count = name.totalCount();
    if (p.p.check(';')) {
        // Just declaration
        try p.p.expect(';');
        // Multiple nets declared
        for (0..net_count) |idx0| {
            var net_key = Netlist.NetKey{
                .name = net_name_id,
                .indexes = name.starts,
                .indexes_len = name.len,
            };
            var idx = idx0;
            for (0..name.len) |i| {
                net_key.indexes[i] += @intCast(idx % name.lens[i]);
                idx /= name.lens[i];
            }
            _ = p.nl().getNetRef(net_key);
        }
        return;
    }

    // Not a declaration, full block
    if (net_count != 1)
        try p.p.err("Only one net can be defined per block, not {}", .{net_count});

    const net_key = Netlist.NetKey{
        .name = net_name_id,
        .indexes = name.starts,
        .indexes_len = name.len,
    };
    const net_ref = p.nl().getNetRef(net_key);

    try p.p.expect('{');
    while (!p.p.checkEof() and !p.p.check('}')) {
        const word = try p.p.parseWord();
        if (std.mem.eql(u8, word, "PERIOD")) { // Clock period
            if (old_kind != .clock)
                try p.p.err(
                    "PERIOD can only be set for clock nets, '{f}' is '{s}'",
                    .{ name, @tagName(kind) },
                );
            const clock_net = p.nl().getGlobalNet(net_ref);
            try p.p.expect('=');
            clock_net.period_ps = try p.p.parseNumber(u32);
            try p.p.expect(';');
        } else if (std.mem.eql(u8, word, "CLK")) { // Clock id
            if (old_kind != .clock)
                try p.p.err(
                    "CLK can only be set for clock nets, '{f}' is '{s}'",
                    .{ name, @tagName(kind) },
                );
            const clock_net = p.nl().getGlobalNet(net_ref);
            try p.p.expect('=');
            clock_net.network = try p.p.parseNumber(u3);
            try p.p.expect(';');
        } else if (std.mem.eql(u8, word, "RST")) { // Reset id
            if (old_kind != .reset)
                try p.p.err(
                    "RST can only be set for reset nets, '{f}' is '{s}'",
                    .{ name, @tagName(kind) },
                );
            const clock_net = p.nl().getGlobalNet(net_ref);
            try p.p.expect('=');
            clock_net.network = try p.p.parseNumber(u2);
            try p.p.expect(';');
        } else if (std.mem.eql(u8, word, "PIN")) { // Reset/clock pin
            if (old_kind != .clock and old_kind != .reset)
                try p.p.err(
                    "PIN can only be set for clock or reset nets, '{f}' is '{s}'",
                    .{ name, @tagName(kind) },
                );
            const global_net = p.nl().getGlobalNet(net_ref);
            try p.p.expect('=');
            global_net.pin = try p.p.parseNumber(u16);
            try p.p.expect(';');
        } else if (std.mem.eql(u8, word, "route")) { // Net route
            if (old_kind != .net)
                try p.p.err(
                    "'route' block can only be set for normal nets, '{f}' is '{s}'",
                    .{ name, @tagName(kind) },
                );
            const net = p.nl().getNet(net_ref);
            try p.parseNetRoute(net);
        } else try p.p.err("Unknown net command: '{s}'", .{word});
    }
    try p.p.expect('}');
}

fn parseNetRoute(p: *NetlistParser, net: *Netlist.Net) !void {
    // 'route' already parsed
    net.route_start = @intCast(p.nl().route_edges.items.len);
    var count: u16 = 0;

    try p.p.expect('{');
    while (!p.p.checkEof() and !p.p.check('}')) {
        const word = try p.p.parseWord();
        if (std.mem.eql(u8, word, "switch")) {
            const sw = try p.p.parseSwitchCoords(&p.nl().model);
            try p.p.expect(':');
            const sink = try p.p.parseSwitchWire() orelse
                try p.p.err("Expected a switch sink like N.L1[3]", .{});

            try p.p.expect('=');
            const source = try p.p.parseSwitchSrc(sw, &p.nl().model);
            try p.p.expect(';');

            const code = wire_codes.encodeSwitchSink(sink, source) orelse
                try p.p.err("For switch sink {f}, source {f} is unencodable", .{ sink, source });
            p.nl().route_edges.append(
                p.nl().alloc,
                .{ .switchbox = .{
                    .at = sw,
                    .dst = sink,
                    .src = code,
                } },
            ) catch common.oom();
        } else blk: {
            inline for (common.TileType.configurable) |t| {
                if (std.mem.eql(u8, word, @tagName(t))) {
                    const tile = try p.p.parseTileCoords(&p.nl().model);
                    const actual = p.nl().model.tileType(tile);
                    if (actual != t)
                        try p.p.err(
                            "Tile ({}, {}) is {s} tile not {s} tile",
                            .{ tile.row, tile.col, @tagName(actual), @tagName(t) },
                        );

                    try p.p.expect(':');
                    const in_word = try p.p.parseWord();
                    if (!std.mem.eql(u8, in_word, "in"))
                        try p.p.err("Tiles can only have inputs in 'route' block", .{});

                    const cxt = p.nl().model.inputCxt(t, tile);
                    const in, const code = try p.p.parseInputCommand(t, cxt);

                    // RouteEdge names its tile variants after TileType, so the
                    // tag is the block keyword we just matched.
                    p.nl().route_edges.append(p.nl().alloc, @unionInit(
                        Netlist.RouteEdge,
                        @tagName(t),
                        .{ .at = tile, .input = in, .src = code },
                    )) catch common.oom();
                    break :blk;
                }
            }

            try p.p.err(
                "Only 'switch', 'logic', 'bram', 'dsp', 'io' routes are possible, not '{s}'",
                .{word},
            );
        }

        count += 1;
    }
    try p.p.expect('}');

    net.route_len = count;
}

fn parseCell(_: *NetlistParser) !void {
    // 'cell' already parsed
    @panic("TODO!");
}

pub const Result = struct {
    netlist: ?*Netlist,
    err: ?[]const u8,

    pub fn deinit(r: Result, alloc: std.mem.Allocator) void {
        if (r.netlist) |netlist| {
            netlist.deinit();
            alloc.destroy(netlist);
        }
        if (r.err) |e|
            alloc.free(e);
    }
};

pub fn parse(input: []const u8, alloc: std.mem.Allocator) Result {
    var p = NetlistParser.init(input, alloc);
    // parseHeader can fail either side of creating the Netlist, so the
    // optional is passed through rather than unwrapped.
    p.parseHeader() catch return Result{
        .netlist = p.netlist,
        .err = p.p.errorText,
    };

    while (!p.p.checkEof())
        p.parseBlock() catch return Result{
            .netlist = p.netlist,
            .err = p.p.errorText,
        };

    return Result{
        .netlist = p.netlist,
        .err = p.p.errorText,
    };
}
