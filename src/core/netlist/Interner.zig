//! String interner over an arena, generic in the id type it hands out. Ids are
//! assigned in insertion order, which `Netlist.internCellRef` relies on: a name
//! interned in `cell_names` *is* the index into `cells`.

const std = @import("std");
const oom = @import("../common.zig").oom;

pub fn Interner(comptime Id: type) type {
    return struct {
        const Self = @This();

        arena: std.heap.ArenaAllocator,
        strings: std.ArrayListUnmanaged([]const u8),
        map: std.StringHashMapUnmanaged(Id),

        pub fn init(gpa: std.mem.Allocator) Self {
            return Self{
                .arena = .init(gpa),
                .strings = .empty,
                .map = .empty,
            };
        }

        pub fn deinit(s: *Self) void {
            s.strings.deinit(s.arena.child_allocator);
            s.map.deinit(s.arena.child_allocator);
            s.arena.deinit();
        }

        /// The id `str` was interned under, or null if it never was. Unlike
        /// `intern` this never allocates, so it is safe on error paths.
        pub fn find(s: *const Self, str: []const u8) ?Id {
            return s.map.get(str);
        }

        pub fn intern(s: *Self, str: []const u8) Id {
            const e = s.map.getOrPut(s.arena.child_allocator, str) catch oom();
            if (!e.found_existing) {
                const owned = s.arena.allocator().dupe(u8, str) catch oom();
                e.key_ptr.* = owned;
                e.value_ptr.* = @enumFromInt(s.strings.items.len);
                s.strings.append(s.arena.child_allocator, owned) catch oom();
            }
            return e.value_ptr.*;
        }

        pub fn get(s: *const Self, id: Id) []const u8 {
            return s.strings.items[@intFromEnum(id)];
        }
    };
}
