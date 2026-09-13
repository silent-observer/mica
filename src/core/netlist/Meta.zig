//! One `@tag data;` annotation, which the tools never interpret - the format
//! requires it to pass through unaffected, so only the tag and the raw text are
//! kept. Entries cannot use the contiguous-span trick the ports and route edges
//! do, because a later block for one owner lands after other owners' entries;
//! `Netlist.metadata` is one flat list in file order, threaded by `next`.

const std = @import("std");

pub const Meta = @This();

/// Interned `@tag` text, without the `@`.
tag: TagId,
/// The raw text between the tag and the `;`, verbatim apart from trimmed
/// surrounding whitespace.
data: []const u8,
next: Ref = .none,

pub const TagId = enum(u32) { _ };
pub const Ref = enum(u32) {
    none = 0xFFFF_FFFF,
    _, // A metadata index
};

/// Head and tail of one owner's list
pub const List = struct {
    head: Ref = .none,
    tail: Ref = .none,
};
