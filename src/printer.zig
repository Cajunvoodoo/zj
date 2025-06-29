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
const ansi = @import("./ansi.zig");
const mkAnsiEscape = ansi.mkAnsiEscape;

const TokenDecoration = enum(u2) {
    SIMILAR,
    MODIFIED,
    NEW, // REVIEW: I don't think we will ever encounter these two with our current strategy.
    REMOVED,
};

pub fn Printer(comptime WriterType: type) type {
    return struct {
        alloc: Allocator,
        /// Where we write our diff to.
        writer: WriterType,
        /// The file bytes.
        fileBytesL: []const u8,
        fileBytesR: []const u8,

        const Self = @This();

        pub fn init(alloc: Allocator, writer: WriterType, fileBytesL: []const u8, fileBytesR: []const u8) Printer(WriterType) {
            return .{
                .alloc = alloc,
                .writer = writer,
                .fileBytesL = fileBytesL,
                .fileBytesR = fileBytesR,
            };
        }

        fn retireToken(self: Self, slice: []const u8, tag: TokenDecoration) !void {
            // Short circuit the retiring logic to avoid two unnecessary `writeAll` calls.
            if (tag == .SIMILAR) {
                try self.writer.writeAll(slice);
                return;
            }
            // Store the diff we found so we can print it out later;

            // std.debug.print("tag: {any}, slice: {s}\n", .{tag, slice});
            const ansiEscape = switch (tag) {
                .MODIFIED => mkAnsiEscape(208), // light orange
                .NEW => mkAnsiEscape(148),      // pale green
                .REMOVED => mkAnsiEscape(160),  // pale red
                else => unreachable,
            };
            try self.writer.writeAll(ansiEscape);
            try self.writer.writeAll(slice);
            try self.writer.writeAll(ansi.ClearStyles);
        }

        /// Helper for `tokenizeStreams`.
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

            var cursorStart: usize = 0;
            // JsonReader will handle .next*()'s error.BufferUnderrun errors.
            while (true) {
                cursorStart = diagL.getByteOffset();
                const lTok = readerL.nextAlloc(alloc, .alloc_if_needed) catch |err| {
                    std.debug.print("readerL, {s}: line {d}\n", .{@errorName(err), readerL.scanner.diagnostics.?.getLine()});
                    return err;
                }; // REVIEW: what the difference between these .alloc* options are
                const rTok = readerR.nextAlloc(alloc, .alloc_if_needed) catch |err| {
                    std.debug.print("readerR, {any}: line {d}\n", .{@errorName(err), readerR.scanner.diagnostics.?.getLine()});
                    return err;
                };
                if (lTok == .end_of_document or rTok == .end_of_document) break;

                const cursorEnd = diagL.getByteOffset();
                // std.debug.print("cursorStart: {d}, cursorEnd: {d}\n", .{cursorStart, cursorEnd});
                const sliceL = self.fileBytesL[cursorStart..cursorEnd];

                const tag: TokenDecoration = if (areTokensEqual(lTok, rTok)) .SIMILAR else .MODIFIED;
                // std.debug.print("cursor: {d}-{d}, tag: {any}, slice: {s}\n", .{cursorStart, cursorEnd, tag, sliceL});
                try self.retireToken(sliceL, tag);
                cursorStart = cursorEnd;
                _ = arena.reset(.retain_capacity);
            }
        }
    };
}

pub fn printer(alloc: Allocator, writer: anytype, fileBytesL: []const u8, fileBytesR: []const u8) Printer(@TypeOf(writer)) {
    return Printer(@TypeOf(writer)).init(alloc, writer, fileBytesL, fileBytesR);
}

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
