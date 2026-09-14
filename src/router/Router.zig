const std = @import("std");
const core = @import("core");
const Netlist = core.Netlist;
const Net = Netlist.Net;
const Cell = Netlist.Cell;
const NetIndex = Netlist.NetIndex;
const oom = core.common.oom;

const Router = @This();

scratch: std.mem.Allocator,
nl: *Netlist,
idx: NetIndex,

used_wires: std.AutoHashMapUnmanaged(core.routing.WireKey, Net.Ref),

fn init(nl: *Netlist, scratch: std.mem.Allocator) Router {
    return Router{
        .nl = nl,
        .scratch = scratch,
        .idx = .build(nl, scratch),
        .used_wires = .empty,
    };
}

fn deinit(r: *Router) void {
    r.idx.deinit(r.scratch);
    r.used_wires.deinit(r.scratch);
}

fn setRouteEdges(r: *const Router, net_ref: Net.Ref, edges: []const Netlist.route.Edge) void {
    const net = r.nl.getNet(net_ref);

    if (net.route_len == 0)
        net.route_start = @intCast(r.nl.route_edges.items.len)
    else
        std.debug.assert(net.route_start + net.route_len == r.nl.route_edges.items.len);

    net.route_len += @intCast(edges.len);

    r.nl.route_edges.appendSlice(r.nl.gpa, edges) catch oom();
}

fn routeSink(
    r: *Router,
    net_ref: Net.Ref,
    driver: NetIndex.PinRef,
    sink: NetIndex.PinRef,
    arena: std.mem.Allocator,
) void {
    const sink_cell = r.nl.getCell(sink.cell);
    const sink_site = Netlist.tile_mapping.resolveInputSite(
        r.nl,
        &r.idx,
        sink_cell,
        sink.port,
    ) orelse return;

    const driver_cell = r.nl.getCell(driver.cell);
    const driver_site = Netlist.tile_mapping.resolveOutputSite(
        driver_cell,
        driver.port,
    ) orelse @panic("Dedicated driver for general sink");

    // Special case for local logic tile connections
    if (std.meta.eql(sink_cell.site.?, driver_cell.site.?) and sink_site == .logic) {
        const logic_src = core.wire_codes.LogicInputSrc{
            .local = @enumFromInt(driver_site.idx),
        };
        const code = core.wire_codes.encodeInput(.logic, sink_site.logic, {}, logic_src);
        if (code) |c| {
            r.setRouteEdges(net_ref, &.{
                Netlist.route.Edge{ .logic = .{
                    .at = sink_cell.site.?,
                    .input = sink_site.logic,
                    .src = c,
                } },
            });
            return;
        }
    }

    var queue: std.array_list.Managed(core.routing.WireKey) = .init(arena);
    var visited: std.AutoHashMap(core.routing.WireKey, struct {
        parent: ?core.routing.WireKey,
        edge: Netlist.route.Edge,
    }) = .init(arena);

    switch (sink_site) {
        .inert => unreachable,
        inline else => |in, t| {
            const max_codes: usize = @as(usize, 1) << core.wire_codes.codeBits(t, in);
            for (0..max_codes) |code| {
                const src = core.wire_codes.resolveInput(
                    t,
                    sink_cell.site.?,
                    in,
                    @intCast(code),
                    r.nl.model,
                );
                switch (src) {
                    .code => continue,
                    .wire => |w| {
                        const channel = switch (@TypeOf(w)) {
                            core.common.DirectionalWire1x1 => sink_cell.site.?.channel(w.side, r.nl.model.grid).?,
                            core.common.DirectionalWire4x1 => sink_cell.site.?.bigChannel(w.side, r.nl.model.grid),
                            else => comptime unreachable,
                        };
                        const wire_key = core.routing.segmentStart(
                            channel,
                            w.dir,
                            w.class,
                            w.track,
                            r.nl.model.grid,
                        ) orelse continue;
                        queue.insert(0, wire_key) catch oom();
                        visited.put(wire_key, .{
                            .parent = null,
                            .edge = switch (t) {
                                .inert => unreachable,
                                inline else => @unionInit(
                                    Netlist.route.Edge,
                                    @tagName(t),
                                    .{
                                        .at = sink_cell.site.?,
                                        .input = in,
                                        .src = @intCast(code),
                                    },
                                ),
                            },
                        }) catch oom();
                    },
                    else => continue,
                }
            }
        },
    }

    var path_start: ?core.routing.WireKey = null;
    var first_edge: ?Netlist.route.Edge = null;
    outer: while (queue.pop()) |wire_key| {
        if (r.used_wires.get(wire_key)) |wire_net| {
            if (wire_net == net_ref) {
                path_start = wire_key;
                break :outer;
            } else {
                // Already used by someone else
                continue;
            }
        }

        const switch_sink = core.common.SwitchWire{
            .side = wire_key.dir.side(),
            .class = wire_key.class,
            .track = wire_key.track,
        };
        for (0..16) |code| {
            const sink_src = core.wire_codes.resolveSwitchSink(
                wire_key.start,
                switch_sink,
                @intCast(code),
                r.nl.model.grid,
            );
            const edge = Netlist.route.Edge{ .switchbox = .{
                .at = wire_key.start,
                .dst = switch_sink,
                .src = @intCast(code),
            } };
            switch (sink_src) {
                .code => continue,
                .out => |ts| {
                    const ts_tile = wire_key.start.tile(ts.corner);
                    var want_tile = driver_cell.site.?;
                    want_tile.row += driver_site.tile_offset;
                    if (std.meta.eql(ts_tile, want_tile) and
                        (ts.any or driver_site.any or driver_site.idx == ts.index))
                    {
                        path_start = wire_key;
                        first_edge = edge;
                        break :outer;
                    }
                },
                .wire => |w| {
                    const start = core.routing.incomingStart(
                        wire_key.start,
                        w.side,
                        w.class,
                        r.nl.model.grid,
                    ) orelse continue;

                    const new_wire_key = core.routing.WireKey{
                        .start = start,
                        .dir = w.side.inDir(),
                        .class = w.class,
                        .track = w.track,
                    };

                    const entry = visited.getOrPut(new_wire_key) catch oom();
                    if (entry.found_existing) continue;

                    entry.value_ptr.parent = wire_key;
                    entry.value_ptr.edge = edge;
                    queue.insert(0, new_wire_key) catch oom();
                },
            }
        }
    }

    if (path_start == null)
        @panic("Couldn't find a path!");

    var edges: std.ArrayList(Netlist.route.Edge) = .empty;
    if (first_edge) |e|
        edges.append(arena, e) catch oom();

    var key = path_start;
    while (key) |k| {
        const entry = visited.get(k).?;
        edges.append(arena, entry.edge) catch oom();
        r.used_wires.put(r.scratch, k, net_ref) catch oom();
        key = entry.parent;
    }
    r.setRouteEdges(net_ref, edges.items);
}

fn routeNet(r: *Router, net_ref: Net.Ref) void {
    const driver = r.idx.driverOf(net_ref);
    const sinks = r.idx.sinksOf(net_ref);

    var arena = std.heap.ArenaAllocator.init(r.scratch);
    defer arena.deinit();

    for (sinks) |sink| {
        _ = arena.reset(.retain_capacity);
        r.routeSink(net_ref, driver, sink, arena.allocator());
    }
}

pub fn route(nl: *Netlist, scratch: std.mem.Allocator) void {
    var r = Router.init(nl, scratch);
    defer r.deinit();

    for (0..nl.nets.items.len) |i| {
        r.routeNet(@enumFromInt(i));
    }
}

test {
    // refAllDecls would only reach this file's own decls, and the golden tests
    // are not decls of it.
    _ = @import("tests.zig");
}
