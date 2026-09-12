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
