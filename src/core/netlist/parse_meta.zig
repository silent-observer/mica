const std = @import("std");

const NetlistParser = @import("NetlistParser.zig");
const Netlist = @import("Netlist.zig");
const Meta = @import("Meta.zig");

pub fn checkMetadata(p: *NetlistParser, owner: Netlist.Owner) !bool {
    if (!p.p.check('@')) return false;

    try p.p.expect('@');
    if (p.p.eof() or !std.ascii.isAlphabetic(p.p.peek(0).?))
        try p.p.err("Metadata tag must start with a letter and follow '@' directly", .{});
    const tag = try p.p.parseWord();

    const data_start = p.p.pos;
    while (!p.p.eof()) {
        if (p.p.peek(0) == ';') break;

        if (p.p.peek(0) == '"')
            _ = try p.p.parseString()
        else
            p.p.pos += 1;
    }
    const data_end = p.p.pos;
    try p.p.expect(';');

    const data = std.mem.trim(
        u8,
        p.p.input[data_start..data_end],
        " \t\r\n",
    );
    p.nl().addMetadata(owner, tag, data);

    return true;
}
