const std = @import("std");

const common = @import("../common.zig");
const wire_codes = @import("../wire_codes.zig");
const Netlist = @import("Netlist.zig");
const DeviceModel = @import("../DeviceModel.zig");
const CommonParser = @import("../CommonParser.zig");
const Indexes = @import("Indexes.zig");
const ports = @import("ports.zig");

const NetlistParser = @This();

p: CommonParser,
netlist: ?*Netlist,
arena: std.heap.ArenaAllocator,

fn init(input: []const u8, alloc: std.mem.Allocator) NetlistParser {
    return .{
        .p = .init(input, alloc),
        .netlist = null,
        .arena = .init(alloc),
    };
}

fn deinit(p: *NetlistParser) void {
    p.arena.deinit();
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

const NetParam = struct {
    word: []const u8,
    kinds: []const Netlist.Net.Kind,
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

fn parseHeader(p: *NetlistParser) !void {
    const model = try p.p.parseFormatAndDevice();

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

const SignalRange = struct {
    name: []const u8,
    indexes: Indexes.Range,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("{s}{f}", .{ self.name, self.indexes });
    }
};

fn parseSignalRange(p: *NetlistParser) !SignalRange {
    const name = try p.parseName();
    var range: Indexes.Range = .empty;
    while (p.p.check('[')) {
        if (range.len() >= Indexes.MAX_INDEXES)
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

        range.addStartEnd(start, end);
    }

    return .{
        .name = name,
        .indexes = range,
    };
}

fn parseNet(p: *NetlistParser) !void {
    // 'net' already parsed
    const signal = try p.parseSignalRange();
    const kind: ?Netlist.Net.Kind = if (p.p.check(':')) blk: {
        try p.p.expect(':');
        const word = try p.p.parseWord();

        if (std.mem.eql(u8, word, "clock"))
            break :blk .clock
        else if (std.mem.eql(u8, word, "reset"))
            break :blk .reset
        else
            try p.p.err("Unknown net type: '{s}'", .{word});
    } else null;

    const net_base_id = p.nl().internNetBaseId(signal.name);

    if (p.p.check(';')) {
        // Just declaration
        try p.p.expect(';');
        // Multiple nets declared
        var iter = signal.indexes.iterator();
        while (iter.next()) |indexes| {
            _ = p.nl().defineNet(
                net_base_id,
                indexes,
                kind orelse .net,
            ) catch {
                const existing_ref = p.nl().findNetRef(net_base_id, indexes).?;
                const existing_net = p.nl().getNet(existing_ref);
                try p.p.err(
                    "Net '{f}' was already defined earlier as '{s}', cannot redefine it as '{s}'",
                    .{ signal, @tagName(existing_net.kind), @tagName(kind orelse .net) },
                );
            };
        }
        return;
    }

    // Not a declaration, full block
    const net_count = signal.indexes.count();
    if (net_count != 1)
        try p.p.err("Only one net can be defined per block, not {}", .{net_count});

    const net_ref = p.nl().defineNet(
        net_base_id,
        signal.indexes.base,
        kind,
    ) catch {
        const existing_ref = p.nl().findNetRef(net_base_id, signal.indexes.base).?;
        const existing_net = p.nl().getNet(existing_ref);
        try p.p.err(
            "Net '{f}' was already defined earlier as '{s}', cannot redefine it as '{s}'",
            .{ signal, @tagName(existing_net.kind), @tagName(kind.?) },
        );
    };

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
            try p.parseNetRoute(net);
        } else blk: {
            inline for (net_params) |param| {
                if (std.mem.eql(u8, word, param.word)) {
                    if (std.mem.indexOfScalar(Netlist.Net.Kind, param.kinds, net.kind) == null)
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

pub const logical_cell_types: std.StaticStringMap(Netlist.CellType) = .initComptime(blk: {
    const logi = std.enums.values(Netlist.CellType.Logical);
    var entries: [logi.len]struct { []const u8, Netlist.CellType } = undefined;
    for (logi, &entries) |t, *entry|
        entry.* = .{ @tagName(t), .{ .logical = t } };
    break :blk entries;
});

pub const physical_cell_types: std.StaticStringMap(Netlist.CellType) = .initComptime(blk: {
    const phys = std.enums.values(Netlist.CellType.Physical);
    var entries: [phys.len]struct { []const u8, Netlist.CellType } = undefined;
    for (phys, &entries) |t, *entry|
        entry.* = .{
            Netlist.CellType.Physical.names.get(t),
            .{ .physical = t },
        };
    break :blk entries;
});

const slots_table: std.StaticStringMap(Netlist.Cell.SlotId) = .initComptime(.{
    .{ "LE1", .le1 },
    .{ "LE2", .le2 },
    .{ "LE1A", .le1a },
    .{ "LE2A", .le2a },
    .{ "LE1B", .le1b },
    .{ "LE2B", .le2b },
});

const clk_rst_table: std.StaticStringMap(Netlist.Net.Kind) = .initComptime(.{
    .{ "CLK", .clock },
    .{ "RST", .reset },
});

fn parsePortCommand(
    p: *NetlistParser,
    comptime entry: ports.CellEntry,
    lookup_table: ports.LookupTable,
    kind: Netlist.Cell.PortKind,
    port_signal: SignalRange,
    net_refs: []Netlist.Net.Ref,
    cell: *Netlist.Cell,
) !void {
    std.debug.assert(port_signal.indexes.count() == net_refs.len);

    if (entry.clk and kind == .in and clk_rst_table.get(port_signal.name) != null) {
        const net_kind = clk_rst_table.get(port_signal.name).?;

        if (port_signal.indexes.len() != 0)
            try p.p.err(
                "Port {s} can't have indexes: '{f}'",
                .{ port_signal.name, port_signal },
            );
        const net_ref = net_refs[0];
        if (net_ref == .unbound or net_ref == .zero or net_ref == .one)
            try p.p.err(
                "Port {s} cannot be {s}",
                .{ port_signal.name, @tagName(net_ref) },
            );

        const net = p.nl().getNet(net_ref);
        if (net.kind != net_kind)
            try p.p.err(
                "Port {s} can only be attached to {s}-type net, {f} is '{s}'",
                .{ port_signal.name, @tagName(net_kind), net.fmt(p.nl()), @tagName(net.kind) },
            );

        const target = if (net_kind == .clock) &cell.clk else &cell.rst;

        if (target.* != .unbound and target.* != net_ref) {
            const old_net = p.nl().getNet(net_ref);
            try p.p.err(
                "Port {s} was earlier bound to {f}",
                .{ port_signal.name, old_net.fmt(p.nl()) },
            );
        }

        target.* = net_ref;
    } else {
        inline for (entry.entries, 0..) |e, e_idx| {
            if (e.kind == kind and std.mem.eql(u8, e.name, port_signal.name)) {
                const lookup = lookup_table.ports[e_idx];
                var port_iter = port_signal.indexes.iterator();
                var pos: usize = 0;
                while (port_iter.next()) |port_indexes| {
                    const index = lookup.full_range.toIndex(port_indexes) orelse
                        try p.p.err(
                            "Port {s} only goes through {f}, {f} is not inside that",
                            .{ port_signal.name, lookup.full_range, port_indexes },
                        );
                    const port = p.nl().getCellPort(cell, @intCast(lookup.base + index));
                    port.* = net_refs[pos];
                    pos += 1;
                }
            }
        }
    }
}

fn parseCommonCellCommand(
    p: *NetlistParser,
    cell: *Netlist.Cell,
    lookup: ports.LookupTable,
) !bool {
    const m = p.p.mark();
    const word = try p.p.parseWord();
    if (std.mem.eql(u8, word, "in") or std.mem.eql(u8, word, "out")) {
        const kind: Netlist.Cell.PortKind = if (std.mem.eql(u8, word, "in")) .in else .out;
        const port_signal = try p.parseSignalRange();
        try p.p.expect('=');
        const external_signal = try p.parseSignalRange();
        try p.p.expect(';');

        p.nl().allocateCellPorts(cell, lookup.total);

        const port_count = port_signal.indexes.count();
        const external_count = external_signal.indexes.count();

        const net_base_id = p.nl().findNetBaseId(external_signal.name) orelse
            try p.p.err("Couldn't find net {f}", .{external_signal});

        var net_refs = p.arena.allocator().alloc(Netlist.Net.Ref, port_count) catch common.oom();
        if (external_count == 1) {
            const net_ref = p.nl().findNetRef(net_base_id, external_signal.indexes.base) orelse
                try p.p.err("Couldn't find net {f}", .{external_signal});
            @memset(net_refs, net_ref);
        } else if (external_count == port_count) {
            var i: usize = 0;
            var iter_external = external_signal.indexes.iterator();
            while (iter_external.next()) |indexes| {
                net_refs[i] = p.nl().findNetRef(net_base_id, indexes) orelse
                    try p.p.err("Couldn't find net {s}{f}", .{ external_signal.name, indexes });
                i += 1;
            }
        } else try p.p.err("Counts of {f} and {f} don't match: {} != {}", .{
            port_signal,
            external_signal,
            port_count,
            external_count,
        });

        switch (cell.cellType()) {
            inline else => |ct| switch (ct) {
                inline else => |cct| {
                    try p.parsePortCommand(
                        ports.cellEntry(cct),
                        lookup,
                        kind,
                        port_signal,
                        net_refs,
                        cell,
                    );
                },
            },
        }
    } else if (std.mem.eql(u8, word, "PACK")) {
        try p.p.expect('=');
        const pack_word = try p.parseName();
        cell.pack = p.nl().internPackId(pack_word);
        try p.p.expect(';');
    } else if (std.mem.eql(u8, word, "SLOT")) {
        try p.p.expect('=');
        const slot_word = try p.parseName();
        cell.slot = if (slots_table.get(slot_word)) |s|
            s
        else
            try p.p.err(
                "Invalid slot name: '{s}', only LE[12][AB]? are supported",
                .{slot_word},
            );
        try p.p.expect(';');
    } else if (std.mem.eql(u8, word, "SITE")) {
        try p.p.expect('=');
        cell.site = try p.p.parseTileCoords(&p.nl().model);
        try p.p.expect(';');
    } else {
        p.p.reset(m);
        return false;
    }

    return true;
}

fn parseParamValue(p: *NetlistParser, comptime V: type) !V {
    return switch (V) {
        common.BramWidth => switch (try p.p.parseNumber(u16)) {
            1 => .w1,
            2 => .w2,
            4 => .w4,
            8 => .w8,
            16 => .w16,
            else => |x| try p.p.err(
                "BRAM width can only be 1, 2, 4, 8 or 16, not {}",
                .{x},
            ),
        },
        else => try p.p.parseNumber(V),
    };
}

fn getPortsLookupTable(p: *NetlistParser, cell: *const Netlist.Cell) !ports.LookupTable {
    return switch (cell.params) {
        .physical => |params_union| switch (std.meta.activeTag(params_union)) {
            inline else => |pt| comptime ports.buildLookupTable(
                ports.physical_cells.get(pt),
                {},
            ) catch unreachable,
        },
        .logical => |params_union| switch (params_union) {
            inline else => |params, tag| ports.buildLookupTable(
                ports.logical_cells.get(tag),
                params,
            ) catch
                try p.p.err("You must define all WIDTH/DEPTH/N parameters " ++
                    "before input/output ports in the cell", .{}),
        },
    };
}

fn parseCellBody(p: *NetlistParser, cell: *Netlist.Cell) !void {
    const lookup = try p.getPortsLookupTable(cell);

    try p.p.expect('{');
    outer: while (!p.p.checkEof() and !p.p.check('}')) {
        _ = p.arena.reset(.retain_capacity);
        if (try p.parseCommonCellCommand(cell, lookup)) continue;

        const param_name = try p.p.parseWord();
        switch (cell.params) {
            inline else => |*kind_params| switch (kind_params.*) {
                inline else => |*params| {
                    inline for (std.meta.fields(@TypeOf(params.*))) |f| {
                        if (std.mem.eql(u8, param_name, comptime common.upper(f.name))) {
                            try p.p.expect('=');
                            const V = @typeInfo(f.type).optional.child;
                            @field(params.*, f.name) =
                                try p.parseParamValue(V);
                            try p.p.expect(';');
                            continue :outer;
                        }
                    }
                },
            },
        }
        // Fell through every field of the active Params struct.
        try p.p.err(
            "Cell '{f}' has no parameter '{s}'",
            .{ cell.cellType(), param_name },
        );
    }
    try p.p.expect('}');
}

fn parseCell(p: *NetlistParser) !void {
    // 'cell' already parsed
    const name = try p.parseName();
    const new_t: ?Netlist.CellType = if (p.p.check(':')) blk: {
        try p.p.expect(':');

        if (p.p.check('$')) {
            try p.p.expect('$');
            const word = try p.p.parseWord();
            if (logical_cell_types.get(word)) |c|
                break :blk c
            else
                try p.p.err("Unknown cell type: '${s}'", .{word});
        } else {
            const word = try p.p.parseWord();
            if (physical_cell_types.get(word)) |c|
                break :blk c
            else
                try p.p.err("Unknown cell type: '{s}'", .{word});
        }
    } else null;

    const cell_id = p.nl().getCellRef(name, new_t) catch |e| switch (e) {
        error.UnknownCellType => try p.p.err("Cell type for '{s}' was not specified", .{name}),
        error.CellTypeConflict => try p.p.err(
            "Cell '{s}' redeclared with a different type '{f}'",
            .{ name, new_t.? },
        ),
    };
    const cell = p.nl().getCell(cell_id);
    try p.parseCellBody(cell);
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

test "net kind is fixed at first mention" {
    const header = "format 1;\ndevice \"M1/S\";\ndesign \"t\";\n";
    const cases = [_]struct { src: []const u8, want: ?[]const u8 }{
        // A kind may be restated as long as it agrees, in either order.
        .{ .src = "net a : clock;\nnet a {}\n", .want = null },
        .{ .src = "net a : clock;\nnet a : clock {}\n", .want = null },
        .{ .src = "net a;\nnet a {}\n", .want = null },
        // Contradicting an explicit kind.
        .{
            .src = "net a : clock;\nnet a : reset {}\n",
            .want = "was already defined earlier as 'clock'",
        },
        // Annotating a name that an earlier mention already pinned to .net.
        .{
            .src = "net a;\nnet a : clock {}\n",
            .want = "was already defined earlier as 'net'",
        },
    };

    for (cases) |case| {
        const src = try std.mem.concat(
            std.testing.allocator,
            u8,
            &.{ header, case.src },
        );
        defer std.testing.allocator.free(src);

        const r = parse(src, std.testing.allocator);
        defer r.deinit(std.testing.allocator);

        if (case.want) |want| {
            try std.testing.expect(r.err != null);
            try std.testing.expect(std.mem.indexOf(u8, r.err.?, want) != null);
        } else {
            if (r.err) |e|
                std.debug.print("{s}\n", .{e});
            try std.testing.expectEqual(@as(?[]const u8, null), r.err);
        }
    }
}
