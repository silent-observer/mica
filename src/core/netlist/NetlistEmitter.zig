const std = @import("std");

const common = @import("../common.zig");
const wire_codes = @import("../wire_codes.zig");
const routing = @import("../routing.zig");
const Netlist = @import("Netlist.zig");
const MemData = @import("MemData.zig");
const DeviceModel = @import("../DeviceModel.zig");
const ports = @import("ports.zig");

const NetlistEmitter = @This();

nl: *const Netlist,
alloc: std.mem.Allocator,
w: std.Io.Writer.Allocating,
indent: []const u8,

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
        try w.print(
            "{s}@{s} {s};\n",
            .{ e.indent, @tagName(meta.tag), meta.data },
        );
        meta_ref = meta.next;
    }
    try w.writeAll("\n");
}

fn emitHeader(e: *NetlistEmitter) !void {
    const w = &e.w.writer;
    try w.print(
        "format 1;\n" ++
            "device \"{s}\";\n" ++
            "design \"{s}\";\n",
        .{ e.nl.model.model_id, e.nl.design_name },
    );

    var iter = e.nl.passes.iterator();
    while (iter.next()) |entry| {
        try w.print(
            "pass {s} \"{s}\";\n",
            .{ @tagName(entry.key), entry.value.* },
        );
    }

    try e.emitMeta(e.nl.meta);
    try w.writeAll("\n");
}

fn emitNetDecl(e: *NetlistEmitter, net: *const Netlist.Net) !void {
    const w = &e.w.writer;
    try w.print("net {f}", .{net.fmt(e.nl)});
    if (net.kind != .net) {
        try w.print(" : {s}", .{@tagName(net.kind)});
    }
    try w.writeAll(";\n");
}

fn emitNet(e: *NetlistEmitter, net: *const Netlist.Net) !void {
    if (net.meta.head == .none and
        net.network == null and
        net.period_ps == null and
        net.pin == null and
        net.route_len == 0) return;

    const w = &e.w.writer;
    try w.print("net {f}", .{net.fmt(e.nl)});

    if (net.kind != .net) {
        try w.print(" : {s}", .{@tagName(net.kind)});
    }
    try w.writeAll("{\n");

    {
        e.indent = "    ";
        defer e.indent = "";

        if (net.period_ps) |period|
            try w.print("{s}PERIOD = {};\n", .{ e.indent, period });

        if (net.network) |network|
            switch (net.kind) {
                .net => e.warn("Network specified for plain net: network = {}", .{network}),
                .clock => try w.print("{s}CLK = {};\n", .{ e.indent, network }),
                .reset => try w.print("{s}RST = {};\n", .{ e.indent, network }),
            };

        if (net.pin) |pin|
            try w.print("{s}PIN = {};\n", .{ e.indent, pin });

        if (net.route_len != 0) {
            try w.print("{s}route {{\n", .{e.indent});

            e.indent = "        ";
            for (e.nl.route_edges.items[net.route_start..][0..net.route_len]) |edge|
                switch (edge) {
                    .switchbox => |s| try w.print(
                        "{s}switch ({}, {}) : {f} = {f};\n",
                        .{
                            e.indent,
                            s.at.row,
                            s.at.col,
                            s.dst,
                            wire_codes.resolveSwitchSink(s.at, s.dst, s.src, e.nl.model.grid),
                        },
                    ),
                    inline else => |s, tag| {
                        const t: common.TileType = @field(common.TileType, @tagName(tag));
                        try w.print(
                            "{s}{s} ({}, {}) : {f} = {f};\n",
                            .{
                                e.indent,
                                @tagName(tag),
                                s.at.row,
                                s.at.col,
                                s.input,
                                wire_codes.resolveInput(
                                    t,
                                    s.at,
                                    s.dst,
                                    e.nl.model.inputCxt(t, s.at),
                                    s.src,
                                    e.nl.model.grid,
                                ),
                            },
                        );
                    },
                };
            e.indent = "    ";

            try w.print("{s}}}\n", .{e.indent});
        }

        try e.emitMeta(net.meta);
    }

    try w.writeAll("}\n");
}

fn emitCellParams(e: *NetlistEmitter, cell: *const Netlist.Cell) !void {
    const w = &e.w.writer;
    switch (cell.params) {
        inline else => |params_union, tag| switch (params_union) {
            inline else => |params, t| {
                inline for (std.meta.fields(@TypeOf(params))) |f| {
                    const param = common.upper(f.name);
                    try w.print("{s}{s} = ", .{ e.indent, param });

                    const hex = comptime if (tag == .physical)
                        switch (t) {
                            .lut4, .lut3, .carry, .mem, .mem_dual => true,
                            else => false,
                        }
                    else
                        false;
                    const v_opt = @field(params, f.name);
                    if (v_opt) |v| {
                        if (@TypeOf(v) == bool)
                            try w.print("{};\n", .{@intFromBool(v)})
                        else if (@TypeOf(v) == common.BramWidth)
                            try w.print("{};\n", .{v.int()})
                        else if (@typeInfo(@TypeOf(v)) == .integer) {
                            const fmt = comptime if (hex) switch (@TypeOf(v)) {
                                u8 => "0x{X:0>2};\n",
                                u16 => "0x{X:0>4};\n",
                                u32 => "0x{X:0>8};\n",
                            } else "{};\n";
                            try w.print(fmt, .{v});
                        }
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

/// Writes one entry straight out of its slot rather than through an integer.
/// The slot holds whole bytes, so a width like 12 leaves one leading nibble
/// of padding that `CommonParser.parseMemSlot` guarantees is zero; drop it.
fn emitSlot(e: *NetlistEmitter, slot: []const u8, digits: u16) !void {
    const w = &e.w.writer;
    var i = slot.len * 2 - digits;
    while (i < slot.len * 2) : (i += 1) {
        const byte = slot[i / 2];
        const nibble: u4 = if (i % 2 == 0) @truncate(byte >> 4) else @truncate(byte);
        try w.writeByte(std.fmt.digitToChar(nibble, .upper));
    }
}

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

fn emitCellPorts(e: *NetlistEmitter, cell: *const Netlist.Cell) !void {
    const cell_entry = ports.cellEntry(cell.cellType());
    const lookup = switch (cell.params) {
        inline else => |params_union| switch (params_union) {
            inline else => |params| ports.buildLookupTable(cell_entry, params) catch unreachable,
        },
    };

    const w = &e.w.writer;

    if (cell.clk) |clk|
        try w.print("{s}in CLK = {};\n", .{ e.indent, clk });
    if (cell.rst) |rst|
        try w.print("{s}in RST = {};\n", .{ e.indent, rst });

    for (cell_entry.entries, lookup.ports) |entry, port_lookup| {
        var iter = port_lookup.full_range.iterator();
        var i: u32 = 0;
        while (iter.next()) |indexes| : (i += 1) {
            const net_ref = e.nl.getCellPort(cell, i).*;
            if (net_ref != .none)
                try w.print("{s}{s} {s}{f} = {f};\n", .{
                    e.indent,
                    @tagName(entry.kind),
                    entry.name,
                    indexes,
                    net_ref.fmt(e.nl),
                });
        }
    }
}

fn emitCell(e: *NetlistEmitter, ref: Netlist.Cell.Ref) !void {
    const cell = e.nl.getCell(ref);
    const name = e.nl.cell_names.get(ref);

    const w = &e.w.writer;
    try w.print("cell {s} : {f} {{\n", .{ name, cell.cellType() });

    e.indent = "    ";
    defer e.indent = "";

    // Emit cell parameters
    try e.emitCellParams(cell);

    // Emit cell special params
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

    try w.writeAll("\n");
    // Emit cell ports
    try e.emitCellPorts(cell);

    try w.writeAll("}\n");
}

pub fn emit(nl: *const Netlist, alloc: std.mem.Allocator) Result {
    var e = NetlistEmitter.init(nl, alloc);
    defer e.deinit();
    e.collectReads();
    e.emitHeader() catch common.oom();

    return .{
        .text = e.finish(),
        .warnings = e.warnings.toOwnedSlice(e.alloc) catch common.oom(),
    };
}
