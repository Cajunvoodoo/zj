//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const lib = @import("zj_lib");

const Allocator = std.mem.Allocator;
const Reader = std.io.Reader;

const Scanner = std.json.Scanner;
const Token = std.json.Token;
const AllocWhen = std.json.AllocWhen;
const Diagnostics = std.json.Diagnostics;
const JsonReader = std.json.Reader;
const jsonReader = std.json.reader;

const native_os = builtin.target.os.tag;
const TaggedPackedPtr = @import("./taggedptr.zig").TaggedPackedPtr;

// REVIEW: My idea is to "discharge" tokens when we finish parsing them. If they
// are similar/don't differ, we pass an argument saying it is a normal, unchanged
// token. Otherwise, we pass an argument saying it is either Changed, New, or Removed.

/// Check if tokens are equal. This is mostly lifted from the zig stdlib test suite.

const printerMod = @import("printer.zig");
const printer = printerMod.printer;

// TODO remove/implement in a streaming fashion
pub fn tokenizeStreams(allocator: Allocator, readerL: anytype, readerR: anytype) !void {
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    var p = printer(allocator, stdout, readerL, readerR);
    try p.tokenizeStreams();
    try bw.flush();
}

pub fn main() !void {
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const alloc = gpa.allocator();

    // CLI Arguments //////////////////////////////////////////////////////////
    // NOTE: We can't use `std.process.ArgIterator` because of windows support.
    //       We could have a conditional if, but meh.
    var argIter = try std.process.argsWithAllocator(alloc);
    defer argIter.deinit();
    var filePaths: [3][]const u8 = undefined;
    var filePathIdx: u8 = 0;
    while (argIter.next()) |arg| : (filePathIdx += 1) {
        filePaths[filePathIdx] = std.mem.sliceTo(arg, 0);
    }
    // Arg count check.
    if (filePathIdx > 3 or filePathIdx < 3) {
        std.debug.print("Usage: {s} <original.json> <alternative.json>\n", .{filePaths[0]});
        std.process.exit(1);
    }

    const fileBytesL = try mmapFile(filePaths[1]);
    // defer std.posix.munmap(@alignCast(fileBytesL));
    const fileBytesR = try mmapFile(filePaths[2]);
    // defer std.posix.munmap(@alignCast(fileBytesR));

    var p = printer(alloc, stdout, fileBytesL, fileBytesR, .{});
    try p.tokenizeStreams();
    try p.ppDiffs();
    p.deinit();

    try bw.flush();
    try unmapFile(fileBytesL);
    try unmapFile(fileBytesR);
}

fn mmapFile(filepath: []const u8) ![]const u8 {
    var file = try std.fs.cwd().openFile(filepath, .{});
    defer file.close();
    const stat = try file.stat();
    const size: usize = @intCast(stat.size);
    const fileBytes = switch (native_os) {
        .windows => bytes: {
            const memoryapi = @import("win32_cbits.zig");
            const w32 = std.os.windows;
            const mappingHandle = memoryapi.CreateFileMappingA(
                file.handle,
                null,
                w32.PAGE_READONLY,
                0,
                0,
                null,
            );
            if (@intFromPtr(mappingHandle) == 0) {
                switch (w32.GetLastError()) {
                    else => |err| return w32.unexpectedError(err),
                }
            }

            const fileBytes = memoryapi.MapViewOfFile(
                mappingHandle,
                memoryapi.FILE_MAP_READ,
                0,
                0,
                size
            );
            if (@intFromPtr(fileBytes) == 0) {
                switch (w32.GetLastError()) {
                    else => |err| return w32.unexpectedError(err),
                }
            }
            break :bytes fileBytes[0..size];
        },
        else => bytes: {
            const fileBytes = try std.posix.mmap(
                null,
                size,
                std.posix.PROT.READ,
                .{ .TYPE = .SHARED },
                file.handle,
                0,
            );
            break :bytes fileBytes;
        },
    };
    return fileBytes;
}

fn unmapFile(fileBytes: []const u8) !void {
    switch (native_os) {
        .windows => {
            const memoryapi = @import("win32_cbits.zig");
            const w32 = std.os.windows;
            if (memoryapi.UnmapViewOfFile(fileBytes.ptr) == 0) {
                switch (w32.GetLastError()) {
                    else => |err| return w32.unexpectedError(err),
                }
            }
        },
        else => std.posix.munmap(@alignCast(fileBytes)),
    }
}

///////////////////////////////////////////////////////////////////////////////
//                            TESTING AND HELPERS                            //
///////////////////////////////////////////////////////////////////////////////

// TODO, FIXME remove/implement
fn compareDocuments(readerL: anytype, readerR: anytype) bool {
    tokenizeStreams(std.testing.allocator, readerL, readerR) catch return false;
    return true;
}

fn testJsonSimilar(objL: []const u8, objR: []const u8) !void {
    var streamL = std.io.fixedBufferStream(objL);
    var streamR = std.io.fixedBufferStream(objR);

    var jsonReaderL = jsonReader(std.testing.allocator, streamL.reader());
    defer jsonReaderL.deinit();
    var jsonReaderR = jsonReader(std.testing.allocator, streamR.reader());
    defer jsonReaderR.deinit();

    try testing.expect(compareDocuments(&jsonReaderL, &jsonReaderR));
}

fn testJsonDissimilar(objL: []const u8, objR: []const u8) !void {
    var streamL = std.io.fixedBufferStream(objL);
    var streamR = std.io.fixedBufferStream(objR);

    var jsonReaderL = jsonReader(std.testing.allocator, streamL.reader());
    defer jsonReaderL.deinit();
    var jsonReaderR = jsonReader(std.testing.allocator, streamR.reader());
    defer jsonReaderR.deinit();

    try testing.expect(!compareDocuments(&jsonReaderL, &jsonReaderR));
}

test "compare similar objects (trivial)" {
    const obj =
        \\ {}
    ;
    try testJsonSimilar(obj, obj);
}

test "compare similar objects (non-trivial, nestedKeyArr)" {
    const obj =
        \\ {
        \\   "key_obj0": {
        \\     "key_obj1": [
        \\       "val_obj1_arrelem0",
        \\       "val_obj1_arrelem1",
        \\       "val_obj1_arrelem2",
        \\       "val_obj1_arrelem3"
        \\     ]
        \\   }
        \\ }
    ;
    try testJsonSimilar(obj, obj);
}

test "compare dissimilar objects (non-trivial, nestedKeyArr)" {
    const objL =
        \\ {
        \\   "key_obj0": {
        \\     "key_obj1": [
        \\       "val_obj1_arrelem0",
        \\       "val_obj1_arrelem1",
        \\       "val_obj1_arrelem2",
        \\       "val_obj1_arrelem3"
        \\     ]
        \\   }
        \\ }
    ;
    const objR =
        \\ {
        \\   "key_obj0": {
        \\     "key_obj1": [
        \\       "val_obj1_arrelem0",
        \\       "val_obj1_arrelem1",
        \\       "val_obj1_arrelem2",
        \\       "val_obj1_arrelem4"
        \\     ]
        \\   }
        \\ }
    ;
    try testJsonDissimilar(objL, objR);
}
