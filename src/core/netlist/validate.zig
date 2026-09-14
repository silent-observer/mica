const std = @import("std");
const common = @import("../common.zig");
const Netlist = @import("Netlist.zig");
const Net = @import("Net.zig");
const Cell = @import("Cell.zig");

pub const Result = struct {
    str_arena: std.heap.ArenaAllocator,
    errs: std.array_list.Managed([]const u8),
};

fn err(r: *Result, comptime fmt: []const u8, args: anytype) void {
    const str = std.fmt.allocPrint(r.str_arena.allocator(), fmt, args) catch common.oom();
    r.errs.append(str) catch common.oom();
}

pub fn validate(nl: *const Netlist, alloc: std.mem.Allocator) Result {
    var r = Result{
        .errs = .init(alloc),
        .str_arena = .init(alloc),
    };

    // Validate each net has exactly one source
    const sources = alloc.alloc(u16, nl.nets.items.len) catch common.oom();
    defer alloc.free(sources);

    @memset(sources, 0);
    for (nl.cells.items) |*cell| {
        const lookup = Netlist.ports.buildLookupTableCell(cell) catch
            @panic("Got netlist without widths somehow");
        for (0..cell.ports_len) |port_index| {
            const port: u32 = @intCast(port_index);
            const ref = nl.getCellPort(cell, port).*;
            if (ref.isReal() and !lookup.isInput(port)) {
                sources[ref.int()] += 1;
            }
        }
    }

    for (nl.nets.items, sources) |*net, source_count| {
        // A net with a `PIN` of its own is bound straight to a pad rather than
        // reaching the die through an `IO` cell - that is how the global clock
        // and reset networks are spelled - so there is no cell output to count.
        if (net.pin != null) continue;

        if (source_count == 0)
            err(&r, "Net {f} has no sources!", .{net.fmt(nl)})
        else if (source_count > 1)
            err(&r, "Net {f} has {} sources!", .{ net.fmt(nl), source_count });
    }
    return r;
}
