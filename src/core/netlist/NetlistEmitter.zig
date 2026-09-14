//! `Netlist` back to `.mnl` text, in the canonical form "Blocks" describes:
//! all net declarations, then all cell blocks, then all net blocks. Like the
//! bitstream's `TextEmitter` it never fails - anything that would otherwise
//! stop it is recorded with `warn()` and emission continues.

const std = @import("std");

const common = @import("../common.zig");
const wire_codes = @import("../wire_codes.zig");
const Netlist = @import("Netlist.zig");
const Indexes = @import("Indexes.zig");
const MemData = @import("MemData.zig");
const ports = @import("ports.zig");
const cell_type = @import("cell_type.zig");

const NetlistEmitter = @This();

nl: *const Netlist,
alloc: std.mem.Allocator,
w: std.Io.Writer.Allocating,
indent: []const u8,
sorted_nets: []Netlist.Net.Ref,

warnings: std.ArrayList([]const u8),

pub const Result = struct {
    text: []const u8,
    warnings: []const []const u8,

    pub fn deinit(r: Result, alloc: std.mem.Allocator) void {
        alloc.free(r.text);
        for (r.warnings) |warning|
            alloc.free(warning);
        alloc.free(r.warnings);
    }
};

fn init(nl: *const Netlist, alloc: std.mem.Allocator) NetlistEmitter {
    return .{
        .w = .init(alloc),
        .alloc = alloc,
        .nl = nl,
        .warnings = .empty,
        .indent = "",
        .sorted_nets = &.{},
    };
}

fn finish(e: *NetlistEmitter) []const u8 {
    return e.w.toOwnedSlice() catch common.oom();
}

/// Records a problem with the netlist without abandoning the conversion
fn warn(e: *NetlistEmitter, comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.allocPrint(e.alloc, fmt, args) catch common.oom();
    e.warnings.append(e.alloc, msg) catch common.oom();
}

fn emitMeta(e: *NetlistEmitter, list: Netlist.Meta.List) !void {
    const w = &e.w.writer;
    var meta_ref = list.head;
    while (meta_ref != .none) {
        const meta = e.nl.metadata.items[@intFromEnum(meta_ref)];
        const tag = e.nl.meta_tags.get(meta.tag);
        if (meta.data.len == 0)
            try w.print("{s}@{s};\n", .{ e.indent, tag })
        else
            try w.print("{s}@{s} {s};\n", .{ e.indent, tag, meta.data });
        meta_ref = meta.next;
    }
}

fn emitHeader(e: *NetlistEmitter) !void {
    const w = &e.w.writer;
    try w.print(
        "format 1;\n" ++
            "device \"{s}\";\n" ++
            "design \"{s}\";\n",
        .{ e.nl.model.model_id, e.nl.design_name },
    );

    // `EnumMap.iterator` wants a mutable map, and the netlist is const here.
    var passes = e.nl.passes;
    var iter = passes.iterator();
    var first = true;
    while (iter.next()) |entry| {
        if (first) {
            try w.writeByte('\n');
            first = false;
        }
        try w.print(
            "pass {s} \"{s}\";\n",
            .{ @tagName(entry.key), entry.value.* },
        );
    }

    if (e.nl.meta.head != .none) {
        try w.writeByte('\n');
        try e.emitMeta(e.nl.meta);
    }
}

/// Folds a list of one-element groups into as few as adjacent merging can
/// reach: `mergeInto` grows `a` by `b` and says whether the two tile, and each
/// pass compacts what is left of the list in place. A pass that merges nothing
/// ends it, and every other pass shortens the list, so it terminates - one pass
/// per dimension in practice, since a row has to be whole before the row below
/// can join it.
///
/// Greedy and left to right, so not always the fewest groups possible - but it
/// is a function of the netlist alone, which is what the canonical form needs.
fn mergeAdjacent(
    comptime Group: type,
    groups: []Group,
    comptime mergeInto: fn (*Group, Group) bool,
) []Group {
    var list = groups;
    while (list.len > 1) {
        var kept: usize = 0;
        for (list[1..]) |group| {
            if (mergeInto(&list[kept], group)) continue;
            kept += 1;
            list[kept] = group;
        }
        if (kept + 1 == list.len) break;
        list = list[0 .. kept + 1];
    }
    return list;
}

const NetGroup = struct {
    name: Netlist.Net.BaseId,
    kind: Netlist.Net.Kind,
    range: Indexes.Range,

    fn mergeInto(a: *NetGroup, b: NetGroup) bool {
        if (a.name != b.name or a.kind != b.kind) return false;
        a.range = a.range.concat(b.range) orelse return false;
        return true;
    }
};

fn emitNetDecls(e: *NetlistEmitter) !void {
    var groups = std.ArrayList(NetGroup)
        .initCapacity(e.alloc, e.sorted_nets.len) catch common.oom();
    defer groups.deinit(e.alloc);

    // One group per net to start with
    for (e.sorted_nets) |ref| {
        const net = e.nl.getNet(ref);
        groups.appendAssumeCapacity(.{
            .name = net.name,
            .kind = net.kind,
            .range = .single(net.indexes),
        });
    }

    const w = &e.w.writer;
    for (mergeAdjacent(NetGroup, groups.items, NetGroup.mergeInto)) |g| {
        try w.print("net {s}{f}", .{
            e.nl.net_base_names.get(g.name),
            g.range,
        });
        if (g.kind != .net) {
            try w.print(" : {s}", .{@tagName(g.kind)});
        }
        try w.writeAll(";\n");
    }
}

/// A blank line between two sections of a block body, `body_start` being the
/// length the buffer had when the body opened - so the first section present
/// is not preceded by one, whichever it turns out to be.
fn section(e: *NetlistEmitter, body_start: usize) !void {
    if (e.w.written().len != body_start)
        try e.w.writer.writeByte('\n');
}

/// Whether a net carries anything a declaration alone cannot say.
fn hasBody(net: *const Netlist.Net) bool {
    return net.meta.head != .none or
        net.network != null or
        net.period_ps != null or
        net.pin != null or
        net.route_len != 0;
}

/// A `route {}` body is bitstream routing lines grouped by net instead of by
/// tile, so the wire spellings here are the ones `TextEmitter` writes - a
/// switch source in particular needs `plusSwitch` to name the tile it comes
/// out of.
fn emitRoute(e: *NetlistEmitter, net: *const Netlist.Net) !void {
    const w = &e.w.writer;
    try w.print("{s}route {{\n", .{e.indent});

    e.indent = "        ";
    defer e.indent = "    ";

    for (e.nl.route_edges.items[net.route_start..][0..net.route_len]) |edge|
        switch (edge) {
            .switchbox => |s| {
                const src = wire_codes.resolveSwitchSink(
                    s.at,
                    s.dst,
                    s.src,
                    e.nl.model.grid,
                );
                if (src == .code)
                    e.warn(
                        "switch ({}, {}) {f}: code {} names a wire that does not exist here",
                        .{ s.at.row, s.at.col, s.dst, s.src },
                    );
                try w.print("{s}switch ({}, {}): {f} = {f};\n", .{
                    e.indent,
                    s.at.row,
                    s.at.col,
                    s.dst,
                    src.plusSwitch(s.at, &e.nl.model),
                });
            },
            inline else => |s, tag| {
                const t: common.TileType = @field(common.TileType, @tagName(tag));
                const src = wire_codes.resolveInput(
                    t,
                    s.at,
                    s.input,
                    s.src,
                    e.nl.model,
                );
                if (src == .code)
                    e.warn(
                        @tagName(tag) ++ " ({}, {}) in {f}: code {} names a wire that does not exist here",
                        .{ s.at.row, s.at.col, s.input, s.src },
                    );
                try w.print("{s}" ++ @tagName(tag) ++ " ({}, {}): in {f} = {f};\n", .{
                    e.indent,
                    s.at.row,
                    s.at.col,
                    s.input,
                    src,
                });
            },
        };

    // The closing brace belongs to the net block, not to the lines above it.
    try w.writeAll("    }\n");
}

fn emitNet(e: *NetlistEmitter, net: *const Netlist.Net) !void {
    const w = &e.w.writer;
    try w.print("net {f}", .{net.fmt(e.nl)});

    if (net.kind != .net) {
        try w.print(" : {s}", .{@tagName(net.kind)});
    }
    try w.writeAll(" {\n");

    {
        e.indent = "    ";
        defer e.indent = "";
        const body_start = e.w.written().len;

        // The three parameters below are each restricted to some net kinds
        // ("Nets"), so a netlist built by hand can hold one the parser would
        // not take back. Dropping it would lose information, so it is written
        // anyway and the disagreement is warned about instead.
        if (net.period_ps) |period| {
            if (net.kind != .clock)
                e.warn("Net {f} has a PERIOD but is a '{s}', not a clock", .{
                    net.fmt(e.nl),
                    @tagName(net.kind),
                });
            try w.print("{s}PERIOD = {};\n", .{ e.indent, period });
        }

        if (net.network) |network|
            switch (net.kind) {
                // There is no keyword for this one: a plain net has no global
                // network, so the number has nowhere to go.
                .net => e.warn("Net {f} is a plain net but has network number {}", .{
                    net.fmt(e.nl),
                    network,
                }),
                .clock => try w.print("{s}CLK = {};\n", .{ e.indent, network }),
                .reset => try w.print("{s}RST = {};\n", .{ e.indent, network }),
            };

        if (net.pin) |pin| {
            if (net.kind == .net)
                e.warn("Net {f} has a PIN but is a plain net", .{net.fmt(e.nl)});
            try w.print("{s}PIN = {};\n", .{ e.indent, pin });
        }

        if (net.route_len != 0) {
            try e.section(body_start);
            try e.emitRoute(net);
        }

        if (net.meta.head != .none) {
            try e.section(body_start);
            try e.emitMeta(net.meta);
        }
    }

    try w.writeAll("}\n");
}

fn emitCellParams(e: *NetlistEmitter, cell: *const Netlist.Cell) !void {
    const w = &e.w.writer;
    switch (cell.params) {
        inline else => |params_union, tag| switch (params_union) {
            inline else => |params, t| {
                inline for (std.meta.fields(@TypeOf(params))) |f| {
                    if (@field(params, f.name)) |v| {
                        const param = comptime common.upper(f.name);
                        try w.print("{s}{s} = ", .{ e.indent, param });

                        // Contents-shaped parameters read better in hex, the
                        // way the bitstream writes them; counts do not.
                        const hex = comptime if (tag == .physical)
                            switch (t) {
                                .lut4, .lut3, .carry, .mem, .mem_dual => true,
                                else => false,
                            }
                        else
                            false;

                        if (@TypeOf(v) == bool)
                            try w.print("{};\n", .{@intFromBool(v)})
                        else if (@TypeOf(v) == common.BramWidth)
                            try w.print("{};\n", .{v.int()})
                        else if (@typeInfo(@TypeOf(v)) == .int) {
                            const fmt = comptime if (hex) switch (@TypeOf(v)) {
                                u8 => "0x{X:0>2};\n",
                                u16 => "0x{X:0>4};\n",
                                u32 => "0x{X:0>8};\n",
                                else => unreachable,
                            } else "{};\n";
                            try w.print(fmt, .{v});
                        } else @compileError("No way to print a " ++ @typeName(@TypeOf(v)));
                    }
                }
            },
        },
    }
}

/// Hex digits `value` needs, at least one: an address of a `depth`-entry
/// memory or an entry of `data_width` bits.
fn hexDigits(bits: u16) u16 {
    return @max(1, (bits + 3) / 4);
}

/// Writes `value` as exactly `digits` uppercase hex digits.
fn emitHex(e: *NetlistEmitter, value: u32, digits: u16) !void {
    std.debug.assert(digits >= 1 and digits <= 8);
    const w = &e.w.writer;
    var i = digits;
    while (i > 0) {
        i -= 1;
        const nibble: u4 = @truncate(value >> @intCast(i * 4));
        try w.writeByte(std.fmt.digitToChar(nibble, .upper));
    }
}

/// Writes one entry straight out of its slot rather than through an integer,
/// since `data_width` goes up to `common.mem_max_data_width`. The slot holds
/// whole bytes, so a width like 12 leaves one leading nibble of padding that
/// `CommonParser.parseMemSlot` guarantees is zero; drop it.
fn emitSlot(e: *NetlistEmitter, slot: []const u8, digits: u16) !void {
    const w = &e.w.writer;
    var i = slot.len * 2 - digits;
    while (i < slot.len * 2) : (i += 1) {
        const byte = slot[i / 2];
        const nibble: u4 = if (i % 2 == 0) @truncate(byte >> 4) else @truncate(byte);
        try w.writeByte(std.fmt.digitToChar(nibble, .upper));
    }
}

/// Emission is driven by `present`, not by which entries are non-zero: unlike
/// the bitstream's `data {}` the netlist distinguishes an entry written as 0
/// from one never written, and the iterator skips empty words, which matters
/// when a `$rom` is 2^24 entries deep and ten of them are live.
///
/// A line covers one run of consecutive present addresses, broken every eight
/// entries on an eight-aligned address - so dense data lines up in the same
/// columns the bitstream emitter produces, and sparse data costs one line per
/// run instead of a screen of filler.
fn emitMemData(e: *NetlistEmitter, data: *const MemData) !void {
    if (data.present.findFirstSet() == null) return;

    const w = &e.w.writer;
    try w.writeAll(e.indent);
    try w.writeAll("data {\n");

    {
        e.indent = "        ";
        defer e.indent = "    ";

        const addr_digits = hexDigits(std.math.log2_int(u32, data.depth));
        const value_digits = hexDigits(data.data_width);

        // Whether a line is open, and the address it would continue with.
        var open = false;
        var next_addr: u32 = 0;

        var iter = data.present.iterator(.{});
        while (iter.next()) |bit| {
            const addr: u32 = @intCast(bit);

            if (open and addr != next_addr) {
                try w.writeAll(";\n");
                open = false;
            }
            if (!open) {
                try w.writeAll(e.indent);
                try e.emitHex(addr, addr_digits);
                try w.writeByte(':');
                open = true;
            }

            try w.writeByte(' ');
            try e.emitSlot(data.constSlot(addr), value_digits);

            // `addr + 1` cannot wrap: `depth` is at most `1 << 24`.
            next_addr = addr + 1;
            if (addr % 8 == 7) {
                try w.writeAll(";\n");
                open = false;
            }
        }
        if (open) try w.writeAll(";\n");
    }

    try w.writeAll(e.indent);
    try w.writeAll("}\n");
}

/// Whether `emitCellPorts` has anything to print, which decides whether the
/// blank line before it is wanted. Reading the span directly avoids building
/// the lookup table twice.
fn hasPorts(e: *const NetlistEmitter, cell: *const Netlist.Cell) bool {
    if (cell.clk != .none or cell.rst != .none) return true;
    for (e.nl.port_nets.items[cell.ports_start..][0..cell.ports_len]) |ref|
        if (ref != .none) return true;
    return false;
}

const PortGroup = struct {
    port_range: Indexes.Range,
    /// The first bit's binding, which is every bit's binding while `uniform`.
    ref: Netlist.Net.Ref,
    uniform: bool,
    net: ?NetSource,

    const NetSource = struct {
        base: Netlist.Net.BaseId,
        range: Indexes.Range,
    };

    fn mergeInto(a: *PortGroup, b: PortGroup) bool {
        const port_range = a.port_range.concat(b.port_range) orelse return false;

        // One net driving both boxes drives the union of them
        if (a.uniform and b.uniform and a.ref == b.ref) {
            a.port_range = port_range;
            a.net = null;
            return true;
        }

        // Otherwise the nets have to tile the way the port bits do
        const a_net = a.net orelse return false;
        const b_net = b.net orelse return false;
        if (a_net.base != b_net.base) return false;
        const range = a_net.range.concat(b_net.range) orelse return false;

        a.port_range = port_range;
        a.net = .{ .base = a_net.base, .range = range };
        a.uniform = false;
        return true;
    }
};

fn emitCellPortRanges(
    e: *NetlistEmitter,
    entry: ports.Entry,
    lookup: ports.LookupTable.PerPort,
    net_refs: []const Netlist.Net.Ref,
) !void {
    const w = &e.w.writer;
    // Fast path for single-wire ports
    if (lookup.count == 1) {
        const net_ref = net_refs[0];
        if (net_ref != .none)
            try w.print("{s}{s} {s}{f} = {f};\n", .{
                e.indent,
                @tagName(entry.kind),
                entry.name,
                lookup.full_range.base(),
                net_ref.fmt(e.nl),
            });
        return;
    }

    var groups = std.ArrayList(PortGroup)
        .initCapacity(e.alloc, net_refs.len) catch common.oom();
    defer groups.deinit(e.alloc);

    // Fill groups from nets we're trying to assign, one group per net
    var iter = lookup.full_range.iterator();
    var idx: usize = 0;
    while (iter.next()) |port_indexes| : (idx += 1) {
        const net_ref = net_refs[idx];
        // Skip unassigned ports
        if (net_ref == .none) continue;

        groups.appendAssumeCapacity(.{
            .port_range = .single(port_indexes),
            .ref = net_ref,
            .uniform = true,
            // Only actual nets get ranges, not constant ones
            .net = if (net_ref.isReal()) blk: {
                const net = e.nl.getNet(net_ref);
                break :blk .{ .base = net.name, .range = .single(net.indexes) };
            } else null,
        });
    }

    if (groups.items.len == 0) return;

    // Emit all the groups
    for (mergeAdjacent(PortGroup, groups.items, PortGroup.mergeInto)) |g| {
        try w.print("{s}{s} {s}{f} = ", .{
            e.indent,
            @tagName(entry.kind),
            entry.name,
            g.port_range,
        });
        if (g.uniform) {
            try w.print("{f};\n", .{g.ref.fmt(e.nl)});
        } else {
            const net = g.net.?;
            try w.print("{s}{f};\n", .{
                e.nl.net_base_names.get(net.base),
                net.range,
            });
        }
    }
}

/// One line per run of port bits that a single line can spell: `DI[0..3]`
/// needs the nets on the other side to be contiguous too, so how far a port
/// folds is decided per port by `emitCellPortRanges`.
fn emitCellPorts(e: *NetlistEmitter, name: []const u8, cell: *const Netlist.Cell) !void {
    const w = &e.w.writer;

    // CLK and RST are not in the port table; they bind straight to the cell.
    if (cell.clk != .none)
        try w.print("{s}in CLK = {f};\n", .{ e.indent, cell.clk.fmt(e.nl) });
    if (cell.rst != .none)
        try w.print("{s}in RST = {f};\n", .{ e.indent, cell.rst.fmt(e.nl) });

    // `ports_len` stays 0 until the first binding. A logical cell whose widths
    // are still unset lands here too, since nothing can bind before them.
    if (cell.ports_len == 0) return;

    const entry = ports.cellEntry(cell.cellType());
    const lookup = ports.buildLookupTableCell(cell) catch {
        e.warn(
            "Cell '{s}' has ports bound but no widths to lay them out",
            .{name},
        );
        return;
    };
    if (lookup.total != cell.ports_len) {
        e.warn(
            "Cell '{s}' has {} port bits, but its parameters describe {}",
            .{ name, cell.ports_len, lookup.total },
        );
        return;
    }

    for (entry.entries, lookup.ports[0..entry.entries.len]) |port, port_lookup| {
        try e.emitCellPortRanges(
            port,
            port_lookup,
            e.nl.getCellPorts(cell, port_lookup.base, port_lookup.count),
        );
    }
}

fn emitCell(e: *NetlistEmitter, ref: Netlist.Cell.Ref) !void {
    const cell = e.nl.getCell(ref);
    const name = e.nl.cell_names.get(ref);

    const w = &e.w.writer;
    try w.print("cell {s} : {f} {{\n", .{ name, cell.cellType() });

    e.indent = "    ";
    defer e.indent = "";
    const body_start = e.w.written().len;

    // Parameters first: both the `data {}` shape and the port widths are
    // derived from them, so the parser needs them before either.
    try e.emitCellParams(cell);

    if (cell.data) |*data| {
        // A BRAM takes its shape from WIDTH, so a `data {}` that does not fill
        // the tile's 4096 bits would come back from the parser a different
        // shape than it went out. Emit it anyway and say so.
        switch (cell.params) {
            .physical => |params_union| switch (params_union) {
                .bram, .bram_dual => if (@as(u64, data.depth) * data.data_width != 4096)
                    e.warn(
                        "Cell '{s}' holds {} entries of {} bits, which does not fill a BRAM tile",
                        .{ name, data.depth, data.data_width },
                    ),
                else => {},
            },
            .logical => {},
        }
        try e.emitMemData(data);
    }

    if (cell.pack != .none)
        try w.print("{s}PACK = {s};\n", .{ e.indent, e.nl.pack_names.get(cell.pack) });
    if (cell.slot != .none)
        try w.print("{s}SLOT = {f};\n", .{ e.indent, cell.slot });
    if (cell.site) |site|
        try w.print("{s}SITE = ({}, {});\n", .{ e.indent, site.row, site.col });

    if (e.hasPorts(cell)) {
        try e.section(body_start);
        try e.emitCellPorts(name, cell);
    }

    if (cell.meta.head != .none) {
        try e.section(body_start);
        try e.emitMeta(cell.meta);
    }

    try w.writeAll("}\n");
}

fn fillSortedNets(e: *NetlistEmitter) void {
    e.sorted_nets = e.alloc.alloc(Netlist.Net.Ref, e.nl.nets.items.len) catch common.oom();
    for (0..e.sorted_nets.len) |i|
        e.sorted_nets[i] = @enumFromInt(i);

    const Cxt = struct {
        nl: *const Netlist,

        fn lessThan(cxt: @This(), a: Netlist.Net.Ref, b: Netlist.Net.Ref) bool {
            const a_net = cxt.nl.getNet(a);
            const b_net = cxt.nl.getNet(b);

            if (@intFromEnum(a_net.name) < @intFromEnum(b_net.name))
                return true;
            if (@intFromEnum(a_net.name) > @intFromEnum(b_net.name))
                return false;

            if (a_net.indexes.n < b_net.indexes.n)
                return true;
            if (a_net.indexes.n > b_net.indexes.n)
                return false;

            const ord = std.mem.order(u16, a_net.indexes.slice(), b_net.indexes.slice());
            return ord.compare(.lt);
        }
    };

    std.sort.pdq(
        Netlist.Net.Ref,
        e.sorted_nets,
        Cxt{ .nl = e.nl },
        Cxt.lessThan,
    );
}

/// Blocks are separated by a blank line rather than followed by one, so the
/// text ends with the closing brace of the last block.
fn emitAll(e: *NetlistEmitter) !void {
    const w = &e.w.writer;
    try e.emitHeader();

    if (e.sorted_nets.len != 0) {
        try w.writeByte('\n');
        try e.emitNetDecls();
    }

    for (0..e.nl.cells.items.len) |i| {
        try w.writeByte('\n');
        try e.emitCell(@enumFromInt(i));
    }

    // Same order as the declarations above, so the two halves of the file
    // agree about where a net sits.
    for (e.sorted_nets) |ref| {
        const net = e.nl.getNet(ref);
        if (!hasBody(net)) continue;
        try w.writeByte('\n');
        try e.emitNet(net);
    }
}

pub fn emit(nl: *const Netlist, alloc: std.mem.Allocator) Result {
    var e = NetlistEmitter.init(nl, alloc);
    e.fillSortedNets();
    defer alloc.free(e.sorted_nets);
    // The only way an `Allocating` writer fails is running out of memory.
    e.emitAll() catch common.oom();

    return .{
        .text = e.finish(),
        .warnings = e.warnings.toOwnedSlice(e.alloc) catch common.oom(),
    };
}
