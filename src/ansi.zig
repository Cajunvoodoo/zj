const std = @import("std");

pub const Stage = enum(u1) {
    FOREGROUND,
    BACKGROUND,
};

pub fn mkAnsiEscape(comptime colorCode: u8, comptime stage: Stage) []const u8 {
    const s = comptime blk: {
        var buf: [20]u8 = undefined;
        break :blk try intToString(colorCode, &buf);
    };
    switch (stage) {
        .FOREGROUND => return "\u{001b}[38;5;" ++ s ++ "m",
        .BACKGROUND => return "\u{001b}[48;5;" ++ s ++ "m",
    }

}

fn intToString(comptime int: u32, comptime buf: []u8) ![]const u8 {
    return try std.fmt.bufPrint(buf, "{}", .{int});
}

pub const ClearStyles = "\u{001b}[0m";
