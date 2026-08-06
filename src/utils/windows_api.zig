const std = @import("std");

pub const MEM_COMMIT: u32 = 0x1000;
pub const MEM_RESERVE: u32 = 0x2000;
pub const MEM_RELEASE: u32 = 0x8000;
pub const PAGE_READWRITE: u32 = 0x04;
pub const PAGE_NOACCESS: u32 = 0x01;

pub extern "kernel32" fn VirtualAlloc(
    lpAddress: ?*anyopaque,
    dwSize: usize,
    flAllocationType: u32,
    flProtect: u32,
) callconv(.winapi) ?[*]align(1) u8;

pub extern "kernel32" fn VirtualFree(
    lpAddress: ?*anyopaque,
    dwSize: usize,
    dwFreeType: u32,
) callconv(.winapi) u32;

pub extern "kernel32" fn VirtualProtect(
    lpAddress: ?*anyopaque,
    dwSize: usize,
    flNewProtect: u32,
    lpflOldProtect: *u32,
) callconv(.winapi) u32;

pub extern "kernel32" fn CreateIoCompletionPort(
    FileHandle: ?*anyopaque,
    ExistingCompletionPort: ?*anyopaque,
    CompletionKey: usize,
    NumberOfConcurrentThreads: u32,
) callconv(.winapi) ?*anyopaque;

pub extern "kernel32" fn GetQueuedCompletionStatus(
    CompletionPort: ?*anyopaque,
    lpNumberOfBytesTransferred: *u32,
    lpCompletionKey: *usize,
    lpOverlapped: *?*anyopaque,
    dwMilliseconds: u32,
) callconv(.winapi) u32;

pub extern "kernel32" fn GetQueuedCompletionStatusEx(
    CompletionPort: ?*anyopaque,
    lpCompletionPortEntries: [*]OVERLAPPED_ENTRY,
    ulCount: u32,
    ulNumEntriesRemoved: *u32,
    dwMilliseconds: u32,
    fAlertable: u32,
) callconv(.winapi) u32;

pub extern "kernel32" fn CloseHandle(hObject: ?*anyopaque) callconv(.winapi) u32;

pub extern "kernel32" fn PostQueuedCompletionStatus(
    CompletionPort: ?*anyopaque,
    dwNumberOfBytesTransferred: u32,
    dwCompletionKey: usize,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) u32;

pub const OVERLAPPED = extern struct {
    Internal: usize = 0,
    InternalHigh: usize = 0,
    Offset: u32 = 0,
    OffsetHigh: u32 = 0,
    hEvent: ?*anyopaque = null,
};

pub const OVERLAPPED_ENTRY = extern struct {
    lpCompletionKey: usize = 0,
    lpOverlapped: ?*OVERLAPPED = null,
    Internal: usize = 0,
    dwNumberOfBytesTransferred: u32 = 0,
};

pub const INVALID_HANDLE_VALUE: ?*anyopaque = @ptrFromInt(std.math.maxInt(usize));
