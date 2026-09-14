//! Golden-file tests for the netlist text converters. `examples/*.mnl` are
//! kept in the canonical form `NetlistEmitter` produces, so each file is both
//! the parser's input and the emitter's expected output - there is no second
//! copy of anything. build.zig hands them in as imports, since @embedFile
//! cannot see outside the module root.
//!
//! The parser's own error cases live in `NetlistParser.zig`.

const std = @import("std");

const NetlistParser = @import("NetlistParser.zig");
const NetlistEmitter = @import("NetlistEmitter.zig");

const alloc = std.testing.allocator;

const Example = struct { name: []const u8, text: []const u8 };

const examples = [_]Example{
    .{ .name = "inverter.mnl", .text = @embedFile("inverter_mnl") },
    .{ .name = "toggle.mnl", .text = @embedFile("toggle_mnl") },
    .{ .name = "bram_dsp.mnl", .text = @embedFile("bram_dsp_mnl") },
    .{ .name = "counter.mnl", .text = @embedFile("counter_mnl") },
};

/// Parses text that is expected to be valid. The caller owns the result.
fn parse(name: []const u8, text: []const u8) !NetlistParser.Result {
    const r = NetlistParser.parse(text, alloc);
    if (r.err) |e| {
        std.debug.print("{s}: unexpected parse error: {s}\n", .{ name, e });
        r.deinit(alloc);
        return error.NetlistParseFailed;
    }
    return r;
}

/// Emits a netlist that is expected to be sane: emission never fails, so a
/// warning is the only way it can complain, and a well-formed netlist must not
/// produce one.
fn emit(name: []const u8, r: NetlistParser.Result) !NetlistEmitter.Result {
    const t = NetlistEmitter.emit(r.netlist.?, alloc);
    if (t.warnings.len != 0) {
        for (t.warnings) |w| std.debug.print("{s}: unexpected warning: {s}\n", .{ name, w });
        t.deinit(alloc);
        return error.NetlistEmitWarned;
    }
    return t;
}

test "golden: the examples are the canonical form of themselves" {
    for (examples) |example| {
        const r = try parse(example.name, example.text);
        defer r.deinit(alloc);

        const t = try emit(example.name, r);
        defer t.deinit(alloc);

        try std.testing.expectEqualStrings(example.text, t.text);
    }
}

/// `header ++ "\n" ++ body` is what the emitter writes for a netlist with no
/// passes and no file metadata, so a case can state just the body.
const header = "format 1;\ndevice \"M1/S\";\ndesign \"t\";\n";

test "consolidation: a bus folds as far as one line can spell it" {
    const Case = struct { src: []const u8, want: []const u8 };
    for ([_]Case{
        // Declarations gather by name however they arrive, since a later pass
        // may append to a bus long after it was first declared.
        .{
            .src =
            \\net a[0];
            \\net b;
            \\net a[1];
            \\
            ,
            .want =
            \\net a[0..1];
            \\net b;
            \\
            ,
        },
        // A kind is part of the declaration, so it splits one.
        .{
            .src =
            \\net a[0] : clock;
            \\net a[1];
            \\
            ,
            .want =
            \\net a[0] : clock;
            \\net a[1];
            \\
            ,
        },
        // Ports: a run of nets, a run of constants, and a bit that is neither.
        // ADDR[2..3] cannot join a[0..1], and a[3] cannot join the constants.
        .{
            .src =
            \\net a[0..3];
            \\
            \\cell m : MEM {
            \\    in ADDR[0] = a[0];
            \\    in ADDR[1] = a[1];
            \\    in ADDR[2] = 0;
            \\    in ADDR[3] = 0;
            \\    in ADDR[4] = a[3];
            \\}
            \\
            ,
            .want =
            \\net a[0..3];
            \\
            \\cell m : MEM {
            \\    in ADDR[0..1] = a[0..1];
            \\    in ADDR[2..3] = 0;
            \\    in ADDR[4] = a[3];
            \\}
            \\
            ,
        },
        // One net over several bits is the broadcast spelling, and a group
        // written that way holds more bits than nets - so the bit after it
        // starts a new line rather than extending a[0] into a[0..1].
        .{
            .src =
            \\net a[0..1];
            \\
            \\cell m : MEM {
            \\    in ADDR[0] = a[0];
            \\    in ADDR[1] = a[0];
            \\    in ADDR[2] = a[1];
            \\}
            \\
            ,
            .want =
            \\net a[0..1];
            \\
            \\cell m : MEM {
            \\    in ADDR[0..1] = a[0];
            \\    in ADDR[2] = a[1];
            \\}
            \\
            ,
        },
        // Ranges only ever ascend, so a bit-reversed bus stays apart.
        .{
            .src =
            \\net a[0..1];
            \\
            \\cell m : MEM {
            \\    in ADDR[0] = a[1];
            \\    in ADDR[1] = a[0];
            \\}
            \\
            ,
            .want =
            \\net a[0..1];
            \\
            \\cell m : MEM {
            \\    in ADDR[0] = a[1];
            \\    in ADDR[1] = a[0];
            \\}
            \\
            ,
        },
        // A two-dimensional port folds its rows first and then folds the rows
        // together, which leaves the flat bus feeding it on the other side.
        .{
            .src =
            \\net d[0..3];
            \\
            \\cell m : $mux {
            \\    WIDTH = 2;
            \\    DEPTH = 1;
            \\
            \\    in IN[0][0] = d[0];
            \\    in IN[0][1] = d[1];
            \\    in IN[1][0] = d[2];
            \\    in IN[1][1] = d[3];
            \\}
            \\
            ,
            .want =
            \\net d[0..3];
            \\
            \\cell m : $mux {
            \\    WIDTH = 2;
            \\    DEPTH = 1;
            \\
            \\    in IN[0..1][0..1] = d[0..3];
            \\}
            \\
            ,
        },
        // Row 1 runs backwards, so it stays in single bits - and row 0, having
        // already folded, no longer has a partner its own shape to join.
        .{
            .src =
            \\net d[0..1];
            \\
            \\cell m : $mux {
            \\    WIDTH = 2;
            \\    DEPTH = 1;
            \\
            \\    in IN[0][0] = d[0];
            \\    in IN[0][1] = d[1];
            \\    in IN[1][0] = d[1];
            \\    in IN[1][1] = d[0];
            \\}
            \\
            ,
            .want =
            \\net d[0..1];
            \\
            \\cell m : $mux {
            \\    WIDTH = 2;
            \\    DEPTH = 1;
            \\
            \\    in IN[0][0..1] = d[0..1];
            \\    in IN[1][0] = d[1];
            \\    in IN[1][1] = d[0];
            \\}
            \\
            ,
        },
        // Net blocks are written in the order the declarations were, so a
        // block cannot end up on the far side of the file from its bus.
        .{
            .src =
            \\net a[0];
            \\net b;
            \\net a[1];
            \\
            \\net b { @second 1; }
            \\net a[1] { @first 1; }
            \\
            ,
            .want =
            \\net a[0..1];
            \\net b;
            \\
            \\net a[1] {
            \\    @first 1;
            \\}
            \\
            \\net b {
            \\    @second 1;
            \\}
            \\
            ,
        },
    }) |case| {
        const src = try std.mem.concat(alloc, u8, &.{ header, "\n", case.src });
        defer alloc.free(src);
        const want = try std.mem.concat(alloc, u8, &.{ header, "\n", case.want });
        defer alloc.free(want);

        const r = try parse(case.src, src);
        defer r.deinit(alloc);
        const t = try emit(case.src, r);
        defer t.deinit(alloc);
        try std.testing.expectEqualStrings(want, t.text);

        // The folded spelling has to mean what the expanded one did, or the
        // emitter would be writing a file that reads back as a different
        // netlist. Emitting it again is how that shows up.
        const again = try parse(case.want, t.text);
        defer again.deinit(alloc);
        const again_text = try emit(case.want, again);
        defer again_text.deinit(alloc);
        try std.testing.expectEqualStrings(want, again_text.text);
    }
}

test "a netlist survives a second round trip unchanged" {
    // The golden test only says the emitter reproduces its input. This says
    // the text it wrote parses back to the same netlist, which catches an
    // emitter that drops or renames something both ways consistently.
    for (examples) |example| {
        const first = try parse(example.name, example.text);
        defer first.deinit(alloc);
        const first_text = try emit(example.name, first);
        defer first_text.deinit(alloc);

        const second = try parse(example.name, first_text.text);
        defer second.deinit(alloc);
        const second_text = try emit(example.name, second);
        defer second_text.deinit(alloc);

        try std.testing.expectEqualStrings(first_text.text, second_text.text);
    }
}

