//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.

const std = @import("std");
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
    // const fileL = try std.fs.cwd().createFile(
    //     "mnemdb.json",
    //     .{ .read = true, .truncate = false, },
    // );
    // defer fileL.close();
    // const fileR = try std.fs.cwd().createFile(
    //     "mnemdb.json",
    //     .{ .read = true, .truncate = false, },
    // );
    // defer fileR.close();
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    // var brL = std.io.bufferedReader(fileL.reader());
    // var brR = std.io.bufferedReader(fileR.reader());
    // const readerL = brL.reader();
    // const readerR = brR.reader();

    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    const alloc = gpa.allocator();

    // const sliceU8L = try readerL.readAllAlloc(alloc, 10000000000);
    // const sliceU8R = try readerR.readAllAlloc(alloc, 10000000000);
    // _ = sliceU8L;
    // _ = sliceU8R;
    // const objL =
    //     \\ {
    //     \\   "key_obj0": {
    //     \\     "key_obj1": [
    //     \\       "val_obj1_arrelem0",
    //     \\       "val_obj1_arrelem1",
    //     \\       "val_obj1_arrelem2",
    //     \\       "val_obj1_arrelem3"
    //     \\     ]
    //     \\   }
    //     \\ }
    // ;
    // const objR =
    //     \\ {
    //     \\   "key_obj0": {
    //     \\     "key_obj1": [
    //     \\       "val_obj1_arrelem0",
    //     \\       "val_obj1_arrelem1",
    //     \\       "val_obj1_arrelem2",
    //     \\       "val_obj1_arrelem4"
    //     \\     ]
    //     \\   }
    //     \\ }
    // ;
    // var streamL = std.io.fixedBufferStream(objLarge);
    // var streamR = std.io.fixedBufferStream(objLarge);

    var argIter = std.process.ArgIterator.init();
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
    defer std.posix.munmap(@alignCast(fileBytesL));
    const fileBytesR = try mmapFile(filePaths[2]);
    defer std.posix.munmap(@alignCast(fileBytesR));


    var p = printer(alloc, stdout, fileBytesL, fileBytesR);
    try p.tokenizeStreams();
    // var jsonReaderL = jsonReader(alloc, streamL.reader());
    // var diagL = Diagnostics{};
    // var diagR = Diagnostics{};
    // var jsonReaderL = jsonReader(alloc, readerL);
    // defer jsonReaderL.deinit();
    // // var jsonReaderR = jsonReader(alloc, streamR.reader());
    // var jsonReaderR = jsonReader(alloc, readerR);
    // defer jsonReaderR.deinit();
    // // jsonReaderL.scanner.cursor

    // jsonReaderL.enableDiagnostics(&diagL);
    // jsonReaderR.enableDiagnostics(&diagR);
    // try tokenizeStreams(alloc, &jsonReaderL, &jsonReaderR);
    // // Prints to stderr (it's a shortcut based on `std.io.getStdErr()`)
    // std.debug.print("All your {s} are belong to us.\n", .{"codebase"});

    // // stdout is for the actual output of your application, for example if you
    // // are implementing gzip, then only the compressed bytes should be sent to
    // // stdout, not any debugging messages.
    // const stdout_file = std.io.getStdOut().writer();
    // var bw = std.io.bufferedWriter(stdout_file);
    // const stdout = bw.writer();

    // try stdout.print("Run `zig build test` to run the tests.\n", .{});

    try bw.flush(); // Don't forget to flush!
}

fn mmapFile(filepath: []const u8) ![]const u8 {
    var file = try std.fs.cwd().openFile(filepath, .{});
    defer file.close();
    const stat = try file.stat();
    const size = stat.size;
    const fileBytes = try std.posix.mmap(
        null,
        size,
        std.posix.PROT.READ,
        .{ .TYPE = .SHARED },
        file.handle,
        0,
    );
    return fileBytes;
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
