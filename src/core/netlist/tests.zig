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

