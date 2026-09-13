//! Parsing of `@tag data;`. The data is opaque, so it is scanned raw to the
//! first `;` outside a string: `//` inside metadata is *not* a comment, and a
//! missing `;` swallows the rest of the file. Callers must try this before
//! their own `parseWord`/`check('}')`, or an `@` aborts the surrounding loop.

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
