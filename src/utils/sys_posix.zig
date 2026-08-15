// SPDX-FileCopyrightText: 2026 Apanazar
//
// SPDX-License-Identifier: LGPL-3.0-or-later

const std = @import("std");
const builtin = @import("builtin");

const is_linux = builtin.os.tag == .linux;
const is_windows = builtin.os.tag == .windows;

pub const FdError = error{
    AddressInUse,
    ConnectionRefused,
    NetworkUnreachable,
    WouldBlock,
    ConnectionReset,
    Unexpected,
};

fn mapErrno(err: std.posix.E) FdError {
    return switch (err) {
        .SUCCESS => unreachable,
        .ADDRINUSE => error.AddressInUse,
        .CONNREFUSED => error.ConnectionRefused,
        .NETUNREACH => error.NetworkUnreachable,
        .AGAIN => error.WouldBlock,
        .INPROGRESS => error.WouldBlock,
        .CONNRESET => error.ConnectionReset,
        else => error.Unexpected,
    };
}

fn check(rc: usize) FdError!void {
    const err = std.posix.errno(rc);
    if (err == .SUCCESS) return;
    return mapErrno(err);
}

fn checkLen(rc: usize) FdError!usize {
    const err = std.posix.errno(rc);
    if (err == .SUCCESS) return rc;
    return mapErrno(err);
}

pub fn sleepNs(ns: u64) void {
    if (ns == 0) return;
    if (comptime is_windows) {
        const ms: u32 = @intCast(@max(ns / std.time.ns_per_ms, 1));
        Sleep(ms);
        return;
    }
    if (comptime is_linux) {
        const req = std.os.linux.timespec{
            .sec = @intCast(ns / std.time.ns_per_s),
            .nsec = @intCast(ns % std.time.ns_per_s),
        };
        _ = std.os.linux.nanosleep(&req, null);
    }
}

extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;

pub fn closeFd(fd: std.posix.fd_t) void {
    if (comptime is_linux) {
        _ = std.os.linux.close(fd);
    }
}

pub fn writeFd(fd: std.posix.fd_t, buf: []const u8) void {
    if (comptime is_linux) {
        _ = std.os.linux.write(fd, buf.ptr, buf.len);
    }
}

pub fn readFd(fd: std.posix.fd_t, buf: []u8) void {
    if (comptime is_linux) {
        _ = std.os.linux.read(fd, buf.ptr, buf.len);
    }
}

pub fn protNone() std.posix.PROT {
    return .{};
}

pub fn protReadWrite() std.posix.PROT {
    return .{ .READ = true, .WRITE = true };
}

pub fn mprotect(mem: []align(std.heap.page_size_min) u8, prot: std.posix.PROT) error{Unexpected}!void {
    if (comptime !is_linux) return;
    const rc = std.os.linux.mprotect(mem.ptr, mem.len, prot);
    const err = std.posix.errno(rc);
    if (err != .SUCCESS) return error.Unexpected;
}

pub fn linuxNegErrno(e: std.os.linux.E) i32 {
    return -@as(i32, @intFromEnum(e));
}

pub fn socket(stream: bool) FdError!std.posix.fd_t {
    if (comptime !is_linux) return error.Unexpected;
    const kind: u32 = if (stream) std.os.linux.SOCK.STREAM else std.os.linux.SOCK.DGRAM;
    const rc = std.os.linux.socket(std.os.linux.AF.INET, kind, 0);
    _ = try checkLen(rc);
    return @intCast(rc);
}

pub fn bind(fd: std.posix.fd_t, addr: *const std.posix.sockaddr, len: std.posix.socklen_t) FdError!void {
    if (comptime !is_linux) return error.Unexpected;
    try check(std.os.linux.bind(fd, addr, len));
}

pub fn listen(fd: std.posix.fd_t, backlog: u32) FdError!void {
    if (comptime !is_linux) return error.Unexpected;
    try check(std.os.linux.listen(fd, backlog));
}

pub fn accept(fd: std.posix.fd_t) FdError!std.posix.fd_t {
    if (comptime !is_linux) return error.Unexpected;
    const rc = std.os.linux.accept(fd, null, null);
    _ = try checkLen(rc);
    return @intCast(rc);
}

pub fn connect(fd: std.posix.fd_t, addr: *const anyopaque, len: std.posix.socklen_t) FdError!void {
    if (comptime !is_linux) return error.Unexpected;
    try check(std.os.linux.connect(fd, addr, len));
}

pub fn recv(fd: std.posix.fd_t, buf: []u8) FdError!usize {
    if (comptime !is_linux) return error.Unexpected;
    return checkLen(std.os.linux.recvfrom(fd, buf.ptr, buf.len, 0, null, null));
}

pub fn send(fd: std.posix.fd_t, buf: []const u8) FdError!usize {
    if (comptime !is_linux) return error.Unexpected;
    return checkLen(std.os.linux.sendto(fd, buf.ptr, buf.len, 0, null, 0));
}

pub fn sendto(
    fd: std.posix.fd_t,
    buf: []const u8,
    addr: *const std.posix.sockaddr,
    len: std.posix.socklen_t,
) FdError!usize {
    if (comptime !is_linux) return error.Unexpected;
    return checkLen(std.os.linux.sendto(fd, buf.ptr, buf.len, 0, addr, len));
}

pub fn getsockname(fd: std.posix.fd_t, addr: *std.posix.sockaddr, len: *std.posix.socklen_t) FdError!void {
    if (comptime !is_linux) return error.Unexpected;
    try check(std.os.linux.getsockname(fd, addr, len));
}

pub fn getSoError(fd: std.posix.fd_t) FdError!i32 {
    if (comptime !is_linux) return error.Unexpected;
    var e: i32 = 0;
    var len: std.posix.socklen_t = @sizeOf(i32);
    try check(std.os.linux.getsockopt(
        fd,
        std.os.linux.SOL.SOCKET,
        std.os.linux.SO.ERROR,
        std.mem.asBytes(&e),
        &len,
    ));
    return e;
}

pub fn setNonblock(fd: std.posix.fd_t) FdError!void {
    if (comptime !is_linux) return error.Unexpected;
    const rc = std.os.linux.fcntl(fd, std.os.linux.F.GETFL, 0);
    _ = try checkLen(rc);
    var flags: std.os.linux.O = @bitCast(@as(u32, @truncate(rc)));
    flags.NONBLOCK = true;
    try check(std.os.linux.fcntl(fd, std.os.linux.F.SETFL, @as(u32, @bitCast(flags))));
}

pub fn pipe() FdError![2]std.posix.fd_t {
    if (comptime is_linux) {
        var fds: [2]std.posix.fd_t = undefined;
        try check(std.os.linux.pipe(&fds));
        return fds;
    }
    return error.Unexpected;
}
