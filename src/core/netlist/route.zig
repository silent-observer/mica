const common = @import("../common.zig");

pub const Edge = union(enum) {
    switchbox: struct { at: common.SwitchCoords, dst: common.SwitchWire, src: u4 },
    logic: struct { at: common.TileCoords, input: common.LogicInput, src: u5 },
    bram: struct { at: common.TileCoords, input: common.BramInput, src: u5 },
    dsp: struct { at: common.TileCoords, input: common.DspInput, src: u5 },
    io: struct { at: common.TileCoords, input: common.IoInput, src: u5 },

    comptime {
        // NetlistParser builds these with @unionInit(RouteEdge, @tagName(t)),
        // so the tile variants have to stay named after the tile types.
        for (common.TileType.configurable) |t| {
            if (!@hasField(Edge, @tagName(t)))
                @compileError("RouteEdge has no variant for tile type " ++ @tagName(t));
        }
    }
};
