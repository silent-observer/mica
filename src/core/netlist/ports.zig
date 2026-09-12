const Indexes = @import("Indexes.zig");
const port_tables = @import("port_tables.zig");
const cell_type = @import("cell_type.zig");
const Cell = @import("Cell.zig");

pub const Dim = union(enum) {
    fixed: u16,
    param: []const u8, // A[0..width-1]
    pow2: []const u8, // OUT[0..2^depth-1]
    twice: []const u8, // O[0..2*width-1]
};

pub const CellEntry = struct {
    clk: bool = false,
    rst: bool = false,
    entries: []const Entry,
};

pub const Entry = struct {
    kind: Cell.PortKind,
    name: []const u8,
    width: []const Dim = &.{},

    pub fn range(
        comptime e: Entry,
        p: anytype,
    ) error{ParamMissing}!Indexes.Range {
        var r: Indexes.Range = .empty;
        inline for (e.width) |d| {
            switch (d) {
                .fixed => |n| r.add(0, n),
                .param => |width_name| {
                    const width: u16 = @field(p, width_name) orelse
                        return error.ParamMissing;
                    r.add(0, width);
                },
                .pow2 => |depth_name| {
                    const depth: u4 = @field(p, depth_name) orelse
                        return error.ParamMissing;
                    const n = @as(u16, 1) << depth;
                    r.add(0, n);
                },
                .twice => |width_name| {
                    const width: u16 = @field(p, width_name) orelse
                        return error.ParamMissing;
                    r.add(0, 2 * width);
                },
            }
        }
        return r;
    }
};

const MAX_PORT_ENTRIES = blk: {
    var curr: usize = 0;
    for (&port_tables.physical_cells.values) |e|
        curr = @max(curr, e.entries.len);
    for (&port_tables.logical_cells.values) |e|
        curr = @max(curr, e.entries.len);
    break :blk curr;
};

pub const LookupTable = struct {
    total: u16,
    ports: [MAX_PORT_ENTRIES]PerPort, // Same order as in CellEntry entries

    pub const PerPort = struct {
        base: u16,
        full_range: Indexes.Range,
        count: u16,
    };
};

pub fn buildLookupTable(comptime entry: CellEntry, p: anytype) error{ParamMissing}!LookupTable {
    var total: u16 = 0;
    var ports: [MAX_PORT_ENTRIES]LookupTable.PerPort = undefined;
    inline for (entry.entries, 0..) |e, i| {
        ports[i].base = total;
        ports[i].full_range = try e.range(p);
        ports[i].count = @intCast(ports[i].full_range.count());
        total += ports[i].count;
    }

    return LookupTable{
        .total = total,
        .ports = ports,
    };
}

pub fn cellEntry(t: cell_type.Full) CellEntry {
    return switch (t) {
        .physical => |pt| port_tables.physical_cells.get(pt),
        .logical => |lt| port_tables.logical_cells.get(lt),
    };
}
