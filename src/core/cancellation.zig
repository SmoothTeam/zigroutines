// SPDX-FileCopyrightText: 2026 Apanazar
//
// SPDX-License-Identifier: LGPL-3.0-or-later

const std = @import("std");
const task_mod = @import("task.zig");
const sync = @import("synchronization.zig");

pub const CancelToken = struct {
    flag: std.atomic.Value(bool) = .init(false),
    parent: ?*CancelToken = null,
    lock: sync.SpinLock = .{},
    children: std.ArrayListUnmanaged(*CancelToken) = .empty,
    waiters: std.ArrayListUnmanaged(*task_mod.Task) = .empty,
    allocator: ?std.mem.Allocator = null,

    pub fn init() CancelToken {
        return .{};
    }

    pub fn initWithAllocator(allocator: std.mem.Allocator) CancelToken {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *CancelToken) void {
        self.lock.lock();
        if (self.parent) |p| {
            self.lock.unlock();
            p.detachChild(self);
            self.lock.lock();
        }
        self.children.deinit(self.allocator orelse std.heap.page_allocator);
        self.waiters.deinit(self.allocator orelse std.heap.page_allocator);
        self.lock.unlock();
        self.* = undefined;
    }

    pub fn linkChild(self: *CancelToken, child: *CancelToken) void {
        const alloc = self.allocator orelse return;
        child.parent = self;
        child.allocator = alloc;
        self.lock.lock();
        defer self.lock.unlock();
        self.children.append(alloc, child) catch {};
        if (self.flag.load(.acquire)) {
            child.cancel();
        }
    }

    fn detachChild(self: *CancelToken, child: *CancelToken) void {
        self.lock.lock();
        defer self.lock.unlock();
        for (self.children.items, 0..) |c, i| {
            if (c == child) {
                _ = self.children.orderedRemove(i);
                break;
            }
        }
        child.parent = null;
    }

    pub fn cancel(self: *CancelToken) void {
        if (self.flag.swap(true, .acq_rel)) {
            return;
        }

        var wake: std.ArrayListUnmanaged(*task_mod.Task) = .empty;
        defer wake.deinit(self.allocator orelse std.heap.page_allocator);
        var kids: std.ArrayListUnmanaged(*CancelToken) = .empty;
        defer kids.deinit(self.allocator orelse std.heap.page_allocator);

        self.lock.lock();
        const alloc = self.allocator orelse std.heap.page_allocator;
        for (self.waiters.items) |t| {
            wake.append(alloc, t) catch {};
        }
        self.waiters.clearRetainingCapacity();
        for (self.children.items) |c| {
            kids.append(alloc, c) catch {};
        }
        self.lock.unlock();

        for (wake.items) |t| {
            wakeTask(t);
        }
        for (kids.items) |c| {
            c.cancel();
        }
    }

    pub fn isCanceled(self: *const CancelToken) bool {
        return self.flag.load(.acquire);
    }

    pub fn check(self: *const CancelToken) error{Canceled}!void {
        if (self.isCanceled()) return error.Canceled;
    }

    pub fn addWaiter(self: *CancelToken, task: *task_mod.Task) void {
        const alloc = self.allocator orelse return;
        self.lock.lock();
        defer self.lock.unlock();
        if (self.flag.load(.acquire)) {
            return;
        }
        self.waiters.append(alloc, task) catch {};
    }

    pub fn removeWaiter(self: *CancelToken, task: *task_mod.Task) void {
        self.lock.lock();
        defer self.lock.unlock();
        for (self.waiters.items, 0..) |t, i| {
            if (t == task) {
                _ = self.waiters.orderedRemove(i);
                return;
            }
        }
    }
};

fn wakeTask(t: *task_mod.Task) void {
    task_mod.wakeTask(t);
}
