// Generic stdlib imports
const std = @import("std");
const testing = std.testing;
const lib = @import("zj_lib");
const Allocator = std.mem.Allocator;
const ArrayListManaged = std.ArrayList;
// JSON stdlib imports
const Reader = std.io.Reader;
const Scanner = std.json.Scanner;
const TokenType = std.json.TokenType;
const Token = std.json.Token;
const AllocWhen = std.json.AllocWhen;
const Diagnostics = std.json.Diagnostics;
const JsonReader = std.json.Reader;
const jsonReader = std.json.reader;

const ansi = @import("./ansi.zig");

/// Classification on how we should print this token.
const TokenDecoration = enum(u2) {
    SIMILAR,
    MODIFIED,
    NEW, // REVIEW: I don't think we will ever encounter these two with our current strategy.
    REMOVED,
};

const Diff = struct {
    /// The bytes that make up the diff, without styling.
    /// FIXME: remove this field, it's redundant.
    bytes: []const u8,
    prefixBytes: []const u8,
    diffBytes: []const u8,
    suffixBytes: []const u8,
    /// The bytes of the alternative file. This is one line, not a whole region
    /// like in `bytes`.
    alternateBytes: []const u8,
    /// The first line number in `bytes`.
    startLine: usize,
    /// The last line number in `bytes`.
    endLine: usize,
    /// The differing line number.
    /// REVIEW: Can tokens span multiple lines?
    diffLine: usize,

    pub fn pprint(self: Diff, writer: anytype) !void {
        // FIXME: This probably looks like trash on a single line. I doubt it works
        // with anything but >= 3 lines. There should be a check for the start/end
        // delta, so we can make a window instead of using line numbers.

        // Count newlines until we find the diffline.
        // We do the work again here to minimize the information we store
        // in the struct;
        var leadingDiffEnd: usize = 0;
        var lineNo = self.startLine;
        while (lineNo < self.diffLine) : ({lineNo += 1;}) {
            if (std.mem.indexOf(u8, self.bytes[leadingDiffEnd..], "\n")) |idx| {
                leadingDiffEnd += idx + 2;
            } else {
                leadingDiffEnd = self.bytes.len;
            }
        }
        // Holy shit what a format string! I hate it!
        try writer.print(
            \\========================
                \\Diff at {d}, showing lines {d}-{d}:
                \\{s}{s}{s}{s}{s}{s}
                ,
            .{self.diffLine, self.startLine, self.endLine,
              self.prefixBytes, self.diffBytes,
              ansi.mkAnsiEscape(88, .BACKGROUND), std.mem.trimRight(u8, self.alternateBytes, ","), ansi.ClearStyles,
              self.suffixBytes,},
              // self.bytes[0..leadingDiffEnd],
              // std.mem.trim(u8, self.alternateBytes, "\n"),
              // self.bytes[trailingDiffStart..]},
        );
    }
};

/// TODO: Find a better name for this struct.
const PrinterFile = struct {
    /// The JSON bytes of this particular file.
    bytes: []const u8,
    diag: Diagnostics,
    /// Stores an array of found diffs. We store slices of the input file with a
    /// window around the diff region, which gives the diff context.
    /// The pointers here are slices into `bytes`.
    // FIXME: use MultiArrayList
    diffs: ArrayListManaged(Diff),
};

/// Configuration options for the output of `Printer`.
const PrinterConfig = struct {
    /// Should we output the file with the diffs?
    outputWholeFile: bool = false,
    /// Should we output the diffs at the end?
    outputDiffs: bool = true,
    /// Number of lines to display before and after the diff found.
    contextWindowSize: usize = 4,
};

pub fn Printer(comptime WriterType: type) type {
    return struct {
        alloc: Allocator,
        /// Where we write our diff to.
        writer: WriterType,
        /// The file bytes.
        fileL: PrinterFile,
        fileR: PrinterFile,
        config: PrinterConfig,

        const Self = @This();

        pub fn init(alloc: Allocator, writer: WriterType, fileBytesL: []const u8, fileBytesR: []const u8, config: PrinterConfig) Printer(WriterType) {
            return .{
                .alloc = alloc,
                .writer = writer,
                .fileL = PrinterFile{
                    .bytes = fileBytesL,
                    .diag = Diagnostics{},
                    .diffs = @FieldType(PrinterFile, "diffs").init(alloc),
                },
                // XXX: We never store anything to diffs here... This seems wrong...
                //      Perhaps if we expected a config option to diff left/right
                //      (i.e., to configure which one is the "original", then we would)
                .fileR = PrinterFile{
                    .bytes = fileBytesR,
                    .diag = Diagnostics{},
                    .diffs = @FieldType(PrinterFile, "diffs").init(alloc),
                },
                .config = config,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.fileL.diffs.items) |diff| {
                self.alloc.free(diff.diffBytes);
            }
            for (self.fileR.diffs.items) |diff| {
                self.alloc.free(diff.diffBytes);
            }
            self.fileL.diffs.deinit();
            self.fileR.diffs.deinit();
        }

        pub fn ppDiffs(self: *Self) !void {
            // FIXME: :UseConfigForOriginalFile Rely on a config option instead. See XXX in `init`.
            for (self.fileL.diffs.items) |diff| {
                try diff.pprint(self.writer);
            }
        }
        // FIXME: We shouldn't call this function when we don't have a diff.
        //        This saves us the function call overhead.
        fn retireToken(self: *Self, tokenSlice: []const u8, tag: TokenDecoration) !void {
            const tagIsSimilar = tag == .SIMILAR;
            var tokenSliceStylized: ?[]const u8 = null;
            // std.debug.print("tag: {any}, slice: {s}\n", .{tag, slice});
            const ansiEscape = switch (tag) {
                .MODIFIED => ansi.mkAnsiEscape(208, .FOREGROUND), // light orange
                .NEW => ansi.mkAnsiEscape(148, .FOREGROUND), // pale green
                .REMOVED => ansi.mkAnsiEscape(160, .FOREGROUND), // pale red
                else => "",
            };
            // XXX: :KeepInSyncForStylizedDiffs
            if (!tagIsSimilar) {
                tokenSliceStylized = try std.fmt.allocPrint(self.alloc, "{s}{s}{s}", .{ansiEscape, tokenSlice, ansi.ClearStyles});
            }

            if (self.config.outputWholeFile) {
                // Short circuit the retiring logic to avoid two unnecessary `writeAll` calls.
                if (tagIsSimilar) {
                    try self.writer.writeAll(tokenSlice);
                    return;
                }
                // Store the diff we found so we can print it out later;

                try self.writer.writeAll(ansiEscape);
                try self.writer.writeAll(tokenSlice);
                try self.writer.writeAll(ansi.ClearStyles);
            }
            // FIXME: :UseConfigForOriginalFile Rely on a config option instead. See XXX in `init`.
            if (self.config.outputDiffs and tag != .SIMILAR) {
                // The offset of where we are as an index into the file.
                const middle: usize = tokenSlice.ptr - self.fileL.bytes.ptr;
                const beforeBytes: []const u8 = self.fileL.bytes[0..middle];
                // const afterBytes: []const u8 = self.fileL.bytes[middle + tokenSlice.len..];
                // const afterBytes: []const u8 = self.fileL.bytes[middle..];
                // We need to go back `self.config.contextWindowSize` bytes back.
                // To do so, we go backwards searching for \n starting at `tokenSlice.ptr`
                // going towards `self.fileL.bytes.ptr`.
                // The default values below are *safe defaults*.
                // FIXME: TODO: use tokenDiffStylized instead. Find the prefix, then the suffix, and allocprint it.
                const diffLineNo = self.fileL.diag.getLine();
                var start: usize = middle;
                var startLineNo: usize = diffLineNo - 1;
                var end: usize = middle + tokenSlice.len;
                var endLineNo: usize = diffLineNo - 1;
                for (0..self.config.contextWindowSize) |_| {
                    // TODO: Support multiple line separators (does zig even support it?)
                    //       The code necessary to support it is below.
                    // if (slice[len - 1] == '\r') {
                    //     slice = slice[0..(len - 1)];
                    // }
                    // Have we reached the start/end for the file buffer?
                    // If so, avoid an unnecessary call.
                    const calcStart: bool = start > 0;
                    const calcEnd: bool = end < self.fileL.bytes.len;
                    // Go backwards for N newlines and store its new start
                    if (calcStart) {
                        if (std.mem.lastIndexOf(u8, beforeBytes[0..start], "\n")) |idx| {
                            start -= start - idx;
                            startLineNo -= 1;
                        } else {
                            start = 0;
                        }
                    }
                    if (calcEnd) {
                        if (std.mem.indexOf(u8, self.fileL.bytes[end..], "\n")) |idx| {
                            end += idx + 1;
                            endLineNo += 1;
                        } else {
                            end = self.fileL.bytes.len;
                        }
                    }
                    if (!(calcStart or calcEnd)) break;
                }
                const diffSlice = self.fileL.bytes[start..end];
                // Get the current line of the right file.
                const fileRCurIdx = self.fileR.diag.getByteOffset();
                const fileRLineStart = std.mem.lastIndexOf(
                    u8,
                    self.fileR.bytes[0..fileRCurIdx],
                    "\n",
                ) orelse fileRCurIdx;
                // This is kinda gross. We ideally could add the curIdx below,
                // but its an optional, so we have to do it after (the next line).
                var fileRLineEnd = std.mem.indexOf(
                    u8,
                    self.fileR.bytes[fileRCurIdx..],
                    "\n",
                ) orelse self.fileR.bytes.len;
                fileRLineEnd += fileRCurIdx;

                const fileRLineSlice: []const u8 = self.fileR.bytes[fileRLineStart..fileRLineEnd];
                //std.debug.print("======================== Diff found in this slice: \n{s}\n============================================= DIFF END\n", .{diffSlice});

                // Substitute the stylized line in if it exists
                var diffBytes: []const u8 = undefined;
                if (tokenSliceStylized) |token| {
                    diffBytes = token;
                } else {
                    // Copy for ownership reasons (we need to free later)
                    diffBytes = try self.alloc.dupe(u8, tokenSlice);
                }
                // if (tokenSliceStylized) |token| {
                //     defer self.alloc.free(token);
                //     // REVIEW: we probably shouldn't be recalculating the diffline.
                //     // NOTE: prefixStart and prefixEnd are slices of the filebytes themselves.
                //     const prefixStart = std.mem.lastIndexOf(u8, beforeBytes, "\n") orelse 0;
                //     const prefixEnd = middle;
                //     const suffixEnd = std.mem.indexOf(u8, self.fileL.bytes[middle], "\n") orelse self.fileL.bytes.len;
                //     const suffixStart = middle + tokenSlice.len;
                //     diffBytes = try std.fmt.allocPrint("{s}{s}{s}", .{prefix})
                // } else {

                // }

                const diff = Diff{
                    .prefixBytes = beforeBytes,
                    .diffBytes = diffBytes,
                    .suffixBytes = self.fileL.bytes[middle+tokenSlice.len..],
                    .bytes = diffSlice,
                    .alternateBytes = fileRLineSlice,
                    .diffLine = diffLineNo,
                    .startLine = startLineNo,
                    .endLine = endLineNo,
                };
                try self.fileL.diffs.append(diff);
            }
        }

        /// Helper for `tokenizeStreams`.
        pub fn tokenizeStreams(self: *Self) !void {
            var arena = std.heap.ArenaAllocator.init(self.alloc);
            const alloc = arena.allocator();
            defer arena.deinit();

            var fileStreamL = std.io.fixedBufferStream(self.fileL.bytes);
            var fileStreamR = std.io.fixedBufferStream(self.fileR.bytes);
            const fileReaderL = fileStreamL.reader();
            const fileReaderR = fileStreamR.reader();

            var readerL = jsonReader(self.alloc, fileReaderL);
            defer readerL.deinit();
            var readerR = jsonReader(self.alloc, fileReaderR);
            defer readerR.deinit();

            // Make sure we have diagnostics in case something goes wrong.
            readerL.enableDiagnostics(&self.fileL.diag);
            readerR.enableDiagnostics(&self.fileR.diag);

            var cursorStart: usize = 0;
            // JsonReader will handle .next*()'s error.BufferUnderrun errors.
            while (true) {
                cursorStart = self.fileL.diag.getByteOffset();
                const lTok = readerL.nextAlloc(alloc, .alloc_if_needed) catch |err| {
                    std.debug.print("readerL, {s}: line {d}\n", .{ @errorName(err), self.fileL.diag.getLine(),});
                    return err;
                }; // REVIEW: what the difference between these .alloc* options are
                const rTok = readerR.nextAlloc(alloc, .alloc_if_needed) catch |err| {
                    std.debug.print("readerR, {any}: line {d}\n", .{ @errorName(err), self.fileR.diag.getLine(),});
                    return err;
                };
                if (lTok == .end_of_document or rTok == .end_of_document) break;

                const cursorEnd = self.fileL.diag.getByteOffset();
                // std.debug.print("cursorStart: {d}, cursorEnd: {d}\n", .{cursorStart, cursorEnd});
                const sliceL = self.fileL.bytes[cursorStart..cursorEnd];

                const tag: TokenDecoration = if (areTokensEqual(lTok, rTok)) .SIMILAR else .MODIFIED;
                // std.debug.print("cursor: {d}-{d}, tag: {any}, slice: {s}\n", .{cursorStart, cursorEnd, tag, sliceL});
                try self.retireToken(sliceL, tag);
                cursorStart = cursorEnd;
                _ = arena.reset(.retain_capacity);
            }
        }
    };
}

pub fn printer(alloc: Allocator, writer: anytype, fileBytesL: []const u8, fileBytesR: []const u8, config: PrinterConfig) Printer(@TypeOf(writer)) {
    return Printer(@TypeOf(writer)).init(alloc, writer, fileBytesL, fileBytesR, config);
}

fn getTokenSize(token: Token) usize {
    switch (token) {
        .allocated_number, .allocated_string => |v| return v.len,
        .number, .partial_number, .string, .partial_string => |v| return v.len,
        .partial_string_escaped_1, .partial_string_escaped_2, .partial_string_escaped_3, .partial_string_escaped_4 => return 1,
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
