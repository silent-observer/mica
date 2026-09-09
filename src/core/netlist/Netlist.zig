const std = @import("std");
const common = @import("../common.zig");
const DeviceModel = @import("../DeviceModel.zig");

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

net_names: std.StringHashMapUnmanaged(NetNameId),
net_kinds: std.ArrayList(NetKind),
net_refs: std.AutoHashMapUnmanaged(NetKey, NetRef),
cell_names: std.StringHashMapUnmanaged(CellId),
pack_names: std.StringHashMapUnmanaged(PackId),

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
    ff_logical,
    rom,
    rom_dual,
    ram,
    ram_dual,
    input,
    output,
    bidir,
    blackbox,
};

pub const MAX_PARAMS = 4;
pub const MAX_INDEXES = 4;

pub const Cell = struct {
    t: CellType,
    name: []const u8,
    params: [MAX_PARAMS]u32 = undefined,
    present: u16 = 0,
    ins_start: u32 = 0,
    ins_len: u16 = 0,
    outs_start: u32 = 0,
    outs_len: u16 = 0,
    clk: ClockId = .none,
    rst: ResetId = .none,
    pack: PackId = .none,
    slot: SlotId = .none,
    site: ?common.TileCoords = null,
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

/// Initialises in place: `str_arena` has to be at its final address before
/// anything is allocated from it, or the allocation lands in a copy that is
/// then dropped.
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

pub fn getNetNameId(self: *Netlist, name: []const u8, kind: NetKind) NetNameId {
    const entry = self.net_names.getOrPut(self.alloc, name) catch common.oom();
    if (!entry.found_existing) {
        entry.key_ptr.* = self.str_arena.allocator().dupe(u8, name) catch common.oom();
        entry.value_ptr.* = @enumFromInt(self.net_kinds.items.len);
        self.net_kinds.append(self.alloc, kind) catch common.oom();
    }
    return entry.value_ptr.*;
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

pub fn getNet(self: *Netlist, ref: NetRef) *Net {
    return &self.nets.items[ref.netIdx()];
}

pub fn getGlobalNet(self: *Netlist, ref: NetRef) *GlobalNet {
    return &self.global_nets.items[ref.globalIdx()];
}

pub fn getCellId(self: *Netlist, name: []const u8, t: ?CellType) error{UnknownCellType}!CellId {
    const entry = self.cell_names.getOrPut(self.alloc, name) catch common.oom();
    if (!entry.found_existing) {
        if (t == null)
            return error.UnknownCellType;
        entry.key_ptr.* = self.str_arena.allocator().dupe(u8, name) catch common.oom();
        entry.value_ptr.* = @enumFromInt(self.cells.items.len);
        self.cells.append(self.alloc, Cell{
            .name = entry.key_ptr.*,
            .t = t.?,
        }) catch common.oom();
    }
    return entry.value_ptr.*;
}

pub fn getCell(self: *Netlist, id: CellId) *Cell {
    std.debug.assert(id != .none);
    return &self.cells.items[@intFromEnum(id)];
}

pub fn getPackId(self: *Netlist, name: []const u8) PackId {
    const entry = self.pack_names.getOrPut(self.alloc, name) catch common.oom();
    if (!entry.found_existing) {
        entry.key_ptr.* = self.str_arena.allocator().dupe(u8, name) catch common.oom();
        entry.value_ptr.* = @enumFromInt(self.pack_names.count());
    }
    return entry.value_ptr.*;
}
