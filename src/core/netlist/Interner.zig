const std = @import("std");
const oom = @import("../common.zig").oom;

pub fn Interner(comptime Id: type) type {
    return struct {
        const Self = @This();

        strings: std.ArrayListUnmanaged([]const u8),
        map: std.StringHashMapUnmanaged(Id),

        pub const empty = Self{
            .strings = .empty,
            .map = .empty,
        };

        pub fn deinit(s: *Self, gpa: std.mem.Allocator) void {
            s.strings.deinit(gpa);
            s.map.deinit(gpa);
        }

        /// The id `str` was interned under, or null if it never was. Unlike
        /// `intern` this never allocates, so it is safe on error paths.
        pub fn find(s: *const Self, str: []const u8) ?Id {
            return s.map.get(str);
        }

        pub fn intern(
            s: *Self,
            gpa: std.mem.Allocator,
            bytes: std.mem.Allocator,
            str: []const u8,
        ) Id {
            const e = s.map.getOrPut(gpa, str) catch oom();
            if (!e.found_existing) {
                const owned = bytes.dupe(u8, str) catch oom();
                e.key_ptr.* = owned;
                e.value_ptr.* = @enumFromInt(s.strings.items.len);
                s.strings.append(gpa, owned) catch oom();
            }
            return e.value_ptr.*;
        }

        pub fn get(s: *const Self, id: Id) []const u8 {
            return s.strings.items[@intFromEnum(id)];
        }
    };
}
