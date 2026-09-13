//! The declarative port table, one `CellEntry` per cell type - the netlist
//! analogue of the bitstream's `blocks.zig`. `CLK` and `RST` are the two
//! booleans rather than entries, because they bind outside the port span.

const std = @import("std");
const cell_type = @import("cell_type.zig");
const ports = @import("ports.zig");
const CellEntry = ports.CellEntry;

pub const physical_cells: std.EnumArray(cell_type.Physical, CellEntry) = .init(.{
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

pub const logical_cells: std.EnumArray(cell_type.Logical, CellEntry) = .init(.{
    .add = add_sub,
    .sub = add_sub,
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
    .@"and" = and_or_xor,
    .@"or" = and_or_xor,
    .xor = and_or_xor,
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
    .and_all = and_or_xor_all,
    .or_all = and_or_xor_all,
    .xor_all = and_or_xor_all,
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
    .rom = memoryEntry(false, false),
    .rom_dual = memoryEntry(true, false),
    .ram = memoryEntry(false, true),
    .ram_dual = memoryEntry(true, true),
});

const add_sub = CellEntry{ .entries = &.{
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
} };

const and_or_xor = CellEntry{ .entries = &.{
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
} };

const and_or_xor_all = CellEntry{ .entries = &.{
    .{
        .kind = .in,
        .name = "IN",
        .width = &.{.{ .param = "n" }},
    },

    .{ .kind = .out, .name = "OUT" },
} };

/// CellEntry for the $rom/$ram family
fn memoryEntry(comptime dual: bool, comptime writable: bool) CellEntry {
    const suffixes: []const []const u8 = if (dual) &.{ "1", "2" } else &.{""};
    const max_entries = 8;

    var entries: [max_entries]ports.Entry = undefined;
    var i: usize = 0;

    // Address
    for (suffixes) |suf| {
        entries[i] = ports.Entry{
            .kind = .in,
            .name = "A" ++ suf,
            .width = &.{.{ .param = "addr_width" }},
        };
        i += 1;
    }
    // Data input
    if (writable)
        for (suffixes) |suf| {
            entries[i] = ports.Entry{
                .kind = .in,
                .name = "DI" ++ suf,
                .width = &.{.{ .param = "data_width" }},
            };
            i += 1;
        };
    // Write enable
    if (writable)
        for (suffixes) |suf| {
            entries[i] = ports.Entry{
                .kind = .in,
                .name = "WE" ++ suf,
            };
            i += 1;
        };
    // Data output
    for (suffixes) |suf| {
        entries[i] = ports.Entry{
            .kind = .out,
            .name = "DO" ++ suf,
            .width = &.{.{ .param = "data_width" }},
        };
        i += 1;
    }
    const final = entries;
    return .{
        .clk = writable,
        .rst = writable,
        .entries = final[0..i],
    };
}
