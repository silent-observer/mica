const std = @import("std");

const Netlist = @import("Netlist.zig");
const Net = @import("Net.zig");
const Cell = @import("Cell.zig");
const oom = @import("../common.zig").oom;

const NetIndex = @This();

sink_offsets: []const u32,
sinks: []const PinRef,
drivers: []const PinRef,

pub const PinRef = packed struct {
    cell: Cell.Ref,
    port: u16,
};

pub fn build(nl: *const Netlist, alloc: std.mem.Allocator) NetIndex {
    // Pass 1: fill sources and sink counts per net
    const offsets = alloc.alloc(u32, nl.nets.items.len + 1) catch oom();
    defer alloc.free(offsets);
    @memset(offsets, 0);

    const drivers = alloc.alloc(PinRef, nl.nets.items.len) catch oom();
    @memset(drivers, .{ .cell = .none, .port = 0 });

    for (nl.cells.items, 0..) |*cell, cell_idx| {
        const lookup = Netlist.ports.buildLookupTableCell(cell) catch
            @panic("Got netlist without widths somehow");
        for (0..cell.ports_len) |port| {
            const ref = nl.getCellPort(cell, @intCast(port)).*;
            if (ref.isReal()) {
                if (lookup.isInput(port))
                    offsets[ref.int()] += 1
                else
                    drivers[ref.int()] = PinRef{
                        .cell = @enumFromInt(cell_idx),
                        .port = @intCast(port),
                    };
            }
        }
    }

    // `offsets` now contain the number of inputs per net
    // Calculate the cumulative offsets
    var sum: u32 = 0;
    for (0..offsets.len) |i| {
        const count = offsets[i];
        offsets[i] = sum;
        sum += count;
    }

    const sink_offsets = alloc.dupe(u32, offsets) catch oom();

    // Pass 2: fill sinks CSR array
    const sinks = alloc.alloc(PinRef, sum) catch oom();
    for (nl.cells.items, 0..) |*cell, cell_idx| {
        const lookup = Netlist.ports.buildLookupTableCell(cell) catch unreachable;
        for (0..cell.ports_len) |port| {
            const ref = nl.getCellPort(cell, @intCast(port)).*;
            if (ref.isReal() and lookup.isInput(port)) {
                sinks[offsets[ref.int()]] = PinRef{
                    .cell = @enumFromInt(cell_idx),
                    .port = @intCast(port),
                };
                offsets[ref.int()] += 1;
            }
        }
    }

    return NetIndex{
        .sink_offsets = sink_offsets,
        .sinks = sinks,
        .drivers = drivers,
    };
}

pub fn deinit(idx: *NetIndex, alloc: std.mem.Allocator) void {
    alloc.free(idx.sink_offsets);
    alloc.free(idx.sinks);
    alloc.free(idx.drivers);
}

pub fn driverOf(idx: *const NetIndex, net: Net.Ref) PinRef {
    return idx.drivers[net.int()];
}

pub fn sinksOf(idx: *const NetIndex, net: Net.Ref) []const PinRef {
    const start = idx.sink_offsets[net.int()];
    const end = idx.sink_offsets[net.int() + 1];
    return idx.sinks[start..end];
}
