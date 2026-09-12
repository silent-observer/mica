const std = @import("std");
const common = @import("../common.zig");
const DeviceModel = @import("../DeviceModel.zig");
const Interner = @import("Interner.zig").Interner;
const Indexes = @import("Indexes.zig");

const Netlist = @This();

gpa: std.mem.Allocator,
model: DeviceModel,
design_name: []const u8,
passes: std.EnumMap(Pass, []const u8),

cells: std.ArrayList(Cell),
port_nets: std.ArrayList(Net.Ref),

nets: std.ArrayList(Net),
route_edges: std.ArrayList(RouteEdge),

net_base_names: Interner(Net.BaseId),
cell_names: Interner(Cell.Ref),
pack_names: Interner(PackId),

net_refs: std.AutoHashMapUnmanaged(struct { Net.BaseId, Indexes }, Net.Ref),

pub fn init(
    gpa: std.mem.Allocator,
    model: DeviceModel,
    design_name: []const u8,
) Netlist {
    return Netlist{
        .gpa = gpa,

        .model = model,
        .design_name = gpa.dupe(u8, design_name) catch common.oom(),
        .passes = .init(.{}),

        .cells = .empty,
        .port_nets = .empty,

        .nets = .empty,
        .route_edges = .empty,

        .cell_names = .init(gpa),
        .net_base_names = .init(gpa),
        .pack_names = .init(gpa),
        .net_refs = .empty,
    };
}

pub fn deinit(self: *Netlist) void {
    self.gpa.free(self.design_name);
    {
        var iter = self.passes.iterator();
        while (iter.next()) |e| {
            self.gpa.free(e.value.*);
        }
    }
    self.cells.deinit(self.gpa);
    self.port_nets.deinit(self.gpa);
    self.nets.deinit(self.gpa);
    self.route_edges.deinit(self.gpa);
    self.cell_names.deinit();
    self.net_base_names.deinit();
    self.pack_names.deinit();
    self.net_refs.deinit(self.gpa);
}

pub const Pass = enum { synth, opt, techmap, pack, place, route };
pub fn setPass(self: *Netlist, pass: Pass, text: []const u8) void {
    const new_text = if (self.passes.get(pass)) |old_text| blk: {
        const r = std.mem.concat(
            self.gpa,
            u8,
            &.{ old_text, "\n", text },
        ) catch common.oom();
        self.gpa.free(old_text);
        break :blk r;
    } else self.gpa.dupe(u8, text) catch common.oom();
    self.passes.put(pass, new_text);
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
        none = 0xFFFF_FFFF,
        zero = 0xFFFF_FFFE,
        one = 0xFFFF_FFFD,
        _, // A net index

        pub fn fmt(ref: Ref, netlist: *const Netlist) Printable {
            return switch (ref) {
                .none => Printable{ .name = "<none>", .indexes = .empty },
                .zero => Printable{ .name = "0", .indexes = .empty },
                .one => Printable{ .name = "1", .indexes = .empty },
                else => netlist.getNet(ref).fmt(netlist),
            };
        }
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

pub const PackId = enum(u32) { none = 0xFFFF_FFFF, _ };

pub fn getNet(self: *const Netlist, ref: Net.Ref) *Net {
    std.debug.assert(ref != .none and ref != .zero and ref != .one);
    return &self.nets.items[@intFromEnum(ref)];
}

pub fn findNetRef(self: *const Netlist, name_id: Net.BaseId, indexes: Indexes) ?Net.Ref {
    return self.net_refs.get(.{ name_id, indexes });
}

pub fn defineNet(
    self: *Netlist,
    name_id: Net.BaseId,
    indexes: Indexes,
    kind: ?Net.Kind,
) error{NetKindConflict}!Net.Ref {
    const entry = self.net_refs.getOrPut(
        self.gpa,
        .{ name_id, indexes },
    ) catch common.oom();

    if (!entry.found_existing) {
        entry.value_ptr.* = @enumFromInt(self.nets.items.len);
        self.nets.append(self.gpa, Net{
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
    clk: Net.Ref = .none,
    rst: Net.Ref = .none,
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

pub fn internCellRef(
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
    const ref = self.cell_names.intern(name);
    std.debug.assert(@intFromEnum(ref) == self.cells.items.len);
    self.cells.append(self.gpa, .init(ct)) catch common.oom();
    return ref;
}

pub fn getCell(self: *const Netlist, id: Cell.Ref) *Cell {
    std.debug.assert(id != .none);
    return &self.cells.items[@intFromEnum(id)];
}

pub fn allocateCellPorts(self: *Netlist, cell: *Cell, count: usize) void {
    if (cell.ports_len != 0) return;

    cell.ports_len = @intCast(count);
    cell.ports_start = @intCast(self.port_nets.items.len);
    self.port_nets.appendNTimes(self.gpa, .none, count) catch common.oom();
}

pub fn getCellPort(self: *const Netlist, cell: *const Cell, index: u32) *Net.Ref {
    std.debug.assert(index < cell.ports_len);
    return &self.port_nets.items[cell.ports_start + index];
}
