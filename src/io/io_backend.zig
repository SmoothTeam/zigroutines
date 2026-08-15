// SPDX-FileCopyrightText: 2026 Apanazar
//
// SPDX-License-Identifier: LGPL-3.0-or-later

const std = @import("std");
const task_mod = @import("../core/task.zig");
const utils = @import("../utils/utils.zig");

pub const Handle = usize;

pub const Interest = enum {
    read,
    write,
};

pub const BackendError = error{
    NoBackend,
    Unsupported,
    Closed,
    ConnectionReset,
    WouldBlock,
    OutOfMemory,
    Unexpected,
};

pub const Waiter = struct {
    task: *task_mod.Task,
    interest: Interest,
    done: bool = false,
    parked: bool = false,
    err: ?BackendError = null,
};

pub const Backend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        deinit: *const fn (ptr: *anyopaque) void,
        wait: *const fn (ptr: *anyopaque, handle: Handle, interest: Interest) BackendError!void,
        poll: *const fn (ptr: *anyopaque, timeout_ns: u64) BackendError!usize,
        associate: ?*const fn (ptr: *anyopaque, handle: Handle) BackendError!void = null,
        cancel_all: ?*const fn (ptr: *anyopaque) void = null,
        wakeup: ?*const fn (ptr: *anyopaque) void = null,
        async_read: ?*const fn (ptr: *anyopaque, handle: Handle, buf: []u8) BackendError!usize = null,
        async_write: ?*const fn (ptr: *anyopaque, handle: Handle, buf: []const u8) BackendError!usize = null,
        supports_async: *const fn (ptr: *anyopaque) bool = supportsAsyncFalse,
    };

    fn supportsAsyncFalse(_: *anyopaque) bool {
        return false;
    }

    pub fn deinit(self: Backend) void {
        self.vtable.deinit(self.ptr);
    }

    pub fn wait(self: Backend, handle: Handle, interest: Interest) BackendError!void {
        return self.vtable.wait(self.ptr, handle, interest);
    }

    pub fn poll(self: Backend, timeout_ns: u64) BackendError!usize {
        return self.vtable.poll(self.ptr, timeout_ns);
    }

    pub fn associate(self: Backend, handle: Handle) BackendError!void {
        if (self.vtable.associate) |f| return f(self.ptr, handle);
    }

    pub fn cancelAll(self: Backend) void {
        if (self.vtable.cancel_all) |f| f(self.ptr);
    }

    pub fn wakeup(self: Backend) void {
        if (self.vtable.wakeup) |f| f(self.ptr);
    }

    pub fn supportsAsync(self: Backend) bool {
        return self.vtable.supports_async(self.ptr);
    }

    pub fn asyncRead(self: Backend, handle: Handle, buf: []u8) BackendError!usize {
        if (self.vtable.async_read) |f| return f(self.ptr, handle, buf);
        return error.Unsupported;
    }

    pub fn asyncWrite(self: Backend, handle: Handle, buf: []const u8) BackendError!usize {
        if (self.vtable.async_write) |f| return f(self.ptr, handle, buf);
        return error.Unsupported;
    }
};

pub const wakeTask = utils.wakeTask;
