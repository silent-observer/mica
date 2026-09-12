const std = @import("std");

const common = @import("../common.zig");
const NetlistParser = @import("NetlistParser.zig");
const Cell = @import("Cell.zig");
const Net = @import("Net.zig");
const cell_type = @import("cell_type.zig");
const ports = @import("ports.zig");
const handlePortCommand = @import("parse_ports.zig").handlePortCommand;

const parse_signals = @import("parse_signals.zig");
const SignalSource = parse_signals.SignalSource;
const parseName = parse_signals.parseName;
const parseSignalRange = parse_signals.parseSignalRange;
const parseSignalSource = parse_signals.parseSignalSource;

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

fn getPortsLookupTable(p: *NetlistParser, cell_ref: Cell.Ref) !ports.LookupTable {
    return switch (p.nl().getCell(cell_ref).params) {
        .physical => |params_union| switch (std.meta.activeTag(params_union)) {
            inline else => |pt| comptime ports.buildLookupTable(
                ports.cellEntry(.{ .physical = pt }),
                {},
            ) catch unreachable,
        },
        .logical => |params_union| switch (params_union) {
            inline else => |params, lt| ports.buildLookupTable(
                ports.cellEntry(.{ .logical = lt }),
                params,
            ) catch
                try p.p.err("You must define all WIDTH/DEPTH/N parameters " ++
                    "before input/output ports in the cell", .{}),
        },
    };
}

const slots_table: std.StaticStringMap(Cell.SlotId) = .initComptime(.{
    .{ "LE1", .le1 },
    .{ "LE2", .le2 },
    .{ "LE1A", .le1a },
    .{ "LE2A", .le2a },
    .{ "LE1B", .le1b },
    .{ "LE2B", .le2b },
});

fn parseCommonCellCommand(
    p: *NetlistParser,
    cell_ref: Cell.Ref,
    lookup: *?ports.LookupTable,
) !bool {
    const m = p.p.mark();
    const word = try p.p.parseWord();
    const cell = p.nl().getCell(cell_ref);
    if (std.mem.eql(u8, word, "in") or std.mem.eql(u8, word, "out")) {
        const kind: Cell.PortKind = if (std.mem.eql(u8, word, "in")) .in else .out;
        const port_signal = try parseSignalRange(p);
        try p.p.expect('=');
        const external_signal = if (kind == .in)
            try parseSignalSource(p)
        else
            SignalSource{ .range = try parseSignalRange(p) };
        try p.p.expect(';');

        if (lookup.* == null)
            lookup.* = try getPortsLookupTable(p, cell_ref);
        p.nl().allocateCellPorts(cell_ref, lookup.*.?.total);

        const port_count = port_signal.indexes.count();
        const external_count = switch (external_signal) {
            .range => |r| r.indexes.count(),
            .zero, .one => 1,
        };

        const net_base_id = switch (external_signal) {
            .range => |r| p.nl().net_base_names.find(r.name) orelse
                try p.p.err("Couldn't find net {f}", .{r}),
            .zero, .one => null,
        };

        var net_refs = p.arena.allocator().alloc(Net.Ref, port_count) catch common.oom();
        if (external_count == 1) {
            const net_ref: Net.Ref = switch (external_signal) {
                .range => |r| p.nl().findNetRef(net_base_id.?, r.indexes.base()) orelse
                    try p.p.err("Couldn't find net {f}", .{external_signal}),
                .zero => .zero,
                .one => .one,
            };
            @memset(net_refs, net_ref);
        } else if (external_count == port_count) {
            var i: usize = 0;
            var iter_external = external_signal.range.indexes.iterator();
            while (iter_external.next()) |indexes| {
                net_refs[i] = p.nl().findNetRef(net_base_id.?, indexes) orelse
                    try p.p.err("Couldn't find net {s}{f}", .{ external_signal.range.name, indexes });
                i += 1;
            }
        } else try p.p.err("Counts of {f} and {f} don't match: {} != {}", .{
            port_signal,
            external_signal,
            port_count,
            external_count,
        });

        try handlePortCommand(
            p,
            &lookup.*.?,
            kind,
            port_signal,
            net_refs,
            cell_ref,
        );
    } else if (std.mem.eql(u8, word, "PACK")) {
        try p.p.expect('=');
        const pack_word = try parseName(p);
        try p.p.expect(';');

        const new_pack = p.nl().pack_names.intern(pack_word);
        if (cell.pack != .none and cell.pack != new_pack)
            try p.p.err(
                "Cell already has an old PACK = '{s}'",
                .{p.nl().pack_names.get(cell.pack)},
            );
        cell.pack = new_pack;
    } else if (std.mem.eql(u8, word, "SLOT")) {
        try p.p.expect('=');
        const slot_word = try p.p.parseWord();
        try p.p.expect(';');

        const new_slot = slots_table.get(slot_word) orelse
            try p.p.err(
                "Invalid slot name: '{s}', only LE[12][AB]? are supported",
                .{slot_word},
            );

        if (cell.slot != .none and cell.slot != new_slot)
            try p.p.err(
                "Cell already has an old SLOT = '{s}'",
                .{@tagName(cell.slot)},
            );
        cell.slot = new_slot;
    } else if (std.mem.eql(u8, word, "SITE")) {
        try p.p.expect('=');
        const new_site = try p.p.parseTileCoords(&p.nl().model);
        try p.p.expect(';');

        if (cell.site != null and !std.meta.eql(cell.site.?, new_site))
            try p.p.err(
                "Cell already has an old SITE = ({}, {})",
                .{ cell.site.?.row, cell.site.?.col },
            );
        cell.site = new_site;
    } else {
        p.p.reset(m);
        return false;
    }

    return true;
}

fn parseCellBody(p: *NetlistParser, cell_ref: Cell.Ref) !void {
    var lookup: ?ports.LookupTable = null;

    try p.p.expect('{');
    outer: while (!p.p.checkEof() and !p.p.check('}')) {
        _ = p.arena.reset(.retain_capacity);
        if (try parseCommonCellCommand(p, cell_ref, &lookup)) continue;

        const cell = p.nl().getCell(cell_ref);
        const param_name = try p.p.parseWord();
        switch (cell.params) {
            inline else => |*kind_params| switch (kind_params.*) {
                inline else => |*params| {
                    inline for (std.meta.fields(@TypeOf(params.*))) |f| {
                        if (std.mem.eql(u8, param_name, comptime common.upper(f.name))) {
                            try p.p.expect('=');
                            const V = @typeInfo(f.type).optional.child;
                            const new_val = try parseParamValue(p, V);
                            const old_val = @field(params.*, f.name);
                            if (old_val != null and old_val != new_val)
                                try p.p.err("Trying to redefine '{s}'", .{f.name});
                            @field(params.*, f.name) = new_val;
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

pub fn parseCell(p: *NetlistParser) !void {
    // 'cell' already parsed
    const name = try parseName(p);
    const new_t: ?cell_type.Full = if (p.p.check(':')) blk: {
        try p.p.expect(':');

        if (p.p.check('$')) {
            try p.p.expect('$');
            const word = try p.p.parseWord();
            if (cell_type.Logical.lookup.get(word)) |c|
                break :blk .{ .logical = c }
            else
                try p.p.err("Unknown cell type: '${s}'", .{word});
        } else {
            const word = try p.p.parseWord();
            if (cell_type.Physical.lookup.get(word)) |c|
                break :blk .{ .physical = c }
            else
                try p.p.err("Unknown cell type: '{s}'", .{word});
        }
    } else null;

    const cell_ref = p.nl().internCellRef(name, new_t) catch |e| switch (e) {
        error.UnknownCellType => try p.p.err("Cell type for '{s}' was not specified", .{name}),
        error.CellTypeConflict => try p.p.err(
            "Cell '{s}' redeclared with a different type '{f}'",
            .{ name, new_t.? },
        ),
    };
    try parseCellBody(p, cell_ref);
}
