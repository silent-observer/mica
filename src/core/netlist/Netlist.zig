const std = @import("std");
const common = @import("../common.zig");
const DeviceModel = @import("../DeviceModel.zig");
const Interner = @import("Interner.zig").Interner;

const Netlist = @This();

alloc: std.mem.Allocator,
str_arena: std.heap.ArenaAllocator,
model: DeviceModel,
design_name: []const u8,
passes: std.EnumMap(Pass, []const u8),

cells: std.ArrayList(Cell),
in_ports: std.ArrayList(NetRef),
out_ports: std.ArrayList(NetRef),

nets: std.ArrayList(Net),
global_nets: std.ArrayList(GlobalNet),
route_edges: std.ArrayList(RouteEdge),

net_names: Interner(NetNameId),
cell_names: Interner(CellId),
pack_names: Interner(PackId),

net_kinds: std.ArrayList(NetKind),
net_refs: std.AutoHashMapUnmanaged(NetKey, NetRef),

pub const Pass = enum { synth, opt, techmap, pack, place, route };

pub const NetNameId = enum(u32) { _ };
pub const NetKind = enum {
    net,
    clock,
    reset,
};

pub const CellId = enum(u32) {
    none = 0xFFFF_FFFF,
    _, // A cell index
};
pub const NetRef = packed struct(u32) {
    idx: u31,
    global: bool,

    const unbound: NetRef = .{ .global = false, .idx = 0x7FFF_FFFF };
    const zero: NetRef = .{ .global = false, .idx = 0x7FFF_FFFE };
    const one: NetRef = .{ .global = false, .idx = 0x7FFF_FFFD };

    pub fn netIdx(ref: NetRef) u31 {
        std.debug.assert(!ref.global);
        std.debug.assert(ref != unbound);
        std.debug.assert(ref != zero);
        std.debug.assert(ref != one);
        return ref.idx;
    }

    pub fn globalIdx(ref: NetRef) u31 {
        std.debug.assert(ref.global);
        return ref.idx;
    }
};

pub const PackId = enum(u32) {
    none = 0xFFFF_FFFF,
    _,
};
pub const ClockId = enum(u8) {
    none = 0xFF,
    _,
};
pub const ResetId = enum(u8) {
    none = 0xFF,
    _,
};
pub const SlotId = enum {
    none,
    le1,
    le2,
    le1a,
    le1b,
    le2a,
    le2b,
};

pub const CellType = union(enum) {
    physical: PhysicalCellType,
    logical: LogicalCellType,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self) {
            .physical => |t| try writer.writeAll(PhysicalCellType.names.get(t)),
            .logical => |t| try writer.print("${s}", .{@tagName(t)}),
        }
    }
};
pub const PhysicalCellType = enum {
    lut4,
    lut3,
    ff,
    carry,
    mem,
    mem_dual,
    bram,
    bram_dual,
    dsp,
    dsp_acc,
    io,

    pub const names = blk: {
        var r: std.EnumArray(PhysicalCellType, []const u8) = .initUndefined();
        for (std.enums.values(PhysicalCellType)) |t|
            r.set(t, common.upper(@tagName(t)));
        break :blk r;
    };

    pub const ParamsUnion = union(PhysicalCellType) {
        lut4: struct { lut: ?u16 = null },
        lut3: struct { lut: ?u8 = null },
        ff: struct {},
        carry: struct { lut_p: ?u8 = null, lut_g: ?u8 = null },
        mem: struct { init: ?u32 = null },
        mem_dual: struct { init0: ?u16 = null, init1: ?u16 = null },
        bram: BramParams,
        bram_dual: BramParams,
        dsp: DspParams,
        dsp_acc: DspParams,
        io: struct { pin: ?u16 = null, pullup: ?bool = null, pulldown: ?bool = null },

        const BramParams = struct { width: ?common.BramWidth = null };
        const DspParams = struct { signed_a: ?bool = null, signed_b: ?bool = null };
    };
};
pub const LogicalCellType = enum {
    add,
    sub,
    mul,
    mux,
    decode,
    @"and",
    @"or",
    xor,
    not,
    and_all,
    or_all,
    xor_all,
    ff,
    rom,
    rom_dual,
    ram,
    ram_dual,

    pub const ParamsUnion = union(LogicalCellType) {
        add: WidthOnlyParams,
        sub: WidthOnlyParams,
        mul: struct { width: ?u16 = null, signed_a: ?bool = null, signed_b: ?bool = null },
        mux: struct { width: ?u16 = null, depth: ?u8 = null },
        decode: struct { depth: ?u8 = null },
        @"and": WidthOnlyParams,
        @"or": WidthOnlyParams,
        xor: WidthOnlyParams,
        not: WidthOnlyParams,
        and_all: NOnlyParams,
        or_all: NOnlyParams,
        xor_all: NOnlyParams,
        ff: WidthOnlyParams,
        rom: MemoryParams,
        rom_dual: MemoryParams,
        ram: MemoryParams,
        ram_dual: MemoryParams,

        const WidthOnlyParams = struct { width: ?u16 = null };
        const NOnlyParams = struct { n: ?u16 = null };
        const MemoryParams = struct { data_width: ?u16 = null, addr_width: ?u16 = null };
    };
};

pub const MAX_INDEXES = 4;

pub const Cell = struct {
    params: union(std.meta.Tag(CellType)) {
        physical: PhysicalCellType.ParamsUnion,
        logical: LogicalCellType.ParamsUnion,
    },
    ins_start: u32 = 0,
    ins_len: u16 = 0,
    outs_start: u32 = 0,
    outs_len: u16 = 0,
    clk: ClockId = .none,
    rst: ResetId = .none,
    pack: PackId = .none,
    slot: SlotId = .none,
    site: ?common.TileCoords = null,

    pub fn cellType(c: *const Cell) CellType {
        return switch (c.params) {
            .physical => |p| .{ .physical = std.meta.activeTag(p) },
            .logical => |l| .{ .logical = std.meta.activeTag(l) },
        };
    }

    pub fn init(t: CellType) Cell {
        return switch (t) {
            .physical => |p| Cell{
                .params = .{
                    .physical = switch (p) {
                        inline else => |cp| @unionInit(
                            PhysicalCellType.ParamsUnion,
                            @tagName(cp),
                            .{},
                        ),
                    },
                },
            },
            .logical => |l| Cell{
                .params = .{
                    .logical = switch (l) {
                        inline else => |cl| @unionInit(
                            LogicalCellType.ParamsUnion,
                            @tagName(cl),
                            .{},
                        ),
                    },
                },
            },
        };
    }
};

pub const NetKey = struct {
    name: NetNameId,
    indexes: [MAX_INDEXES]u16,
    indexes_len: u8,
};

pub const Net = struct {
    key: NetKey,
    route_start: u32 = 0,
    route_len: u16 = 0,
};

pub const RouteEdge = union(enum) {
    switchbox: struct { at: common.SwitchCoords, dst: common.SwitchWire, src: u4 },
    logic: struct { at: common.TileCoords, input: common.LogicInput, src: u5 },
    bram: struct { at: common.TileCoords, input: common.BramInput, src: u5 },
    dsp: struct { at: common.TileCoords, input: common.DspInput, src: u5 },
    io: struct { at: common.TileCoords, input: common.IoInput, src: u5 },

    comptime {
        // NetlistParser builds these with @unionInit(RouteEdge, @tagName(t)),
        // so the tile variants have to stay named after the tile types.
        for (common.TileType.configurable) |t| {
            if (!@hasField(RouteEdge, @tagName(t)))
                @compileError("RouteEdge has no variant for tile type " ++ @tagName(t));
        }
    }
};

pub const GlobalNet = struct {
    key: NetKey,
    period_ps: ?u32 = null,
    network: ?u3 = null,
    pin: ?u16 = null,
};

pub fn init(
    self: *Netlist,
    alloc: std.mem.Allocator,
    model: DeviceModel,
    design_name: []const u8,
) void {
    self.* = Netlist{
        .alloc = alloc,
        .str_arena = .init(alloc),

        .model = model,
        .design_name = "",
        .passes = .init(.{}),

        .cells = .empty,
        .in_ports = .empty,
        .out_ports = .empty,

        .nets = .empty,
        .global_nets = .empty,
        .route_edges = .empty,

        .cell_names = .empty,
        .net_names = .empty,
        .net_kinds = .empty,
        .net_refs = .empty,
        .pack_names = .empty,
    };
    self.design_name = self.str_arena.allocator().dupe(u8, design_name) catch common.oom();
}

pub fn deinit(self: *Netlist) void {
    self.str_arena.deinit();
    self.cells.deinit(self.alloc);
    self.in_ports.deinit(self.alloc);
    self.out_ports.deinit(self.alloc);
    self.nets.deinit(self.alloc);
    self.global_nets.deinit(self.alloc);
    self.route_edges.deinit(self.alloc);
    self.cell_names.deinit(self.alloc);
    self.net_names.deinit(self.alloc);
    self.net_kinds.deinit(self.alloc);
    self.net_refs.deinit(self.alloc);
    self.pack_names.deinit(self.alloc);
}

pub fn getNetNameId(
    self: *Netlist,
    name: []const u8,
    kind: ?NetKind,
) error{NetKindConflict}!NetNameId {
    const id = self.net_names.intern(self.alloc, self.str_arena.allocator(), name);
    const idx: usize = @intFromEnum(id);

    std.debug.assert(idx <= self.net_kinds.items.len);
    if (idx == self.net_kinds.items.len) {
        self.net_kinds.append(self.alloc, kind orelse .net) catch common.oom();
    } else if (kind) |k| {
        if (self.net_kinds.items[idx] != k)
            return error.NetKindConflict;
    }
    return id;
}

pub fn getNetRef(self: *Netlist, key: NetKey) NetRef {
    const kind = self.getNetKind(key.name);
    const entry = self.net_refs.getOrPut(self.alloc, key) catch common.oom();
    if (!entry.found_existing) {
        switch (kind) {
            .net => {
                entry.value_ptr.* = .{
                    .idx = @intCast(self.nets.items.len),
                    .global = false,
                };
                self.nets.append(
                    self.alloc,
                    Net{ .key = key },
                ) catch common.oom();
            },
            .clock, .reset => {
                entry.value_ptr.* = .{
                    .idx = @intCast(self.global_nets.items.len),
                    .global = true,
                };
                self.global_nets.append(
                    self.alloc,
                    GlobalNet{ .key = key },
                ) catch common.oom();
            },
        }
    }
    return entry.value_ptr.*;
}

pub fn getNetKind(self: *Netlist, id: NetNameId) NetKind {
    return self.net_kinds.items[@intFromEnum(id)];
}

pub fn findNetKind(self: *Netlist, name: []const u8) ?NetKind {
    return self.getNetKind(self.net_names.find(name) orelse return null);
}

pub fn getNet(self: *Netlist, ref: NetRef) *Net {
    return &self.nets.items[ref.netIdx()];
}

pub fn getGlobalNet(self: *Netlist, ref: NetRef) *GlobalNet {
    return &self.global_nets.items[ref.globalIdx()];
}

pub fn getCellId(
    self: *Netlist,
    name: []const u8,
    t: ?CellType,
) error{ UnknownCellType, CellTypeConflict }!CellId {
    if (self.cell_names.find(name)) |id| {
        if (t) |ct| if (!std.meta.eql(self.getCell(id).cellType(), ct))
            return error.CellTypeConflict;
        return id;
    }

    const ct = t orelse return error.UnknownCellType;
    const id = self.cell_names.intern(self.alloc, self.str_arena.allocator(), name);
    std.debug.assert(@intFromEnum(id) == self.cells.items.len);
    self.cells.append(self.alloc, .init(ct)) catch common.oom();
    return id;
}

pub fn getCell(self: *Netlist, id: CellId) *Cell {
    std.debug.assert(id != .none);
    return &self.cells.items[@intFromEnum(id)];
}

pub fn getPackId(self: *Netlist, name: []const u8) PackId {
    return self.pack_names.intern(self.alloc, self.str_arena.allocator(), name);
}
