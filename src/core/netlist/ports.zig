const std = @import("std");
const common = @import("../common.zig");
const Netlist = @import("Netlist.zig");
const Indexes = @import("Indexes.zig");

const Dim = union(enum) {
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
    kind: Netlist.Cell.PortKind,
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

pub const physical_cells: std.EnumArray(Netlist.CellType.Physical, CellEntry) = .init(.{
    .lut4 = CellEntry{ .entries = &.{
        .{ .kind = .in, .name = "A" },
        .{ .kind = .in, .name = "B" },
        .{ .kind = .in, .name = "C" },
        .{ .kind = .in, .name = "D" },

        .{ .kind = .out, .name = "O" },
    } },
    .lut3 = CellEntry{ .entries = &.{
        .{ .kind = .in, .name = "B" },
        .{ .kind = .in, .name = "C" },
        .{ .kind = .in, .name = "D" },

        .{ .kind = .out, .name = "O" },
    } },
    .ff = CellEntry{
        .clk = true,
        .rst = true,
        .entries = &.{
            .{ .kind = .in, .name = "D" },
            .{ .kind = .in, .name = "E" },

            .{ .kind = .out, .name = "Q" },
        },
    },
    .carry = CellEntry{ .entries = &.{
        .{ .kind = .in, .name = "B" },
        .{ .kind = .in, .name = "C" },
        .{ .kind = .in, .name = "D" },
        .{ .kind = .in, .name = "CIN" },

        .{ .kind = .out, .name = "S" },
        .{ .kind = .out, .name = "G" },
        .{ .kind = .out, .name = "COUT" },
    } },
    .mem = CellEntry{
        .clk = true,
        .rst = true,
        .entries = &.{
            .{
                .kind = .in,
                .name = "ADDR",
                .width = &.{.{ .fixed = 5 }},
            },
            .{ .kind = .in, .name = "DI" },
            .{ .kind = .in, .name = "WE" },

            .{ .kind = .out, .name = "DO" },
        },
    },
    .mem_dual = CellEntry{
        .clk = true,
        .rst = true,
        .entries = &.{
            .{
                .kind = .in,
                .name = "ADDR",
                .width = &.{.{ .fixed = 4 }},
            },
            .{
                .kind = .in,
                .name = "DI",
                .width = &.{.{ .fixed = 2 }},
            },
            .{ .kind = .in, .name = "WE" },

            .{
                .kind = .out,
                .name = "DO",
                .width = &.{.{ .fixed = 2 }},
            },
        },
    },
    .bram = CellEntry{
        .clk = true,
        .entries = &.{
            .{
                .kind = .in,
                .name = "ADDR",
                .width = &.{.{ .fixed = 12 }},
            },
            .{
                .kind = .in,
                .name = "DI",
                .width = &.{.{ .fixed = 16 }},
            },
            .{ .kind = .in, .name = "WE" },

            .{
                .kind = .out,
                .name = "DO",
                .width = &.{.{ .fixed = 16 }},
            },
        },
    },
    .bram_dual = CellEntry{
        .clk = true,
        .entries = &.{
            .{
                .kind = .in,
                .name = "ADDR1",
                .width = &.{.{ .fixed = 12 }},
            },
            .{
                .kind = .in,
                .name = "ADDR2",
                .width = &.{.{ .fixed = 12 }},
            },
            .{
                .kind = .in,
                .name = "DI1",
                .width = &.{.{ .fixed = 8 }},
            },
            .{
                .kind = .in,
                .name = "DI2",
                .width = &.{.{ .fixed = 8 }},
            },
            .{ .kind = .in, .name = "WE1" },
            .{ .kind = .in, .name = "WE2" },

            .{
                .kind = .out,
                .name = "DO1",
                .width = &.{.{ .fixed = 8 }},
            },
            .{
                .kind = .out,
                .name = "DO2",
                .width = &.{.{ .fixed = 8 }},
            },
        },
    },
    .dsp = CellEntry{ .entries = &.{
        .{
            .kind = .in,
            .name = "A",
            .width = &.{.{ .fixed = 8 }},
        },
        .{
            .kind = .in,
            .name = "B",
            .width = &.{.{ .fixed = 8 }},
        },

        .{
            .kind = .out,
            .name = "O",
            .width = &.{.{ .fixed = 16 }},
        },
    } },
    .dsp_acc = CellEntry{
        .clk = true,
        .rst = true,
        .entries = &.{
            .{
                .kind = .in,
                .name = "A",
                .width = &.{.{ .fixed = 8 }},
            },
            .{
                .kind = .in,
                .name = "B",
                .width = &.{.{ .fixed = 8 }},
            },
            .{
                .kind = .in,
                .name = "C",
                .width = &.{.{ .fixed = 16 }},
            },
            .{ .kind = .in, .name = "MD" },
            .{ .kind = .in, .name = "AD" },
            .{ .kind = .in, .name = "WE" },

            .{
                .kind = .out,
                .name = "O",
                .width = &.{.{ .fixed = 16 }},
            },
        },
    },
    .io = CellEntry{
        .clk = true,
        .rst = true,
        .entries = &.{
            .{ .kind = .in, .name = "O" },
            .{ .kind = .in, .name = "E" },
            .{ .kind = .in, .name = "IE" },
            .{ .kind = .in, .name = "OE" },
            .{ .kind = .in, .name = "EE" },

            .{ .kind = .out, .name = "I" },
        },
    },
});

pub const logical_cells: std.EnumArray(Netlist.CellType.Logical, CellEntry) = .init(.{
    .add = CellEntry{ .entries = &.{
        .{
            .kind = .in,
            .name = "A",
            .width = &.{.{ .param = "width" }},
        },
        .{
            .kind = .in,
            .name = "B",
            .width = &.{.{ .param = "width" }},
        },
        .{ .kind = .in, .name = "CIN" },

        .{
            .kind = .out,
            .name = "O",
            .width = &.{.{ .param = "width" }},
        },
        .{ .kind = .out, .name = "COUT" },
    } },
    .sub = CellEntry{ .entries = &.{
        .{
            .kind = .in,
            .name = "A",
            .width = &.{.{ .param = "width" }},
        },
        .{
            .kind = .in,
            .name = "B",
            .width = &.{.{ .param = "width" }},
        },
        .{ .kind = .in, .name = "CIN" },

        .{
            .kind = .out,
            .name = "O",
            .width = &.{.{ .param = "width" }},
        },
        .{ .kind = .out, .name = "COUT" },
    } },
    .mul = CellEntry{ .entries = &.{
        .{
            .kind = .in,
            .name = "A",
            .width = &.{.{ .param = "width" }},
        },
        .{
            .kind = .in,
            .name = "B",
            .width = &.{.{ .param = "width" }},
        },

        .{
            .kind = .out,
            .name = "O",
            .width = &.{.{ .twice = "width" }},
        },
    } },
    .mux = CellEntry{ .entries = &.{
        .{
            .kind = .in,
            .name = "IN",
            .width = &.{
                .{ .pow2 = "depth" },
                .{ .param = "width" },
            },
        },
        .{
            .kind = .in,
            .name = "SEL",
            .width = &.{.{ .param = "depth" }},
        },

        .{
            .kind = .out,
            .name = "OUT",
            .width = &.{.{ .param = "width" }},
        },
    } },
    .decode = CellEntry{ .entries = &.{
        .{
            .kind = .in,
            .name = "SEL",
            .width = &.{.{ .param = "depth" }},
        },

        .{
            .kind = .out,
            .name = "OUT",
            .width = &.{.{ .pow2 = "depth" }},
        },
    } },
    .@"and" = CellEntry{ .entries = &.{
        .{
            .kind = .in,
            .name = "A",
            .width = &.{.{ .param = "width" }},
        },
        .{
            .kind = .in,
            .name = "B",
            .width = &.{.{ .param = "width" }},
        },

        .{
            .kind = .out,
            .name = "OUT",
            .width = &.{.{ .param = "width" }},
        },
    } },
    .@"or" = CellEntry{ .entries = &.{
        .{
            .kind = .in,
            .name = "A",
            .width = &.{.{ .param = "width" }},
        },
        .{
            .kind = .in,
            .name = "B",
            .width = &.{.{ .param = "width" }},
        },

        .{
            .kind = .out,
            .name = "OUT",
            .width = &.{.{ .param = "width" }},
        },
    } },
    .xor = CellEntry{ .entries = &.{
        .{
            .kind = .in,
            .name = "A",
            .width = &.{.{ .param = "width" }},
        },
        .{
            .kind = .in,
            .name = "B",
            .width = &.{.{ .param = "width" }},
        },

        .{
            .kind = .out,
            .name = "OUT",
            .width = &.{.{ .param = "width" }},
        },
    } },
    .not = CellEntry{ .entries = &.{
        .{
            .kind = .in,
            .name = "IN",
            .width = &.{.{ .param = "width" }},
        },

        .{
            .kind = .out,
            .name = "OUT",
            .width = &.{.{ .param = "width" }},
        },
    } },
    .and_all = CellEntry{ .entries = &.{
        .{
            .kind = .in,
            .name = "IN",
            .width = &.{.{ .param = "n" }},
        },

        .{ .kind = .out, .name = "OUT" },
    } },
    .or_all = CellEntry{ .entries = &.{
        .{
            .kind = .in,
            .name = "IN",
            .width = &.{.{ .param = "n" }},
        },

        .{ .kind = .out, .name = "OUT" },
    } },
    .xor_all = CellEntry{ .entries = &.{
        .{
            .kind = .in,
            .name = "IN",
            .width = &.{.{ .param = "n" }},
        },

        .{ .kind = .out, .name = "OUT" },
    } },
    .ff = CellEntry{
        .clk = true,
        .rst = true,
        .entries = &.{
            .{
                .kind = .in,
                .name = "D",
                .width = &.{.{ .param = "width" }},
            },
            .{ .kind = .in, .name = "E" },

            .{
                .kind = .out,
                .name = "Q",
                .width = &.{.{ .param = "width" }},
            },
        },
    },
    .rom = CellEntry{ .entries = &.{
        .{
            .kind = .in,
            .name = "A",
            .width = &.{.{ .param = "addr_width" }},
        },

        .{
            .kind = .out,
            .name = "DO",
            .width = &.{.{ .param = "data_width" }},
        },
    } },
    .rom_dual = CellEntry{ .entries = &.{
        .{
            .kind = .in,
            .name = "A1",
            .width = &.{.{ .param = "addr_width" }},
        },
        .{
            .kind = .in,
            .name = "A2",
            .width = &.{.{ .param = "addr_width" }},
        },

        .{
            .kind = .out,
            .name = "DO1",
            .width = &.{.{ .param = "data_width" }},
        },
        .{
            .kind = .out,
            .name = "DO2",
            .width = &.{.{ .param = "data_width" }},
        },
    } },
    .ram = CellEntry{
        .clk = true,
        .rst = true,
        .entries = &.{
            .{
                .kind = .in,
                .name = "A",
                .width = &.{.{ .param = "addr_width" }},
            },
            .{
                .kind = .in,
                .name = "DI",
                .width = &.{.{ .param = "data_width" }},
            },
            .{ .kind = .in, .name = "WE" },

            .{
                .kind = .out,
                .name = "DO",
                .width = &.{.{ .param = "data_width" }},
            },
        },
    },
    .ram_dual = CellEntry{
        .clk = true,
        .rst = true,
        .entries = &.{
            .{
                .kind = .in,
                .name = "A1",
                .width = &.{.{ .param = "addr_width" }},
            },
            .{
                .kind = .in,
                .name = "A2",
                .width = &.{.{ .param = "addr_width" }},
            },
            .{
                .kind = .in,
                .name = "DI1",
                .width = &.{.{ .param = "data_width" }},
            },
            .{
                .kind = .in,
                .name = "DI2",
                .width = &.{.{ .param = "data_width" }},
            },
            .{ .kind = .in, .name = "WE1" },
            .{ .kind = .in, .name = "WE2" },

            .{
                .kind = .out,
                .name = "DO1",
                .width = &.{.{ .param = "data_width" }},
            },
            .{
                .kind = .out,
                .name = "DO2",
                .width = &.{.{ .param = "data_width" }},
            },
        },
    },
});

const MAX_PORT_ENTRIES = blk: {
    var curr: usize = 0;
    for (&physical_cells.values) |e|
        curr = @max(curr, e.entries.len);
    for (&logical_cells.values) |e|
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

pub fn cellEntry(t: Netlist.CellType) CellEntry {
    return switch (t) {
        .physical => |pt| physical_cells.get(pt),
        .logical => |lt| logical_cells.get(lt),
    };
}
