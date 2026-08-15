// SPDX-FileCopyrightText: 2026 Apanazar
//
// SPDX-License-Identifier: LGPL-3.0-or-later

const std = @import("std");
const runtime_mod = @import("../core/runtime.zig");
const task_mod = @import("../core/task.zig");
const channel_mod = @import("../csp/channel.zig");

const Ch = channel_mod.Channel(usize);

fn cAllocator() std.mem.Allocator {
    return std.heap.smp_allocator;
}

pub const zr_runtime = opaque {};
pub const zr_channel = opaque {};

pub export fn zr_version_major() c_uint {
    return 1;
}
pub export fn zr_version_minor() c_uint {
    return 0;
}
pub export fn zr_version_patch() c_uint {
    return 0;
}

pub export fn zr_runtime_create(workers: c_uint) ?*zr_runtime {
    const alloc = cAllocator();
    const rt = alloc.create(runtime_mod.Runtime) catch return null;
    rt.* = runtime_mod.Runtime.init(alloc, .{
        .workers = workers,
        .stack_pool = true,
        .io = .none,
    }) catch {
        alloc.destroy(rt);
        return null;
    };
    return @ptrCast(rt);
}

pub export fn zr_runtime_destroy(handle: ?*zr_runtime) void {
    const h = handle orelse return;
    const rt: *runtime_mod.Runtime = @ptrCast(@alignCast(h));
    const alloc = rt.allocator;
    rt.deinit();
    alloc.destroy(rt);
}

pub export fn zr_runtime_run(handle: ?*zr_runtime) c_int {
    const h = handle orelse return -1;
    const rt: *runtime_mod.Runtime = @ptrCast(@alignCast(h));
    rt.run() catch return -1;
    return 0;
}

pub export fn zr_spawn(
    handle: ?*zr_runtime,
    fn_ptr: ?*const fn (?*anyopaque) callconv(.c) void,
    user: ?*anyopaque,
) c_int {
    const h = handle orelse return -1;
    const cb = fn_ptr orelse return -1;
    const rt: *runtime_mod.Runtime = @ptrCast(@alignCast(h));
    _ = rt.spawn(.{}, struct {
        fn go(f: *const fn (?*anyopaque) callconv(.c) void, u: ?*anyopaque) void {
            f(u);
        }
    }.go, .{ cb, user }) catch return -1;
    return 0;
}

pub export fn zr_yield() void {
    task_mod.yield();
}

pub export fn zr_sleep_ns(ns: u64) void {
    const rt = runtime_mod.currentRuntime() orelse @panic("zigroutines: zr_sleep_ns without runtime");
    rt.sleep(ns);
}

pub export fn zr_channel_create(capacity: usize) ?*zr_channel {
    const ch = Ch.create(cAllocator(), capacity) catch return null;
    return @ptrCast(ch);
}

pub export fn zr_channel_destroy(handle: ?*zr_channel) void {
    const h = handle orelse return;
    const ch: *Ch = @ptrCast(@alignCast(h));
    ch.destroy();
}

pub export fn zr_channel_close(handle: ?*zr_channel) void {
    const h = handle orelse return;
    const ch: *Ch = @ptrCast(@alignCast(h));
    ch.close();
}

pub export fn zr_channel_send(handle: ?*zr_channel, value: usize) c_int {
    const h = handle orelse return -1;
    const ch: *Ch = @ptrCast(@alignCast(h));
    ch.send(value) catch return -1;
    return 0;
}

pub export fn zr_channel_recv(handle: ?*zr_channel, out: ?*usize) c_int {
    const h = handle orelse return -1;
    const dest = out orelse return -1;
    const ch: *Ch = @ptrCast(@alignCast(h));
    dest.* = ch.recv() catch return -1;
    return 0;
}

pub export fn zr_channel_try_send(handle: ?*zr_channel, value: usize) c_int {
    const h = handle orelse return -1;
    const ch: *Ch = @ptrCast(@alignCast(h));
    ch.trySend(value) catch |err| switch (err) {
        error.WouldBlock, error.Full => return 1,
        else => return -1,
    };
    return 0;
}

pub export fn zr_channel_try_recv(handle: ?*zr_channel, out: ?*usize) c_int {
    const h = handle orelse return -1;
    const dest = out orelse return -1;
    const ch: *Ch = @ptrCast(@alignCast(h));
    dest.* = ch.tryRecv() catch |err| switch (err) {
        error.WouldBlock => return 1,
        else => return -1,
    };
    return 0;
}
