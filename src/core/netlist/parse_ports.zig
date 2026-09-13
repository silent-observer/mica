//! Binding of `in`/`out` commands to a cell's port span. `CLK` and `RST` are
//! spelled like ports but live outside the table, on `Cell.clk`/`Cell.rst`, so
//! they take no indexes and reject constant drivers.

const std = @import("std");

const NetlistParser = @import("NetlistParser.zig");
const Cell = @import("Cell.zig");
const Net = @import("Net.zig");
const ports = @import("ports.zig");
const parse_signals = @import("parse_signals.zig");
const SignalRange = parse_signals.SignalRange;

const clk_rst_table: std.StaticStringMap(Net.Kind) = .initComptime(.{
    .{ "CLK", .clock },
    .{ "RST", .reset },
});

/// Binds `Cell.clk`/`Cell.rst`, which live outside the port table and so
/// take no indexes and reject constant drivers.
fn handleClkRstPort(
    p: *NetlistParser,
    net_kind: Net.Kind,
    port_signal: SignalRange,
    net_ref: Net.Ref,
    cell_ref: Cell.Ref,
) !void {
    const cell = p.nl().getCell(cell_ref);
    const entry = ports.cellEntry(cell.cellType());

    const should_have_clk_rst = if (net_kind == .clock) entry.clk else entry.rst;
    if (!should_have_clk_rst)
        try p.p.err(
            "Cell type '{f}' doesn't have a {s} input",
            .{ cell.cellType(), port_signal.name },
        );

    if (port_signal.indexes.n != 0)
        try p.p.err(
            "Port {s} can't have indexes: '{f}'",
            .{ port_signal.name, port_signal },
        );
    if (net_ref == .none or net_ref == .zero or net_ref == .one)
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

    if (target.* != .none and target.* != net_ref) {
        try p.p.err(
            "Port {s} was earlier bound to {f}",
            .{ port_signal.name, target.fmt(p.nl()) },
        );
    }

    target.* = net_ref;
}

fn handleGeneralPort(
    p: *NetlistParser,
    lookup_table: *const ports.LookupTable,
    kind: Cell.PortKind,
    port_signal: SignalRange,
    net_refs: []Net.Ref,
    cell_ref: Cell.Ref,
) !void {
    const cell = p.nl().getCell(cell_ref);
    const entry = ports.cellEntry(cell.cellType());

    for (entry.entries, 0..) |e, e_idx| {
        if (e.kind == kind and std.mem.eql(u8, e.name, port_signal.name)) {
            const lookup = lookup_table.ports[e_idx];
            var port_iter = port_signal.indexes.iterator();
            var pos: usize = 0;
            while (port_iter.next()) |port_indexes| : (pos += 1) {
                const index = lookup.full_range.toIndex(port_indexes) orelse {
                    if (port_indexes.n != lookup.full_range.n)
                        try p.p.err(
                            "Port {s} needs {} indexes, got {}",
                            .{ port_signal.name, lookup.full_range.n, port_indexes.n },
                        )
                    else
                        try p.p.err(
                            "Port {s} only goes through {f}, {f} is not inside that",
                            .{ port_signal.name, lookup.full_range, port_indexes },
                        );
                };
                const port = p.nl().getCellPort(cell, @intCast(lookup.base + index));
                if (port.* != .none and port.* != net_refs[pos]) {
                    try p.p.err(
                        "Port {s}{f} was earlier bound to {f}",
                        .{ port_signal.name, port_indexes, port.fmt(p.nl()) },
                    );
                }
                port.* = net_refs[pos];
            }
            return;
        }
    }
    // Fall-through
    try p.p.err("Unknown port: {s} {f}", .{ @tagName(kind), port_signal });
}

/// `net_refs` holds one ref per port bit, already broadcast or zipped against
/// the port's indexes by the caller.
pub fn handlePortCommand(
    p: *NetlistParser,
    lookup_table: *const ports.LookupTable,
    kind: Cell.PortKind,
    port_signal: SignalRange,
    net_refs: []Net.Ref,
    cell_ref: Cell.Ref,
) !void {
    if (kind == .in and clk_rst_table.get(port_signal.name) != null) {
        const net_kind = clk_rst_table.get(port_signal.name).?;
        try handleClkRstPort(p, net_kind, port_signal, net_refs[0], cell_ref);
    } else try handleGeneralPort(p, lookup_table, kind, port_signal, net_refs, cell_ref);
}
