// SPDX-FileCopyrightText: 2026 Apanazar
//
// SPDX-License-Identifier: LGPL-3.0-or-later

const std = @import("std");
const builtin = @import("builtin");
const be = @import("io_backend.zig");
const reactor_mod = @import("poll_reactor.zig");
const task_mod = @import("../core/task.zig");
const sync = @import("../core/synchronization.zig");
const sys_posix = @import("../utils/sys_posix.zig");

const is_linux = builtin.os.tag == .linux;

const LinuxIoUring = if (is_linux) std.os.linux.IoUring else struct {};

const UringReq = struct {
    task: *task_mod.Task,
    done: bool = false,
    parked: bool = false,
    released: bool = false,
    cqe_seen: bool = false,
    res: i32 = 0,
    err: ?be.BackendError = null,
};

pub const IoUringBackend = struct {
    allocator: std.mem.Allocator,
    reactor: *reactor_mod.Reactor,
    lock: sync.SpinLock = .{},
    ring: if (is_linux) ?LinuxIoUring else void = if (is_linux) null else {},
    uring_active: bool = false,
    pending: if (is_linux) std.ArrayListUnmanaged(*UringReq) else void =
        if (is_linux) .empty else {},
    free_reqs: if (is_linux) std.ArrayListUnmanaged(*UringReq) else void =
        if (is_linux) .empty else {},

    pub fn create(allocator: std.mem.Allocator) !*IoUringBackend {
        const self = try allocator.create(IoUringBackend);
        errdefer allocator.destroy(self);
        const r = try reactor_mod.Reactor.create(allocator);
        errdefer r.destroy();

        self.* = .{
            .allocator = allocator,
            .reactor = r,
        };

        if (comptime is_linux) {
            self.pending = .empty;
            self.free_reqs = .empty;
            self.trySetupUring();
        }
        return self;
    }

    fn trySetupUring(self: *IoUringBackend) void {
        if (comptime !is_linux) return;
        const ring = LinuxIoUring.init(256, 0) catch {
            self.uring_active = false;
            self.ring = null;
            return;
        };
        self.ring = ring;
        self.uring_active = true;
    }

    pub fn destroy(self: *IoUringBackend) void {
        self.cancelAll();
        if (comptime is_linux) {
            var spins: u32 = 0;
            while (spins < 8) : (spins += 1) {
                if ((self.harvestCqes(0) catch 0) == 0 and self.pending.items.len == 0) break;
            }
            for (self.free_reqs.items) |r| self.allocator.destroy(r);
            self.free_reqs.deinit(self.allocator);
            for (self.pending.items) |r| self.allocator.destroy(r);
            self.pending.deinit(self.allocator);
            if (self.ring) |*ring| {
                ring.deinit();
                self.ring = null;
            }
        }
        self.reactor.destroy();
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn backend(self: *IoUringBackend) be.Backend {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    pub fn isUringActive(self: *const IoUringBackend) bool {
        return self.uring_active;
    }

    const vtable = be.Backend.VTable{
        .deinit = deinitV,
        .wait = waitV,
        .poll = pollV,
        .associate = null,
        .cancel_all = cancelAllV,
        .wakeup = wakeupV,
        .async_read = if (is_linux) asyncReadV else null,
        .async_write = if (is_linux) asyncWriteV else null,
        .supports_async = supportsAsyncV,
    };

    fn cancelAllV(ptr: *anyopaque) void {
        const self: *IoUringBackend = @ptrCast(@alignCast(ptr));
        self.cancelAll();
    }

    pub fn cancelAll(self: *IoUringBackend) void {
        self.reactor.cancelAll();
        if (comptime !is_linux) return;

        var to_wake: std.ArrayListUnmanaged(*task_mod.Task) = .empty;
        defer to_wake.deinit(self.allocator);

        self.lock.lock();
        if (self.ring) |*ring| {
            for (self.pending.items) |req| {
                _ = ring.cancel(0, @intFromPtr(req), 0) catch {};
            }
            _ = ring.submit() catch {};
        }
        for (self.pending.items) |req| {
            if (!req.done) {
                req.err = error.Closed;
                req.done = true;
                req.res = sys_posix.linuxNegErrno(.CANCELED);
                if (req.parked) to_wake.append(self.allocator, req.task) catch {};
            }
        }
        self.lock.unlock();
        self.reactor.poke();
        for (to_wake.items) |t| be.wakeTask(t);
    }

    fn wakeupV(ptr: *anyopaque) void {
        const self: *IoUringBackend = @ptrCast(@alignCast(ptr));
        self.reactor.poke();
    }

    fn deinitV(ptr: *anyopaque) void {
        const self: *IoUringBackend = @ptrCast(@alignCast(ptr));
        self.destroy();
    }

    fn waitV(ptr: *anyopaque, handle: be.Handle, interest: be.Interest) be.BackendError!void {
        const self: *IoUringBackend = @ptrCast(@alignCast(ptr));
        return self.reactor.asBackend().wait(handle, interest);
    }

    fn pollV(ptr: *anyopaque, timeout_ns: u64) be.BackendError!usize {
        const self: *IoUringBackend = @ptrCast(@alignCast(ptr));
        var woken: usize = 0;
        if (comptime is_linux) {
            if (self.uring_active) {
                woken += self.harvestCqes(0) catch 0;
            }
            const need_ready = self.reactor.hasWaiters();
            if (need_ready or woken == 0) {
                const t: u64 = if (woken > 0) 0 else timeout_ns;
                woken += self.reactor.asBackend().poll(t) catch 0;
            }
            if (self.uring_active and woken == 0) {
                woken += self.harvestCqes(0) catch 0;
            }
        } else {
            woken += self.reactor.asBackend().poll(timeout_ns) catch 0;
        }
        return woken;
    }

    fn supportsAsyncV(ptr: *anyopaque) bool {
        const self: *IoUringBackend = @ptrCast(@alignCast(ptr));
        return self.uring_active;
    }

    fn asyncReadV(ptr: *anyopaque, handle: be.Handle, buf: []u8) be.BackendError!usize {
        const self: *IoUringBackend = @ptrCast(@alignCast(ptr));
        return self.asyncRead(handle, buf);
    }

    fn asyncWriteV(ptr: *anyopaque, handle: be.Handle, buf: []const u8) be.BackendError!usize {
        const self: *IoUringBackend = @ptrCast(@alignCast(ptr));
        return self.asyncWrite(handle, buf);
    }

    fn asyncRead(self: *IoUringBackend, handle: be.Handle, buf: []u8) be.BackendError!usize {
        if (comptime !is_linux) return error.Unsupported;
        if (!self.uring_active) return error.Unsupported;

        const me = task_mod.current() orelse @panic("zigroutines: async_read outside task");
        const req = try self.acquireReq(me);

        const ud: u64 = @intFromPtr(req);
        const fd: std.os.linux.fd_t = @intCast(handle);

        self.lock.lock();
        const ring = &(self.ring orelse {
            self.lock.unlock();
            self.finishReq(req);
            return error.Unsupported;
        });
        _ = ring.recv(ud, fd, .{ .buffer = buf }, 0) catch {
            self.lock.unlock();
            self.finishReq(req);
            return error.Unexpected;
        };
        _ = ring.submit() catch {
            self.lock.unlock();
            self.finishReq(req);
            return error.Unexpected;
        };
        self.pending.append(self.allocator, req) catch {};
        _ = self.harvestCqesUnlocked(0) catch {};
        if (req.done) {
            self.lock.unlock();
            return self.takeResult(req);
        }
        req.parked = true;
        self.lock.unlock();

        const ex = me.executor orelse @panic("zigroutines: async_read without executor");
        ex.parkFromRunning(.io);
        return self.takeResult(req);
    }

    fn asyncWrite(self: *IoUringBackend, handle: be.Handle, buf: []const u8) be.BackendError!usize {
        if (comptime !is_linux) return error.Unsupported;
        if (!self.uring_active) return error.Unsupported;

        const me = task_mod.current() orelse @panic("zigroutines: async_write outside task");
        const req = try self.acquireReq(me);

        const ud: u64 = @intFromPtr(req);
        const fd: std.os.linux.fd_t = @intCast(handle);

        self.lock.lock();
        const ring = &(self.ring orelse {
            self.lock.unlock();
            self.finishReq(req);
            return error.Unsupported;
        });
        _ = ring.send(ud, fd, buf, 0) catch {
            self.lock.unlock();
            self.finishReq(req);
            return error.Unexpected;
        };
        _ = ring.submit() catch {
            self.lock.unlock();
            self.finishReq(req);
            return error.Unexpected;
        };
        self.pending.append(self.allocator, req) catch {};
        _ = self.harvestCqesUnlocked(0) catch {};
        if (req.done) {
            self.lock.unlock();
            return self.takeResult(req);
        }
        req.parked = true;
        self.lock.unlock();

        const ex = me.executor orelse @panic("zigroutines: async_write without executor");
        ex.parkFromRunning(.io);
        return self.takeResult(req);
    }

    fn acquireReq(self: *IoUringBackend, task: *task_mod.Task) !*UringReq {
        self.lock.lock();
        const reused = self.free_reqs.pop();
        self.lock.unlock();
        const req = reused orelse (self.allocator.create(UringReq) catch return error.OutOfMemory);
        req.* = .{ .task = task };
        return req;
    }

    fn finishReq(self: *IoUringBackend, req: *UringReq) void {
        self.lock.lock();
        defer self.lock.unlock();
        req.released = true;
        const was_pending = self.removePendingUnlocked(req);
        if (req.cqe_seen or !was_pending) {
            self.recycleUnlocked(req);
        }
    }

    fn takeResult(self: *IoUringBackend, req: *UringReq) be.BackendError!usize {
        const err = req.err;
        const res = req.res;
        self.finishReq(req);
        if (err) |e| return e;
        return resultToLen(res);
    }

    fn recycleUnlocked(self: *IoUringBackend, req: *UringReq) void {
        req.* = .{ .task = req.task, .released = true, .done = true };
        self.free_reqs.append(self.allocator, req) catch {
            self.allocator.destroy(req);
        };
    }

    fn removePendingUnlocked(self: *IoUringBackend, req: *UringReq) bool {
        if (comptime !is_linux) return false;
        for (self.pending.items, 0..) |p, i| {
            if (p == req) {
                _ = self.pending.swapRemove(i);
                return true;
            }
        }
        return false;
    }

    fn harvestCqes(self: *IoUringBackend, timeout_ns: u64) be.BackendError!usize {
        self.lock.lock();
        defer self.lock.unlock();
        return self.harvestCqesUnlocked(timeout_ns);
    }

    fn harvestCqesUnlocked(self: *IoUringBackend, timeout_ns: u64) be.BackendError!usize {
        if (comptime !is_linux) return 0;
        const ring = &(self.ring orelse return 0);

        var cqes: [32]std.os.linux.io_uring_cqe = undefined;
        _ = timeout_ns;
        const n = ring.copy_cqes(&cqes, 0) catch |err| switch (err) {
            error.SignalInterrupt => return 0,
            else => return error.Unexpected,
        };

        var woken: usize = 0;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const cqe = cqes[i];
            if (cqe.user_data == 0) continue;
            const req: *UringReq = @ptrFromInt(cqe.user_data);
            if (req.cqe_seen) continue;
            req.cqe_seen = true;
            req.res = cqe.res;
            req.done = true;
            if (req.err == null and cqe.res < 0) {
                if (cqe.res == sys_posix.linuxNegErrno(.CANCELED)) req.err = error.Closed;
            }
            if (req.released) {
                _ = self.removePendingUnlocked(req);
                self.recycleUnlocked(req);
                continue;
            }
            if (req.parked) {
                be.wakeTask(req.task);
                woken += 1;
            }
        }
        return woken;
    }

    fn resultToLen(res: i32) be.BackendError!usize {
        if (res < 0) {
            if (res == sys_posix.linuxNegErrno(.CONNRESET)) return error.ConnectionReset;
            if (res == sys_posix.linuxNegErrno(.PIPE)) return error.ConnectionReset;
            return error.Unexpected;
        }
        return @intCast(res);
    }
};
