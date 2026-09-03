const std = @import("std");
const common = @import("common.zig");

pub const LogicOutput = enum(u2) {
    o1a = 0,
    o1b = 1,
    o2a = 2,
    o2b = 3,
};

pub const DirectionalWire1x1 = struct {
    side: common.Side,
    dir: common.Direction,
    class: common.WireClass,
    local_track: u8,
};

pub const DirectionalWire4x1 = struct {
    side: common.BigEdge,
    dir: common.Direction,
    class: common.WireClass,
    local_track: u8,
};

fn trackWindow(
    parity: u1,
    d: usize,
    idx: usize,
) struct { class: common.WireClass, local_track: u8 } {
    const i = (d + idx) % 9;
    const p: u8 = parity;
    return switch (i) {
        0 => .{ .class = .l1, .local_track = p },
        1 => .{ .class = .l4, .local_track = p },
        2 => .{ .class = .l16, .local_track = p },
        3 => .{ .class = .l1, .local_track = p + 2 },
        4 => .{ .class = .l4, .local_track = p + 2 },
        5 => .{ .class = .l4, .local_track = p + 4 },
        6 => .{ .class = .l1, .local_track = p + 4 },
        7 => .{ .class = .l16, .local_track = p + 2 },
        8 => .{ .class = .l4, .local_track = p + 6 },
        else => unreachable,
    };
}

fn window1(
    side: common.Side,
    dir: common.Direction,
    parity: u1,
    d: usize,
    idx: usize,
) DirectionalWire1x1 {
    const r = trackWindow(parity, d, idx);
    return DirectionalWire1x1{
        .side = side,
        .dir = dir,
        .class = r.class,
        .local_track = r.local_track,
    };
}

fn window4(
    side: common.BigEdge,
    dir: common.Direction,
    parity: u1,
    d: usize,
    idx: usize,
) DirectionalWire4x1 {
    const r = trackWindow(parity, d, idx);
    return DirectionalWire4x1{
        .side = side,
        .dir = dir,
        .class = r.class,
        .local_track = r.local_track,
    };
}

pub const LogicInputSrc = union(enum) {
    zero: void,
    one: void,
    local: LogicOutput,
    wire: DirectionalWire1x1,
    code: u5,
};

const LogicInputDesc = struct {
    parity: u1,
    primary: ?common.Side,
};

const logic_inputs: std.EnumArray(common.LogicInput, LogicInputDesc) = .init(.{
    .a1 = LogicInputDesc{ .parity = 0, .primary = .n },
    .b1 = LogicInputDesc{ .parity = 0, .primary = .e },
    .c1 = LogicInputDesc{ .parity = 0, .primary = .s },
    .d1 = LogicInputDesc{ .parity = 0, .primary = .w },
    .ce1 = LogicInputDesc{ .parity = 0, .primary = null },

    .a2 = LogicInputDesc{ .parity = 1, .primary = .s },
    .b2 = LogicInputDesc{ .parity = 1, .primary = .w },
    .c2 = LogicInputDesc{ .parity = 1, .primary = .n },
    .d2 = LogicInputDesc{ .parity = 1, .primary = .e },
    .ce2 = LogicInputDesc{ .parity = 1, .primary = null },
});

pub fn decodeLogicInput(in: common.LogicInput, code: u5) LogicInputSrc {
    const desc = logic_inputs.get(in);
    switch (in) {
        .a1, .b1, .c1, .d1, .a2, .b2, .c2, .d2 => switch (code) {
            0 => return .zero,
            1 => return .one,
            2 => return .{ .local = .o1a },
            3 => return .{ .local = .o1b },
            4 => return .{ .local = .o2a },
            5 => return .{ .local = .o2b },

            // Primary
            6...23 => {
                const k = code - 6; // 0..17
                const to = ([2]common.TurnOrientation{ .cw, .ccw })[k / 9];
                const idx = k % 9;
                return .{ .wire = window1(
                    desc.primary.?,
                    desc.primary.?.turnDir(to),
                    desc.parity,
                    0,
                    idx,
                ) };
            },

            // Secondary
            24...31 => {
                const side = desc.primary.?.opposite();
                const parity = 1 - desc.parity;
                const dir = switch (desc.parity) {
                    0 => side.turnDir(.cw),
                    1 => side.turnDir(.ccw),
                };
                const idx = code - 24;
                return .{ .wire = window1(side, dir, parity, 1, idx) };
            },
        },
        .ce1, .ce2 => switch (code) {
            0 => return .zero,
            1 => return .one,
            2 => return .{ .local = .o1b },
            3 => return .{ .local = .o2b },

            // CW
            4...19 => {
                const k = code - 4; // 0...15
                const side = ([4]common.Side{ .n, .e, .s, .w })[k / 4];
                const idx = k % 4;
                return .{ .wire = window1(
                    side,
                    side.turnDir(.cw),
                    desc.parity,
                    4,
                    idx,
                ) };
            },
            // CCW
            20...31 => {
                const k = code - 20; // 0...11
                const side = ([4]common.Side{ .n, .e, .s, .w })[k / 3];
                const idx = k % 3;
                return .{ .wire = window1(
                    side,
                    side.turnDir(.ccw),
                    desc.parity,
                    6,
                    idx,
                ) };
            },
        },
    }
}

pub fn encodeLogicInput(in: common.LogicInput, src: LogicInputSrc) ?u5 {
    for (0..32) |i| {
        const code: u5 = @intCast(i);
        if (std.meta.eql(decodeLogicInput(in, code), src))
            return code;
    }
    return null;
}

pub const BramInputSrc = union(enum) {
    zero: void,
    one: void,
    wire: DirectionalWire4x1,
    code: u5,
};

const BramInputDesc = struct {
    edge: common.BigEdge,
    secondary: common.BigEdge,
    d: u8,
    slot: u2,
};

const BramInputEntry = struct {
    edge: common.BigEdge,
    secondary: common.BigEdge,
    d: u8,
    slots: [4]common.BramInput,
};

const bram_input_entries: [10]BramInputEntry = .{
    .{
        .edge = .h0,
        .secondary = .h1,
        .d = 0,
        .slots = .{ .A1(0), .A2(0), .A1(1), .A2(1) },
    },
    .{
        .edge = .w0,
        .secondary = .h1,
        .d = 2,
        .slots = .{ .A1(2), .A2(2), .DI(0), .DI(1) },
    },
    .{
        .edge = .e0,
        .secondary = .h1,
        .d = 4,
        .slots = .{ .A1(3), .A2(3), .DI(2), .DI(3) },
    },

    .{
        .edge = .w1,
        .secondary = .h2,
        .d = 0,
        .slots = .{ .DI(5), .A1(4), .A2(4), .DI(4) },
    },
    .{
        .edge = .e1,
        .secondary = .h2,
        .d = 2,
        .slots = .{ .DI(7), .A1(5), .A2(5), .DI(6) },
    },
    .{
        .edge = .w2,
        .secondary = .h2,
        .d = 4,
        .slots = .{ .DI(8), .DI(9), .A1(6), .A2(6) },
    },
    .{
        .edge = .e2,
        .secondary = .h2,
        .d = 6,
        .slots = .{ .DI(10), .DI(11), .A1(7), .A2(7) },
    },

    .{
        .edge = .w3,
        .secondary = .h3,
        .d = 0,
        .slots = .{ .A2(8), .DI(12), .DI(13), .A1(8) },
    },
    .{
        .edge = .e3,
        .secondary = .h3,
        .d = 2,
        .slots = .{ .A2(9), .DI(14), .DI(15), .A1(9) },
    },
    .{
        .edge = .h4,
        .secondary = .h3,
        .d = 4,
        .slots = .{ .A1(10), .A2(10), .A1(11), .A2(11) },
    },
};

const bram_inputs: [common.BramInput.TOTAL]BramInputDesc = blk: {
    var t: [common.BramInput.TOTAL]BramInputDesc = undefined;
    for (bram_input_entries) |e| {
        for (e.slots, 0..4) |in, slot| {
            t[in.idx()] = BramInputDesc{
                .edge = e.edge,
                .secondary = e.secondary,
                .d = e.d,
                .slot = @intCast(slot),
            };
        }
    }
    break :blk t;
};

pub fn decodeBramInput(in: common.BramInput, code: u5) BramInputSrc {
    switch (in) {
        .a1, .a2, .di => {
            const desc = bram_inputs[in.idx()];
            const p: u1 = @intCast(desc.slot >> 1);
            const x: u1 = @intCast(desc.slot & 1);
            switch (code) {
                0 => return .zero,
                1 => return .one,

                // Primary
                2...10 => {
                    const to: common.TurnOrientation = if (x == 0) .cw else .ccw;
                    const dir = desc.edge.side().?.turnDir(to);
                    const idx = code - 2; // 0..8

                    return .{ .wire = window4(
                        desc.edge,
                        dir,
                        p,
                        0,
                        idx,
                    ) };
                },

                // Secondary
                11...15 => {
                    const dir: common.Direction = if (x == 0) .left else .right;
                    const idx = code - 11; // 0..4

                    return .{ .wire = window4(
                        desc.secondary,
                        dir,
                        1 - p,
                        desc.d,
                        idx,
                    ) };
                },
                16...31 => @panic("BRAM A1,B1,DI codes are 4 bits!"),
            }
        },
        .we1, .we2 => switch (code) {
            0 => return .zero,
            1 => return .one,

            // Primary
            2...31 => {
                const k = code - 2; // 0..29
                const side = ([3]common.BigEdge{ .h1, .h2, .h3 })[k / 10];
                const dir: common.Direction = if ((k % 10) < 5) .left else .right;
                const j = k % 5;
                const parity: u1 = if (in == .we1) 0 else 1;

                return .{ .wire = window4(side, dir, parity, 7, j) };
            },
        },
    }
}

pub fn encodeBramInput(in: common.BramInput, src: BramInputSrc) ?u5 {
    const code_count = switch (in) {
        .a1, .a2, .di => 16,
        .we1, .we2 => 32,
    };
    for (0..code_count) |i| {
        const code: u5 = @intCast(i);
        if (std.meta.eql(decodeBramInput(in, code), src))
            return code;
    }
    return null;
}

pub const DspInputSrc = union(enum) {
    zero: void,
    one: void,
    wire: DirectionalWire4x1,
    code: u5,
};

const DspInputDesc = struct {
    edge: common.BigEdge,
    secondary: common.BigEdge,
    d: u8,
    parity: u1,
};

const DspInputEntry = struct {
    edge: common.BigEdge,
    secondary: common.BigEdge,
    d: u8,
    slots: [2]common.DspInput,
};

const dsp_input_entries: [16]DspInputEntry = .{
    .{
        .edge = .w0,
        .secondary = .h0,
        .d = 0,
        .slots = .{ .A(0), .B(0) },
    },
    .{
        .edge = .w0,
        .secondary = .h1,
        .d = 0,
        .slots = .{ .C(0), .C(1) },
    },
    .{
        .edge = .e0,
        .secondary = .h0,
        .d = 4,
        .slots = .{ .C(2), .C(3) },
    },
    .{
        .edge = .e0,
        .secondary = .h1,
        .d = 2,
        .slots = .{ .B(1), .A(1) },
    },

    .{
        .edge = .w1,
        .secondary = .h1,
        .d = 4,
        .slots = .{ .B(2), .A(2) },
    },
    .{
        .edge = .w1,
        .secondary = .h2,
        .d = 0,
        .slots = .{ .C(4), .C(5) },
    },
    .{
        .edge = .e1,
        .secondary = .h1,
        .d = 6,
        .slots = .{ .C(6), .C(7) },
    },
    .{
        .edge = .e1,
        .secondary = .h2,
        .d = 2,
        .slots = .{ .A(3), .B(3) },
    },

    .{
        .edge = .w2,
        .secondary = .h2,
        .d = 4,
        .slots = .{ .A(4), .B(4) },
    },
    .{
        .edge = .w2,
        .secondary = .h3,
        .d = 0,
        .slots = .{ .C(8), .C(9) },
    },
    .{
        .edge = .e2,
        .secondary = .h2,
        .d = 6,
        .slots = .{ .C(10), .C(11) },
    },
    .{
        .edge = .e2,
        .secondary = .h3,
        .d = 2,
        .slots = .{ .B(5), .A(5) },
    },

    .{
        .edge = .w3,
        .secondary = .h3,
        .d = 4,
        .slots = .{ .B(6), .A(6) },
    },
    .{
        .edge = .w3,
        .secondary = .h4,
        .d = 0,
        .slots = .{ .C(12), .C(13) },
    },
    .{
        .edge = .e3,
        .secondary = .h3,
        .d = 6,
        .slots = .{ .C(14), .C(15) },
    },
    .{
        .edge = .e3,
        .secondary = .h4,
        .d = 4,
        .slots = .{ .A(7), .B(7) },
    },
};

const dsp_inputs: [common.DspInput.TOTAL]DspInputDesc = blk: {
    var t: [common.DspInput.TOTAL]DspInputDesc = undefined;
    for (dsp_input_entries) |e| {
        for (e.slots, 0..2) |in, parity| {
            t[in.idx()] = DspInputDesc{
                .edge = e.edge,
                .secondary = e.secondary,
                .d = e.d,
                .parity = parity,
            };
        }
    }
    break :blk t;
};

pub fn decodeDspInput(in: common.DspInput, code: u5) DspInputSrc {
    switch (in) {
        .a, .b, .c => {
            const desc = dsp_inputs[in.idx()];
            switch (code) {
                0 => return .zero,
                1 => return .one,

                // Primary
                2...19 => {
                    const k = code - 2; // 0..17
                    const to = ([2]common.TurnOrientation{ .cw, .ccw })[k / 9];
                    const dir = desc.edge.side().?.turnDir(to);
                    const idx = k % 9;

                    return .{ .wire = window4(
                        desc.edge,
                        dir,
                        desc.parity,
                        0,
                        idx,
                    ) };
                },

                // Secondary
                20...31 => {
                    const k = code - 20; // 0..11
                    const dir = ([2]common.Direction{ .left, .right })[k / 6];
                    const idx = k % 6;

                    return .{ .wire = window4(
                        desc.secondary,
                        dir,
                        1 - desc.parity,
                        desc.d,
                        idx,
                    ) };
                },
            }
        },
        .ad, .md, .we => switch (code) {
            0 => return .zero,
            1 => return .one,

            // Primary
            2...31 => {
                const k = code - 2; // 0..29
                const side = ([3]common.BigEdge{ .h1, .h2, .h3 })[k / 10];
                const dir: common.Direction = if ((k % 10) < 5) .left else .right;
                const j = k % 5;

                return .{ .wire = window4(side, dir, 0, 7, j) };
            },
        },
    }
}

pub fn encodeDspInput(in: common.DspInput, src: DspInputSrc) ?u5 {
    for (0..32) |i| {
        const code: u5 = @intCast(i);
        if (std.meta.eql(decodeDspInput(in, code), src))
            return code;
    }
    return null;
}

pub const IoInputSrc = union(enum) {
    zero: void,
    one: void,
    wire: DirectionalWire1x1,
    code: u5,
};

const IoInputDesc = struct {
    parity: u1,
    d: u8,
};

const io_inputs: std.EnumArray(common.IoInput, IoInputDesc) = .init(.{
    .o = IoInputDesc{ .parity = 0, .d = 0 },
    .ie = IoInputDesc{ .parity = 0, .d = 3 },
    .ee = IoInputDesc{ .parity = 0, .d = 6 },

    .e = IoInputDesc{ .parity = 1, .d = 0 },
    .oe = IoInputDesc{ .parity = 1, .d = 4 },
});

pub fn decodeIoInput(in: common.IoInput, side: common.Side, code: u5) IoInputSrc {
    const desc = io_inputs.get(in);
    switch (code) {
        0 => return .zero,
        1 => return .one,

        // Primary
        2...19 => {
            const k = code - 2; // 0..17
            const to = ([2]common.TurnOrientation{ .cw, .ccw })[k / 9];
            const dir = side.turnDir(to);
            const idx = k % 9;

            return .{ .wire = window1(
                side,
                dir,
                desc.parity,
                0,
                idx,
            ) };
        },
        // Secondary
        20...31 => {
            const k = code - 20; // 0...11
            const to = ([2]common.TurnOrientation{ .cw, .ccw })[k / 6];
            const dir = side.turnDir(to);
            const idx = k % 6;
            return .{ .wire = window1(
                side,
                dir,
                1 - desc.parity,
                desc.d,
                idx,
            ) };
        },
    }
}

pub fn encodeIoInput(in: common.IoInput, side: common.Side, src: IoInputSrc) ?u5 {
    for (0..32) |i| {
        const code: u5 = @intCast(i);
        if (std.meta.eql(decodeIoInput(in, side, code), src))
            return code;
    }
    return null;
}

pub const SwitchSinkSrc = union(enum) {
    out: TileSource,
    wire: DirectionalWire1x1,
};

pub const TileSource = struct {
    corner: common.Corner,
    index: u2,
};

pub fn decodeSwitchSink(sink: DirectionalWire1x1, code: u4) SwitchSinkSrc {
    const u = sink.local_track;
    const s = sink.side.int();
    switch (code) {
        // Tile output
        0...3 => {
            const corner = ([4]common.Corner{ .nw, .ne, .se, .sw })[code];
            const index: u2 = @intCast((u + s + code) % 4);
            return .{ .out = .{ .corner = corner, .index = index } };
        },

        // L1
        4...6 => {
            const k = code - 4; // 0..2
            const src_side = ([3]common.Side{
                sink.side.straight(),
                sink.side.left(),
                sink.side.right(),
            })[k];

            const src_track = switch (sink.class) {
                .l1 => ([3]u8{
                    u,
                    (u + 1) % 6,
                    (u + 2) % 6,
                })[k],
                .l4 => ([3]u8{
                    3 * u,
                    3 * u + 1,
                    3 * u + 2,
                })[k],
                .l16 => ([3]u8{
                    4,
                    5,
                    5,
                })[k],
            };

            return .{ .wire = .{
                .class = .l1,
                .side = src_side,
                .dir = src_side.inDir(),
                .local_track = src_track,
            } };
        },

        // L4
        7...12 => {
            const k = code - 7; // 0..5
            const src_side = ([3]common.Side{
                sink.side.straight(),
                sink.side.left(),
                sink.side.right(),
            })[k / 2];
            const src_track = k % 2;

            return .{ .wire = .{
                .class = .l4,
                .side = src_side,
                .dir = src_side.inDir(),
                .local_track = src_track,
            } };
        },

        // L16
        13...15 => {
            const k = code - 13; // 0..2
            const src_side = ([3]common.Side{
                sink.side.straight(),
                sink.side.left(),
                sink.side.right(),
            })[k];

            return .{ .wire = .{
                .class = .l16,
                .side = src_side,
                .dir = src_side.inDir(),
                .local_track = 0,
            } };
        },
    }
}

pub fn encodeSwitchSink(sink: DirectionalWire1x1, src: SwitchSinkSrc) ?u4 {
    for (0..16) |i| {
        const code: u4 = @intCast(i);
        if (std.meta.eql(decodeSwitchSink(sink, code), src))
            return code;
    }
    return null;
}

test "encode is the inverse of decode" {
    for (std.enums.values(common.LogicInput)) |in| {
        for (0..32) |i| {
            const code: u5 = @intCast(i);
            try std.testing.expectEqual(
                code,
                encodeLogicInput(in, decodeLogicInput(in, code)),
            );
        }
    }

    for (0..common.BramInput.TOTAL) |idx| {
        const in = common.BramInput.fromIdx(@intCast(idx));
        const code_count: usize = switch (in) {
            .a1, .a2, .di => 16,
            .we1, .we2 => 32,
        };
        for (0..code_count) |i| {
            const code: u5 = @intCast(i);
            try std.testing.expectEqual(
                code,
                encodeBramInput(in, decodeBramInput(in, code)),
            );
        }
    }

    for (0..common.DspInput.TOTAL) |idx| {
        const in = common.DspInput.fromIdx(@intCast(idx));
        for (0..32) |i| {
            const code: u5 = @intCast(i);
            try std.testing.expectEqual(
                code,
                encodeDspInput(in, decodeDspInput(in, code)),
            );
        }
    }

    for (std.enums.values(common.IoInput)) |in| {
        for (std.enums.values(common.Side)) |side| {
            for (0..32) |i| {
                const code: u5 = @intCast(i);
                try std.testing.expectEqual(
                    code,
                    encodeIoInput(in, side, decodeIoInput(in, side, code)),
                );
            }
        }
    }

    for (std.enums.values(common.Side)) |side| {
        for (std.enums.values(common.WireClass)) |class| {
            const local_track_count: u8 = switch (class) {
                .l1 => 6,
                .l4 => 2,
                .l16 => 1,
            };
            for (0..local_track_count) |local_track| {
                const sink = DirectionalWire1x1{
                    .side = side,
                    .dir = side.outDir(),
                    .class = class,
                    .local_track = @intCast(local_track),
                };
                for (0..16) |i| {
                    const code: u4 = @intCast(i);
                    try std.testing.expectEqual(
                        code,
                        encodeSwitchSink(sink, decodeSwitchSink(sink, code)),
                    );
                }
            }
        }
    }
}
