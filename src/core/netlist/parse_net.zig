const std = @import("std");

const common = @import("../common.zig");
const wire_codes = @import("../wire_codes.zig");
const NetlistParser = @import("NetlistParser.zig");
const Net = @import("Net.zig");
const route = @import("route.zig");

const parse_signals = @import("parse_signals.zig");
const parseSignalRange = parse_signals.parseSignalRange;

const NetParam = struct {
    word: []const u8,
    kinds: []const Net.Kind,
    phrase: []const u8,
    field: []const u8,
    T: type,
};

const net_params = [_]NetParam{
    .{
        .word = "PERIOD",
        .kinds = &.{.clock},
        .phrase = "clock nets",
        .field = "period_ps",
        .T = u32,
    },
    .{
        .word = "CLK",
        .kinds = &.{.clock},
        .phrase = "clock nets",
        .field = "network",
        .T = u3,
    },
    .{
        .word = "RST",
        .kinds = &.{.reset},
        .phrase = "reset nets",
        .field = "network",
        .T = u2,
    },
    .{
        .word = "PIN",
        .kinds = &.{ .clock, .reset },
        .phrase = "clock or reset nets",
        .field = "pin",
        .T = u16,
    },
};

pub fn parseNet(p: *NetlistParser) !void {
    // 'net' already parsed
    const signal = try parseSignalRange(p);
    const kind: ?Net.Kind = if (p.p.check(':')) blk: {
        try p.p.expect(':');
        const word = try p.p.parseWord();

        if (std.mem.eql(u8, word, "clock"))
            break :blk .clock
        else if (std.mem.eql(u8, word, "reset"))
            break :blk .reset
        else
            try p.p.err("Unknown net type: '{s}'", .{word});
    } else null;

    const net_base_id = p.nl().net_base_names.intern(signal.name);

    const is_decl = p.p.check(';');

    if (is_decl)
        try p.p.expect(';')
    else if (signal.indexes.count() != 1)
        try p.p.err("Only one net can be defined per block, not {}", .{signal.indexes.count()});

    // A bare `net a;` pins the kind to .net; a block leaves it open, so
    // `net a : clock;` followed by `net a {}` stays legal.
    const decl_kind: ?Net.Kind = if (is_decl) kind orelse .net else kind;

    // Declare all the nets first
    {
        var iter = signal.indexes.iterator();
        while (iter.next()) |indexes| {
            _ = p.nl().defineNet(
                net_base_id,
                indexes,
                decl_kind,
            ) catch {
                const existing_ref = p.nl().findNetRef(net_base_id, indexes).?;
                const existing_net = p.nl().getNet(existing_ref);
                try p.p.err(
                    "Net '{f}' was already defined earlier as '{s}', cannot redefine it as '{s}'",
                    .{ signal, @tagName(existing_net.kind), @tagName(decl_kind.?) },
                );
            };
        }
    }

    if (is_decl)
        return;
    // Not a declaration, full block

    const net_ref = p.nl().findNetRef(net_base_id, signal.indexes.base()).?;
    const net = p.nl().getNet(net_ref);

    try p.p.expect('{');
    while (!p.p.checkEof() and !p.p.check('}')) {
        const word = try p.p.parseWord();
        if (std.mem.eql(u8, word, "route")) { // Net route
            if (net.kind != .net)
                try p.p.err(
                    "'route' block can only be set for normal nets, '{f}' is '{s}'",
                    .{ signal, @tagName(net.kind) },
                );
            try parseNetRoute(p, net_ref);
        } else blk: {
            inline for (net_params) |param| {
                if (std.mem.eql(u8, word, param.word)) {
                    if (std.mem.indexOfScalar(Net.Kind, param.kinds, net.kind) == null)
                        try p.p.err(
                            param.word ++ " can only be set for " ++ param.phrase ++
                                ", '{f}' is '{s}'",
                            .{ signal, @tagName(net.kind) },
                        );

                    try p.p.expect('=');
                    @field(net, param.field) = try p.p.parseNumber(param.T);
                    try p.p.expect(';');
                    break :blk;
                }
            }

            try p.p.err("Unknown net command: '{s}'", .{word});
        }
    }
    try p.p.expect('}');
}

fn parseNetRoute(p: *NetlistParser, net_ref: Net.Ref) !void {
    const net = p.nl().getNet(net_ref);
    // 'route' already parsed
    if (net.route_len != 0)
        try p.p.err("You cannot redefine 'route' for a net", .{});
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
                p.nl().gpa,
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

                    // route.Edge names its tile variants after TileType, so the
                    // tag is the block keyword we just matched.
                    p.nl().route_edges.append(p.nl().gpa, @unionInit(
                        route.Edge,
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
