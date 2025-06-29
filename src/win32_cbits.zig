const std = @import("std");
const w32 = std.os.windows;
const HANDLE = w32.HANDLE;
const LPCSTR = w32.LPCSTR;
const SECURITY_ATTRIBUTES = w32.SECURITY_ATTRIBUTES;
const BOOL = w32.BOOL;
const LPCVOID = w32.LPCVOID;
const SIZE_T = w32.SIZE_T;

pub extern "kernel32" fn CreateFileMappingA(
    hFile: HANDLE,
    lpFileMappingAttributes: ?*SECURITY_ATTRIBUTES,
    flProtect: u32,
    dwMaximumSizeHigh: u32,
    dwMaximumSizeLow: u32,
    lpName: ?LPCSTR,
) callconv(.winapi) HANDLE;

pub extern "kernel32" fn MapViewOfFile(
    hFileMappingObject: HANDLE,
    dwDesiredAccess: u32,
    dwFileOffsetHigh: u32,
    dwFileOffsetLow: u32,
    dwNumberOfBytesToMap: SIZE_T,

) callconv(.winapi) [*]const u8;

pub extern "kernel32" fn UnmapViewOfFile(
    lpBaseAddress: LPCVOID,
) callconv(.winapi) BOOL;

pub const FILE_MAP_ALL_ACCESS = 983071;
pub const FILE_MAP_COPY = 1;
pub const FILE_MAP_READ = 4;
pub const FILE_MAP_WRITE = 2;
