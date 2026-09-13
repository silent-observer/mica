//! The universal IR carried between synthesis and the bitstream: a flat-array
//! store of nets and cells, addressed by typed index enums rather than by
//! pointer, since every list can reallocate. There is no tile object - a tile
//! is the cells sharing a `SITE`. The format is monotonic, so the mutators here
//! all take an idempotent repeat and reject only a contradicting one.

const std = @import("std");
const common = @import("../common.zig");
const DeviceModel = @import("../DeviceModel.zig");
const Interner = @import("Interner.zig").Interner;
const Indexes = @import("Indexes.zig");

pub const Net = @import("Net.zig");
pub const Cell = @import("Cell.zig");
pub const Meta = @import("Meta.zig");
pub const cell_type = @import("cell_type.zig");
pub const route = @import("route.zig");

pub const Netlist = @This();

gpa: std.mem.Allocator,
arena: std.heap.ArenaAllocator,
model: DeviceModel,
design_name: []const u8,
passes: std.EnumMap(Pass, []const u8),
meta: Meta.List,

metadata: std.ArrayList(Meta),

cells: std.ArrayList(Cell),
port_nets: std.ArrayList(Net.Ref),

nets: std.ArrayList(Net),
route_edges: std.ArrayList(route.Edge),

net_base_names: Interner(Net.BaseId),
cell_names: Interner(Cell.Ref),
pack_names: Interner(Cell.PackId),
meta_tags: Interner(Meta.TagId),

net_refs: std.AutoHashMapUnmanaged(struct { Net.BaseId, Indexes }, Net.Ref),

pub fn init(
    gpa: std.mem.Allocator,
    model: DeviceModel,
    design_name: []const u8,
) Netlist {
    return Netlist{
        .gpa = gpa,
        .arena = .init(gpa),

        .model = model,
        .design_name = gpa.dupe(u8, design_name) catch common.oom(),
        .passes = .init(.{}),
        .meta = .{},

        .metadata = .empty,

        .cells = .empty,
        .port_nets = .empty,

        .nets = .empty,
        .route_edges = .empty,

        .cell_names = .init(gpa),
        .net_base_names = .init(gpa),
        .pack_names = .init(gpa),
        .meta_tags = .init(gpa),
        .net_refs = .empty,
    };
}

pub fn deinit(self: *Netlist) void {
    self.gpa.free(self.design_name);
    self.arena.deinit();
    self.metadata.deinit(self.gpa);
    self.cells.deinit(self.gpa);
    self.port_nets.deinit(self.gpa);
    self.nets.deinit(self.gpa);
    self.route_edges.deinit(self.gpa);
    self.cell_names.deinit();
    self.net_base_names.deinit();
    self.pack_names.deinit();
    self.meta_tags.deinit();
    self.net_refs.deinit(self.gpa);
}

// Passes

pub const Pass = enum { synth, opt, techmap, pack, place, route };
pub fn setPass(self: *Netlist, pass: Pass, text: []const u8) void {
    const new_text = if (self.passes.get(pass)) |old_text| blk: {
        const r = std.mem.concat(
            self.arena.allocator(),
            u8,
            &.{ old_text, "\n", text },
        ) catch common.oom();
        self.arena.allocator().free(old_text);
        break :blk r;
    } else self.arena.allocator().dupe(u8, text) catch common.oom();
    self.passes.put(pass, new_text);
}

// Metadata

pub const Owner = union(enum) { file, net: Net.Ref, cell: Cell.Ref };

pub fn addMetadata(self: *Netlist, owner: Owner, tag: []const u8, data: []const u8) void {
    const list = switch (owner) {
        .file => &self.meta,
        .cell => |ref| &self.getCell(ref).meta,
        .net => |ref| &self.getNet(ref).meta,
    };
    const tag_id = self.meta_tags.intern(tag);

    var it = list.head;
    while (it != .none) : (it = self.metadata.items[@intFromEnum(it)].next) {
        const m = self.metadata.items[@intFromEnum(it)];
        if (m.tag == tag_id and std.mem.eql(u8, m.data, data)) return;
    }

    const ref: Meta.Ref = @enumFromInt(self.metadata.items.len);
    self.metadata.append(self.gpa, .{
        .tag = tag_id,
        .data = self.arena.allocator().dupe(u8, data) catch common.oom(),
    }) catch common.oom();

    if (list.tail == .none)
        list.head = ref
    else
        self.metadata.items[@intFromEnum(list.tail)].next = ref;
    list.tail = ref;
}

// Nets

pub fn findNetRef(self: *const Netlist, name_id: Net.BaseId, indexes: Indexes) ?Net.Ref {
    return self.net_refs.get(.{ name_id, indexes });
}

/// Asserts `ref` names a real net; use `Net.Ref.fmt` for a ref that may still
/// be a sentinel.
pub fn getNet(self: *const Netlist, ref: Net.Ref) *Net {
    std.debug.assert(ref != .none and ref != .zero and ref != .one);
    return &self.nets.items[@intFromEnum(ref)];
}

/// Returns the existing ref if the net is already defined. A `kind` may be
/// restated as long as it agrees; contradicting it is an error.
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

// Cells

/// Cell names are interned in `cells` order, so an interned id *is* the
/// `Cell.Ref`. `t` may be omitted only once the cell already exists.
pub fn internCellRef(
    self: *Netlist,
    name: []const u8,
    t: ?cell_type.Full,
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

// Cell ports

/// No-op once the span exists: `ports_len` is frozen by the first `in`/`out`
/// binding, so a parameter changing afterwards cannot resize it.
pub fn allocateCellPorts(self: *Netlist, cell_ref: Cell.Ref, count: usize) void {
    const cell = self.getCell(cell_ref);
    if (cell.ports_len != 0) return;

    cell.ports_len = @intCast(count);
    cell.ports_start = @intCast(self.port_nets.items.len);
    self.port_nets.appendNTimes(self.gpa, .none, count) catch common.oom();
}

pub fn getCellPort(self: *const Netlist, cell: *const Cell, index: u32) *Net.Ref {
    std.debug.assert(index < cell.ports_len);
    return &self.port_nets.items[cell.ports_start + index];
}

pub fn getCellPorts(self: *const Netlist, cell: *const Cell, start: u32, len: u32) []const Net.Ref {
    std.debug.assert(start + len <= cell.ports_len);
    return self.port_nets.items[cell.ports_start + start ..][0..len];
}
