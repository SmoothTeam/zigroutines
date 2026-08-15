// SPDX-FileCopyrightText: 2026 Apanazar
//
// SPDX-License-Identifier: LGPL-3.0-or-later

const std = @import("std");
const builtin = @import("builtin");
const sys_posix = @import("sys_posix.zig");

pub const is_windows = builtin.os.tag == .windows;

const is_linux = builtin.os.tag == .linux;
const is_darwin = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos => true,
    else => false,
};

pub const WorkerWake = struct {
    word: std.atomic.Value(u32) = .init(0),
    waiting: std.atomic.Value(u32) = .init(0),

    pub fn init() WorkerWake {
        return .{};
    }

    pub fn deinit(self: *WorkerWake) void {
        self.* = undefined;
    }

    pub fn wait(self: *WorkerWake, timeout_ns: ?u64) void {
        _ = self.waiting.fetchAdd(1, .acq_rel);
        defer _ = self.waiting.fetchSub(1, .acq_rel);

        if (self.word.swap(0, .acq_rel) != 0) return;
        osWait(&self.word, 0, timeout_ns);
        _ = self.word.swap(0, .acq_rel);
    }

    pub fn signal(self: *WorkerWake) void {
        self.word.store(1, .release);
        osWake(&self.word, 1);
    }

    pub fn signalAll(self: *WorkerWake) void {
        self.word.store(1, .release);
        osWake(&self.word, std.math.maxInt(u32));
    }
};

fn osWait(word: *std.atomic.Value(u32), expected: u32, timeout_ns: ?u64) void {
    if (comptime is_windows) {
        const ntdll = std.os.windows.ntdll;
        var cmp = expected;
        if (timeout_ns) |ns| {
            const units: i64 = @intCast(@max(ns / 100, 1));
            var timeout: i64 = -units;
            _ = ntdll.RtlWaitOnAddress(@ptrCast(&word.raw), @ptrCast(&cmp), @sizeOf(u32), &timeout);
        } else {
            _ = ntdll.RtlWaitOnAddress(@ptrCast(&word.raw), @ptrCast(&cmp), @sizeOf(u32), null);
        }
        return;
    }
    if (comptime is_linux) {
        var ts: std.os.linux.timespec = undefined;
        const ts_ptr: ?*const std.os.linux.timespec = if (timeout_ns) |ns| blk: {
            ts = .{
                .sec = @intCast(ns / std.time.ns_per_s),
                .nsec = @intCast(ns % std.time.ns_per_s),
            };
            break :blk &ts;
        } else null;
        _ = std.os.linux.futex_4arg(
            @ptrCast(&word.raw),
            .{ .cmd = .WAIT, .private = true },
            expected,
            ts_ptr,
        );
        return;
    }
    if (comptime is_darwin) {
        const us: u32 = if (timeout_ns) |ns| blk: {
            const u = ns / std.time.ns_per_us;
            if (u == 0) break :blk 1;
            break :blk @intCast(@min(u, std.math.maxInt(u32)));
        } else 0;
        _ = darwin.ulock_wait(darwin.UL_COMPARE_AND_WAIT, @ptrCast(&word.raw), expected, us);
        return;
    }
    fallbackWait(timeout_ns);
}

fn osWake(word: *std.atomic.Value(u32), count: u32) void {
    if (comptime is_windows) {
        const ntdll = std.os.windows.ntdll;
        if (count <= 1) {
            ntdll.RtlWakeAddressSingle(@ptrCast(&word.raw));
        } else {
            ntdll.RtlWakeAddressAll(@ptrCast(&word.raw));
        }
        return;
    }
    if (comptime is_linux) {
        _ = std.os.linux.futex_3arg(
            @ptrCast(&word.raw),
            .{ .cmd = .WAKE, .private = true },
            count,
        );
        return;
    }
    if (comptime is_darwin) {
        const op: u32 = if (count <= 1)
            darwin.UL_COMPARE_AND_WAIT
        else
            darwin.UL_COMPARE_AND_WAIT | darwin.ULF_WAKE_ALL;
        _ = darwin.ulock_wake(op, @ptrCast(&word.raw), 0);
        return;
    }
}

fn fallbackWait(timeout_ns: ?u64) void {
    const budget: u64 = timeout_ns orelse 1 * std.time.ns_per_ms;
    if (budget == 0) return;
    sys_posix.sleepNs(budget);
}

const darwin = struct {
    const UL_COMPARE_AND_WAIT: u32 = 1;
    const ULF_WAKE_ALL: u32 = 0x00000100;

    extern "c" fn __ulock_wait(op: u32, addr: *const anyopaque, val: u64, timeout_us: u32) callconv(.c) i32;
    extern "c" fn __ulock_wake(op: u32, addr: *const anyopaque, val: u64) callconv(.c) i32;

    fn ulock_wait(op: u32, addr: *const anyopaque, val: u32, timeout_us: u32) i32 {
        return __ulock_wait(op, addr, val, timeout_us);
    }

    fn ulock_wake(op: u32, addr: *const anyopaque, val: u64) i32 {
        return __ulock_wake(op, addr, val);
    }
};
