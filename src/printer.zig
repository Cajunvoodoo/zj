const std = @import("std");
const testing = std.testing;
const lib = @import("zj_lib");

const Allocator = std.mem.Allocator;
const Reader = std.io.Reader;
const Scanner = std.json.Scanner;
const TokenType = std.json.TokenType;
const Token = std.json.Token;
const AllocWhen = std.json.AllocWhen;
const Diagnostics = std.json.Diagnostics;
const JsonReader = std.json.Reader;
const jsonReader = std.json.reader;
const TaggedPackedPtr = @import("./taggedptr.zig").TaggedPackedPtr;
const mkAnsiEscape = @import("./ansi.zig").mkAnsiEscape;

const TokenDecoration = enum(u2) {
    SIMILAR,
    MODIFIED,
    NEW, // REVIEW: I don't think we will ever encounter these two with our current strategy.
    REMOVED,
};

/// A decorated token contains a Json Token and a TokenDecoration.
const DecoratedToken = TaggedPackedPtr(Token, TokenDecoration);

/// Architecture:
///
/// We are given some slice of json input (likely an mmap'd file), which we
/// scan through a `Scanner`. When we find a diff, we push a partial diff start
/// to a stack.
///
/// Whenever we print a value, we store the current cursor to continue from for
/// the next print.
pub fn Printer(comptime WriterType: type) type {
    return struct {
        alloc: Allocator,
        /// Where we write our diff to.
        writer: WriterType,
        /// The file bytes
        fileBytesL: []const u8,
        fileBytesR: []const u8,
        /// How deep we are in the strucutre, for pretty-printing
        indent: usize = 0,
        const Self = @This();

        pub fn init(alloc: Allocator, writer: WriterType, fileBytesL: []const u8, fileBytesR: []const u8) Printer(WriterType) {
            return .{
                .alloc = alloc,
                .writer = writer,
                .fileBytesL = fileBytesL,
                .fileBytesR = fileBytesR,
            };
        }

        // REVIEW: Should these functions take a reference to self, or just self?
        //         Check the codegen at some point.
        // inline fn beginTokRetire(self: Self, tag: TokenDecoration) !void {
        //     if (tag == .SIMILAR) return;

        //     const ansiEscape = switch (tag) {
        //         .MODIFIED => mkAnsiEscape(208), // light orange
        //         .NEW => mkAnsiEscape(148),      // pale green
        //         .REMOVED => mkAnsiEscape(160),  // pale red
        //         else => unreachable,
        //     };
        //     try self.writer.writeAll(ansiEscape);
        // }

        // inline fn endTokRetire(self: *Self) !void {
        //     _ = try self.writer.write("\u{001b}[0m");
        // }

        fn retireToken(self: Self, slice: []const u8, tag: TokenDecoration) !void {
            if (tag == .SIMILAR) {
                try self.writer.writeAll(slice);
                return;
            }

            // std.debug.print("tag: {any}, slice: {s}\n", .{tag, slice});
            const ansiEscape = switch (tag) {
                .MODIFIED => mkAnsiEscape(208), // light orange
                .NEW => mkAnsiEscape(148),      // pale green
                .REMOVED => mkAnsiEscape(160),  // pale red
                else => unreachable,
            };
            const ansiClear = "\u{001b}[0m";
            // std.debug.print("{s}foo\n", .{ansiEscape});
            // _ = ansiEscape;
            // _ = ansiClear;
            std.debug.print("\n\nDIFF HERE:", .{});
            try self.writer.writeAll(ansiEscape);
            try self.writer.writeAll(slice);
            try self.writer.writeAll(ansiClear);
            // try self.writer.print("{s}{s}", .{ansiClear, slice});
        }

        /// Helper for `tokenizeStreams`.
        fn getCursorPos(self: Self, firstBuf: bool, fileStream: anytype, reader: anytype) usize {
            _ = firstBuf;
            const len = self.fileBytesL.len;
            const fsOffset = fileStream.pos + reader.scanner.cursor;
            if (len == fileStream.pos) {
                // std.debug.print("\n\n\n\n\n\n", .{});
                // const upperBound = @min(std.heap.pageSize(), len);
                return len;// - reader.scanner.cursor;
            }
            return @min(len, fsOffset);
        }

        pub fn tokenizeStreams(self: *Self) !void {
            var arena = std.heap.ArenaAllocator.init(self.alloc);
            const alloc = arena.allocator();
            defer arena.deinit();

            var fileStreamL = std.io.fixedBufferStream(self.fileBytesL);
            var fileStreamR = std.io.fixedBufferStream(self.fileBytesR);
            const fileReaderL = fileStreamL.reader();
            const fileReaderR = fileStreamR.reader();

            var readerL = jsonReader(self.alloc, fileReaderL);
            defer readerL.deinit();
            var readerR = jsonReader(self.alloc, fileReaderR);
            defer readerR.deinit();

            // Make sure we have diagnostics in case something goes wrong.
            var diagL = Diagnostics{};
            var diagR = Diagnostics{};
            readerL.enableDiagnostics(&diagL);
            readerR.enableDiagnostics(&diagR);

            var firstBuf = true;
            var cursorStart: usize = 0;
            // JsonReader will handle .next*()'s error.BufferUnderrun errors.
            while (true) {
                // cursorStart = self.getCursorPos(firstBuf, fileStreamL, readerL);
                cursorStart = diagL.getByteOffset();
                // try self.writer.print("currentByteOffset: {d}\n", .{diagL.getByteOffset()});
                const lTok = readerL.nextAlloc(alloc, .alloc_if_needed) catch |err| {
                    std.debug.print("readerL, {s}: line {d}\n", .{@errorName(err), readerL.scanner.diagnostics.?.getLine()});
                    return err;
                }; // REVIEW: what the difference between these .alloc* options are
                const rTok = readerR.nextAlloc(alloc, .alloc_if_needed) catch |err| {
                    std.debug.print("readerR, {any}: line {d}\n", .{@errorName(err), readerR.scanner.diagnostics.?.getLine()});
                    return err;
                };
                if (lTok == .end_of_document or rTok == .end_of_document) break;

                // const cursorEnd = self.getCursorPos(firstBuf, fileStreamL, readerL);
                const cursorEnd = diagL.getByteOffset();
                firstBuf = false;
                // std.debug.print("cursorStart: {d}, cursorEnd: {d}\n", .{cursorStart, cursorEnd});
                const sliceL = self.fileBytesL[cursorStart..cursorEnd];

                const tag: TokenDecoration = if (areTokensEqual(lTok, rTok)) .SIMILAR else .MODIFIED;
                // std.debug.print("cursor: {d}-{d}, tag: {any}, slice: {s}\n", .{cursorStart, cursorEnd, tag, sliceL});
                try self.retireToken(sliceL, tag);
                // try self.beginTokRetire(tag);
                // try self.writer.print("{s}", .{sliceL});
                // std.debug.print("{s}", .{sliceL});
                // try self.endTokRetire();
                // std.debug.print("Token:\n  lTok: {any}\n  rTok: {any}\n", .{lTok, rTok});

                // std.debug.print("TOKENS ARE SIMILAR? {any}\n", .{areTokensEqual(lTok, rTok)});

                // var decoratedToken: DecoratedToken = DecoratedToken.from(&lTok, tag);
                // try self.retireToken(&decoratedToken);

                // std.debug.print("tokType: {any}, tokSize: {d}, cursorStart: {d}, cursorEnd: {d}\n", .{std.meta.activeTag(lTok), getTokenSize(lTok), cursorStart, cursorEnd});
                cursorStart = cursorEnd;
                _ = arena.reset(.retain_capacity);
            }

            // try self.writer.flush();
        }
    };
}

pub fn printer(alloc: Allocator, writer: anytype, fileBytesL: []const u8, fileBytesR: []const u8) Printer(@TypeOf(writer)) {
    return Printer(@TypeOf(writer)).init(alloc, writer, fileBytesL, fileBytesR);
}

const View = struct {
    curr: usize,
    str: []const u8,
};

fn getTokenSize(token: Token) usize {
    switch (token) {
        .allocated_number,
        .allocated_string => |v| return v.len,
        .number,
        .partial_number,
        .string,
        .partial_string => |v| return v.len,
        .partial_string_escaped_1,
        .partial_string_escaped_2,
        .partial_string_escaped_3,
        .partial_string_escaped_4 => return 1,
        else => return 0,
    }
}

fn areTokensEqual(lTok: Token, rTok: Token) bool {
    const areTagsEqual = std.meta.activeTag(lTok) == std.meta.activeTag(rTok);
    if (!areTagsEqual) return false;
    switch (lTok) {
        .number => |lval| {
            return std.mem.eql(u8, lval, rTok.number); // TODO actually check the other token type?
        },
        .allocated_number => |lval| {
            return std.mem.eql(u8, lval, rTok.allocated_number); // TODO actually check the other token type?
        },
        .partial_number => |lval| {
            return std.mem.eql(u8, lval, rTok.partial_number); // TODO actually check the other token type?
        },
        .string => |lval| {
            return std.mem.eql(u8, lval, rTok.string);
        },
        .allocated_string => |lval| {
            return std.mem.eql(u8, lval, rTok.allocated_string);
        },
        .partial_string => |lval| {
            return std.mem.eql(u8, lval, rTok.partial_string);
        },
        .partial_string_escaped_1 => |lval| {
            // REVIEW: should these use &?
            return std.mem.eql(u8, &lval, &rTok.partial_string_escaped_1);
        },
        .partial_string_escaped_2 => |lval| {
            return std.mem.eql(u8, &lval, &rTok.partial_string_escaped_2);
        },
        .partial_string_escaped_3 => |lval| {
            return std.mem.eql(u8, &lval, &rTok.partial_string_escaped_3);
        },
        .partial_string_escaped_4 => |lval| {
            return std.mem.eql(u8, &lval, &rTok.partial_string_escaped_4);
        },

        .object_begin,
        .object_end,
        .array_begin,
        .array_end,
        .true,
        .false,
        .null,
        .end_of_document,
        => return areTagsEqual,
    }
}
