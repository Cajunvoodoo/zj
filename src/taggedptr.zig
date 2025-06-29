//! This module provides a tagged pointer, as seen in
//! `https://zig.news/orgold/type-safe-tagged-pointers-with-comptime-ghi`.

pub fn TaggedPackedPtr(
    comptime PtrType: type,
    comptime TagType: type,
) type {
    return packed struct(usize) {
        const BackingIntegerType = backing_integer: {
            var info = @typeInfo(usize);
            info.int.bits -= @bitSizeOf(TagType);
            break :backing_integer @Type(info);
        };

        tag: TagType,
        ptr: BackingIntegerType,

        pub fn from(ptr: ?*PtrType, tag: TagType) @This() {
            return @This(){ .tag = tag, .ptr = @intCast(@intFromPtr(ptr) >> @bitSizeOf(TagType)) };
        }

        pub fn getPtr(self: @This()) ?*PtrType {
            return @ptrFromInt(@as(usize, self.ptr) << @bitSizeOf(TagType));
        }

        pub fn setPtr(self: *@This(), ptr: ?*PtrType) void {
            self.ptr = @intCast(@intFromPtr(ptr) >> @bitSizeOf(TagType));
        }
    };
}
