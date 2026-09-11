const std = @import("std");
const common = @import("../common.zig");
const DeviceModel = @import("../DeviceModel.zig");
const Interner = @import("Interner.zig").Interner;
const Indexes = @import("Indexes.zig");

const Netlist = @This();

alloc: std.mem.Allocator,
str_arena: std.heap.ArenaAllocator,
model: DeviceModel,
design_name: []const u8,
passes: std.EnumMap(Pass, []const u8),

cells: std.ArrayList(Cell),
ports: std.ArrayList(Net.Ref),

nets: std.ArrayList(Net),
route_edges: std.ArrayList(RouteEdge),

net_base_names: Interner(Net.BaseId),
cell_names: Interner(Cell.Ref),
pack_names: Interner(PackId),

net_refs: std.AutoHashMapUnmanaged(struct { Net.BaseId, Indexes }, Net.Ref),

pub const Pass = enum { synth, opt, techmap, pack, place, route };

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
        .ports = .empty,

        .nets = .empty,
        .route_edges = .empty,

        .cell_names = .empty,
        .net_base_names = .empty,
        .net_refs = .empty,
        .pack_names = .empty,
    };
    self.design_name = self.str_arena.allocator().dupe(u8, design_name) catch common.oom();
}

pub fn deinit(self: *Netlist) void {
    self.str_arena.deinit();
    self.cells.deinit(self.alloc);
    self.ports.deinit(self.alloc);
    self.nets.deinit(self.alloc);
    self.route_edges.deinit(self.alloc);
    self.cell_names.deinit(self.alloc);
    self.net_base_names.deinit(self.alloc);
    self.net_refs.deinit(self.alloc);
    self.pack_names.deinit(self.alloc);
}

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

pub const Net = struct {
    name: BaseId,
    indexes: Indexes,
    kind: Kind,
    route_start: u32 = 0,
    route_len: u16 = 0,
    period_ps: ?u32 = null,
    network: ?u3 = null,
    pin: ?u16 = null,

    pub const Kind = enum { net, clock, reset };

    pub const BaseId = enum(u32) { _ };
    pub const Ref = enum(u32) {
        unbound = 0xFFFF_FFFF,
        zero = 0xFFFF_FFFE,
        one = 0xFFFF_FFFD,
        _, // A net index
    };

    pub const Printable = struct {
        name: []const u8,
        indexes: Indexes,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("{s}{f}", .{ self.name, self.indexes });
        }
    };

    pub fn fmt(n: *const Net, netlist: *const Netlist) Printable {
        return Printable{
            .name = netlist.net_base_names.get(n.name),
            .indexes = n.indexes,
        };
    }
};

pub fn findNetBaseId(self: *const Netlist, name: []const u8) ?Net.BaseId {
    return self.net_base_names.find(name);
}
pub fn internNetBaseId(self: *Netlist, name: []const u8) Net.BaseId {
    return self.net_base_names.intern(self.alloc, self.str_arena.allocator(), name);
}

pub const PackId = enum(u32) { none = 0xFFFF_FFFF, _ };
pub fn internPackId(self: *Netlist, name: []const u8) PackId {
    return self.pack_names.intern(self.alloc, self.str_arena.allocator(), name);
}

pub fn getNet(self: *Netlist, ref: Net.Ref) *Net {
    std.debug.assert(ref != .unbound and ref != .zero and ref != .one);
    return &self.nets.items[@intFromEnum(ref)];
}

pub fn findNetRef(self: *Netlist, name_id: Net.BaseId, indexes: Indexes) ?Net.Ref {
    return self.net_refs.get(.{ name_id, indexes });
}
pub fn defineNet(
    self: *Netlist,
    name_id: Net.BaseId,
    indexes: Indexes,
    kind: ?Net.Kind,
) error{NetKindConflict}!Net.Ref {
    const entry = self.net_refs.getOrPut(
        self.alloc,
        .{ name_id, indexes },
    ) catch common.oom();

    if (!entry.found_existing) {
        entry.value_ptr.* = @enumFromInt(self.nets.items.len);
        self.nets.append(self.alloc, Net{
            .name = name_id,
            .indexes = indexes,
            .kind = kind orelse .net,
        }) catch common.oom();
    } else if (kind) |k| {
        const old_kind = self.getNet(entry.value_ptr.*).kind;
        if (old_kind != k)
            return error.NetKindConflict;
    }

    return entry.value_ptr.*;
}

pub const CellType = union(enum) {
    physical: Physical,
    logical: Logical,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self) {
            .physical => |t| try writer.writeAll(Physical.names.get(t)),
            .logical => |t| try writer.print("${s}", .{@tagName(t)}),
        }
    }

    pub const Physical = enum {
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
            var r: std.EnumArray(Physical, []const u8) = .initUndefined();
            for (std.enums.values(Physical)) |t|
                r.set(t, common.upper(@tagName(t)));
            break :blk r;
        };

        pub const ParamsUnion = union(Physical) {
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

    pub const Logical = enum {
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

        pub const ParamsUnion = union(Logical) {
            add: WidthOnlyParams,
            sub: WidthOnlyParams,
            mul: struct { width: ?u16 = null, signed_a: ?bool = null, signed_b: ?bool = null },
            mux: struct { width: ?u16 = null, depth: ?u4 = null },
            decode: struct { depth: ?u4 = null },
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

        pub fn Params(comptime t: Logical) type {
            return @FieldType(ParamsUnion, @tagName(t));
        }
    };
};

pub const Cell = struct {
    params: union(std.meta.Tag(CellType)) {
        physical: CellType.Physical.ParamsUnion,
        logical: CellType.Logical.ParamsUnion,
    },
    ports_start: u32 = 0,
    ports_len: u16 = 0,
    clk: Net.Ref = .unbound,
    rst: Net.Ref = .unbound,
    pack: PackId = .none,
    slot: SlotId = .none,
    site: ?common.TileCoords = null,

    pub const Ref = enum(u32) {
        none = 0xFFFF_FFFF,
        _, // A cell index
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

    pub const PortKind = enum { in, out };

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
                            CellType.Physical.ParamsUnion,
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
                            CellType.Logical.ParamsUnion,
                            @tagName(cl),
                            .{},
                        ),
                    },
                },
            },
        };
    }
};

pub fn getCellRef(
    self: *Netlist,
    name: []const u8,
    t: ?CellType,
) error{ UnknownCellType, CellTypeConflict }!Cell.Ref {
    if (self.cell_names.find(name)) |id| {
        if (t) |ct| if (!std.meta.eql(self.getCell(id).cellType(), ct))
            return error.CellTypeConflict;
        return id;
    }

    const ct = t orelse return error.UnknownCellType;
    const ref = self.cell_names.intern(self.alloc, self.str_arena.allocator(), name);
    std.debug.assert(@intFromEnum(ref) == self.cells.items.len);
    self.cells.append(self.alloc, .init(ct)) catch common.oom();
    return ref;
}

pub fn getCell(self: *Netlist, id: Cell.Ref) *Cell {
    std.debug.assert(id != .none);
    return &self.cells.items[@intFromEnum(id)];
}

pub fn allocateCellPorts(self: *Netlist, cell: *Cell, count: usize) void {
    if (cell.ports_len != 0) return;

    cell.ports_len = @intCast(count);
    cell.ports_start = @intCast(self.ports.items.len);
    self.ports.appendNTimes(self.alloc, .unbound, count) catch common.oom();
}

pub fn getCellPort(self: *Netlist, cell: *const Cell, index: u32) *Net.Ref {
    std.debug.assert(index < cell.ports_len);
    return &self.ports.items[cell.ports_start + index];
}
