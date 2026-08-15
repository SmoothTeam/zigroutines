// SPDX-FileCopyrightText: 2026 Apanazar
//
// SPDX-License-Identifier: LGPL-3.0-or-later

const std = @import("std");
const builtin = @import("builtin");
const be = @import("io_backend.zig");
const reactor_mod = @import("poll_reactor.zig");
const task_mod = @import("../core/task.zig");
const sync = @import("../core/synchronization.zig");

const is_windows = builtin.os.tag == .windows;

const IoRequest = struct {
    ov: @import("../utils/windows_api.zig").OVERLAPPED = .{},
    task: *task_mod.Task,
    handle: be.Handle = 0,
    done: bool = false,
    parked: bool = false,
    bytes: u32 = 0,
    err: ?be.BackendError = null,
};

pub const IocpBackend = struct {
    allocator: std.mem.Allocator,
    reactor: *reactor_mod.Reactor,
    lock: sync.SpinLock = .{},
    iocp: if (is_windows) ?*anyopaque else void = if (is_windows) null else {},
    associated: if (is_windows) std.AutoHashMapUnmanaged(be.Handle, void) else void =
        if (is_windows) .{} else {},
    pending: if (is_windows) std.ArrayListUnmanaged(*IoRequest) else void =
        if (is_windows) .empty else {},
    free_reqs: if (is_windows) std.ArrayListUnmanaged(*IoRequest) else void =
        if (is_windows) .empty else {},
    async_enabled: bool = is_windows,

    pub fn create(allocator: std.mem.Allocator) !*IocpBackend {
        const self = try allocator.create(IocpBackend);
        errdefer allocator.destroy(self);
        const r = try reactor_mod.Reactor.create(allocator);
        errdefer r.destroy();

        self.* = .{
            .allocator = allocator,
            .reactor = r,
        };

        if (comptime is_windows) {
            const win = @import("../utils/windows_api.zig");
            const h = win.CreateIoCompletionPort(win.INVALID_HANDLE_VALUE, null, 0, 0);
            if (h == null or h == win.INVALID_HANDLE_VALUE) {
                r.destroy();
                allocator.destroy(self);
                return error.Unexpected;
            }
            self.iocp = h;
            self.associated = .{};
            self.pending = .empty;
            self.free_reqs = .empty;
            self.async_enabled = true;
            ensureWsa() catch {};
        }
        return self;
    }

    pub fn destroy(self: *IocpBackend) void {
        self.cancelAll();
        if (comptime is_windows) {
            const win = @import("../utils/windows_api.zig");
            var spins: u32 = 0;
            while (spins < 8) : (spins += 1) {
                if ((self.drainCompletions(0) catch 0) == 0) break;
            }
            for (self.free_reqs.items) |r| self.allocator.destroy(r);
            self.free_reqs.deinit(self.allocator);
            self.pending.deinit(self.allocator);
            self.associated.deinit(self.allocator);
            if (self.iocp) |h| {
                _ = win.CloseHandle(h);
            }
        }
        self.reactor.destroy();
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn backend(self: *IocpBackend) be.Backend {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    const wake_key: usize = std.math.maxInt(usize);

    const vtable = be.Backend.VTable{
        .deinit = deinitV,
        .wait = waitV,
        .poll = pollV,
        .associate = associateV,
        .cancel_all = cancelAllV,
        .wakeup = wakeupV,
        .async_read = if (is_windows) asyncReadV else null,
        .async_write = if (is_windows) asyncWriteV else null,
        .supports_async = supportsAsyncV,
    };

    fn cancelAllV(ptr: *anyopaque) void {
        const self: *IocpBackend = @ptrCast(@alignCast(ptr));
        self.cancelAll();
    }

    fn wakeupV(ptr: *anyopaque) void {
        const self: *IocpBackend = @ptrCast(@alignCast(ptr));
        self.wakeup();
    }

    pub fn wakeup(self: *IocpBackend) void {
        if (comptime !is_windows) {
            self.reactor.poke();
            return;
        }
        const win = @import("../utils/windows_api.zig");
        if (self.iocp) |h| {
            _ = win.PostQueuedCompletionStatus(h, 0, wake_key, null);
        }
        self.reactor.poke();
    }

    pub fn cancelAll(self: *IocpBackend) void {
        self.reactor.cancelAll();
        if (comptime !is_windows) return;
        const win = @import("../utils/windows_api.zig");
        var to_wake: std.ArrayListUnmanaged(*task_mod.Task) = .empty;
        defer to_wake.deinit(self.allocator);

        self.lock.lock();
        for (self.pending.items) |req| {
            _ = win.CancelIoEx(@ptrFromInt(req.handle), &req.ov);
            if (!req.done) {
                req.err = error.Closed;
                req.done = true;
                if (req.parked) to_wake.append(self.allocator, req.task) catch {};
            }
        }
        self.pending.clearRetainingCapacity();
        self.lock.unlock();
        self.wakeup();
        for (to_wake.items) |t| be.wakeTask(t);
    }

    fn deinitV(ptr: *anyopaque) void {
        const self: *IocpBackend = @ptrCast(@alignCast(ptr));
        self.destroy();
    }

    fn waitV(ptr: *anyopaque, handle: be.Handle, interest: be.Interest) be.BackendError!void {
        const self: *IocpBackend = @ptrCast(@alignCast(ptr));
        return self.reactor.asBackend().wait(handle, interest);
    }

    fn pollV(ptr: *anyopaque, timeout_ns: u64) be.BackendError!usize {
        const self: *IocpBackend = @ptrCast(@alignCast(ptr));
        var woken: usize = 0;
        if (comptime is_windows) {
            const need_ready = self.reactor.hasWaiters();
            if (need_ready) {
                woken += self.drainCompletions(0) catch 0;
                const t: u64 = if (woken > 0) 0 else timeout_ns;
                woken += self.reactor.asBackend().poll(t) catch 0;
            } else {
                woken += self.drainCompletions(timeout_ns) catch 0;
            }
        } else {
            woken += self.reactor.asBackend().poll(timeout_ns) catch 0;
        }
        return woken;
    }

    fn associateV(ptr: *anyopaque, handle: be.Handle) be.BackendError!void {
        const self: *IocpBackend = @ptrCast(@alignCast(ptr));
        return self.associateHandle(handle);
    }

    fn supportsAsyncV(ptr: *anyopaque) bool {
        const self: *IocpBackend = @ptrCast(@alignCast(ptr));
        return self.async_enabled;
    }

    fn associateHandle(self: *IocpBackend, handle: be.Handle) be.BackendError!void {
        if (comptime !is_windows) return;
        const win = @import("../utils/windows_api.zig");
        self.lock.lock();
        defer self.lock.unlock();
        if (self.associated.contains(handle)) return;
        const iocp = self.iocp orelse return error.Unexpected;
        const r = win.CreateIoCompletionPort(@ptrFromInt(handle), iocp, handle, 0);
        if (r == null) {}
        self.associated.put(self.allocator, handle, {}) catch return error.OutOfMemory;
    }

    fn asyncReadV(ptr: *anyopaque, handle: be.Handle, buf: []u8) be.BackendError!usize {
        const self: *IocpBackend = @ptrCast(@alignCast(ptr));
        return self.asyncRead(handle, buf);
    }

    fn asyncWriteV(ptr: *anyopaque, handle: be.Handle, buf: []const u8) be.BackendError!usize {
        const self: *IocpBackend = @ptrCast(@alignCast(ptr));
        return self.asyncWrite(handle, buf);
    }

    fn asyncRead(self: *IocpBackend, handle: be.Handle, buf: []u8) be.BackendError!usize {
        if (comptime !is_windows) return error.Unsupported;
        const me = task_mod.current() orelse @panic("zigroutines: async_read outside task");

        const req = try self.acquireReq(me, handle);
        errdefer self.releaseReq(req);

        const issued = issueRecv(handle, buf, req);
        if (issued) |n| {
            self.releaseReq(req);
            return n;
        } else |err| switch (err) {
            error.WouldBlock => {},
            else => {
                self.releaseReq(req);
                return err;
            },
        }

        self.lock.lock();
        self.pending.append(self.allocator, req) catch {};
        req.parked = true;
        const already = req.done;
        self.lock.unlock();
        if (!already) {
            const ex = me.executor orelse @panic("zigroutines: async_read without executor");
            ex.parkFromRunning(.io);
        }

        self.removePending(req);
        const result: be.BackendError!usize = if (req.err) |e| e else if (!req.done) error.Unexpected else req.bytes;
        self.releaseReq(req);
        return result;
    }

    fn asyncWrite(self: *IocpBackend, handle: be.Handle, buf: []const u8) be.BackendError!usize {
        if (comptime !is_windows) return error.Unsupported;
        const me = task_mod.current() orelse @panic("zigroutines: async_write outside task");

        const req = try self.acquireReq(me, handle);
        errdefer self.releaseReq(req);

        const issued = issueSend(handle, buf, req);
        if (issued) |n| {
            self.releaseReq(req);
            return n;
        } else |err| switch (err) {
            error.WouldBlock => {},
            else => {
                self.releaseReq(req);
                return err;
            },
        }

        self.lock.lock();
        self.pending.append(self.allocator, req) catch {};
        req.parked = true;
        const already = req.done;
        self.lock.unlock();
        if (!already) {
            const ex = me.executor orelse @panic("zigroutines: async_write without executor");
            ex.parkFromRunning(.io);
        }

        self.removePending(req);
        const result: be.BackendError!usize = if (req.err) |e| e else if (!req.done) error.Unexpected else req.bytes;
        self.releaseReq(req);
        return result;
    }

    fn acquireReq(self: *IocpBackend, task: *task_mod.Task, handle: be.Handle) !*IoRequest {
        self.lock.lock();
        const reused = self.free_reqs.pop();
        self.lock.unlock();
        const req = reused orelse (self.allocator.create(IoRequest) catch return error.OutOfMemory);
        req.* = .{ .task = task, .handle = handle };
        return req;
    }

    fn releaseReq(self: *IocpBackend, req: *IoRequest) void {
        req.* = .{ .task = req.task, .handle = 0 };
        self.lock.lock();
        self.free_reqs.append(self.allocator, req) catch {
            self.lock.unlock();
            self.allocator.destroy(req);
            return;
        };
        self.lock.unlock();
    }

    fn issueRecv(handle: be.Handle, buf: []u8, req: *IoRequest) be.BackendError!usize {
        var wsabuf = WSABUF{
            .len = @intCast(@min(buf.len, std.math.maxInt(u32))),
            .buf = buf.ptr,
        };
        var flags: u32 = 0;
        var transferred: u32 = 0;
        const rc = WSARecv(
            handle,
            @as([*]WSABUF, @ptrCast(&wsabuf)),
            1,
            &transferred,
            &flags,
            @ptrCast(&req.ov),
            null,
        );
        if (rc == 0) return transferred;
        const err = WSAGetLastError();
        if (err == WSA_IO_PENDING) return error.WouldBlock;
        if (err == WSAECONNRESET) return error.ConnectionReset;
        return error.Unexpected;
    }

    fn issueSend(handle: be.Handle, buf: []const u8, req: *IoRequest) be.BackendError!usize {
        var wsabuf = WSABUF{
            .len = @intCast(@min(buf.len, std.math.maxInt(u32))),
            .buf = @constCast(buf.ptr),
        };
        var transferred: u32 = 0;
        const flags: u32 = 0;
        const rc = WSASend(
            handle,
            @as([*]WSABUF, @ptrCast(&wsabuf)),
            1,
            &transferred,
            flags,
            @ptrCast(&req.ov),
            null,
        );
        if (rc == 0) return transferred;
        const err = WSAGetLastError();
        if (err == WSA_IO_PENDING) return error.WouldBlock;
        if (err == WSAECONNRESET) return error.ConnectionReset;
        return error.Unexpected;
    }

    fn removePending(self: *IocpBackend, req: *IoRequest) void {
        if (comptime !is_windows) return;
        self.lock.lock();
        defer self.lock.unlock();
        for (self.pending.items, 0..) |p, i| {
            if (p == req) {
                _ = self.pending.swapRemove(i);
                return;
            }
        }
    }

    fn drainCompletions(self: *IocpBackend, timeout_ns: u64) be.BackendError!usize {
        if (comptime !is_windows) return 0;
        const win = @import("../utils/windows_api.zig");
        const iocp = self.iocp orelse return 0;

        const timeout_ms: u32 = if (timeout_ns == 0)
            0
        else
            @intCast(@min(timeout_ns / std.time.ns_per_ms, std.math.maxInt(u32)));

        var entries: [32]win.OVERLAPPED_ENTRY = undefined;
        var removed: u32 = 0;
        const ok = win.GetQueuedCompletionStatusEx(
            iocp,
            &entries,
            entries.len,
            &removed,
            timeout_ms,
            0,
        );
        if (ok == 0) {
            return 0;
        }

        var woken: usize = 0;
        var i: u32 = 0;
        while (i < removed) : (i += 1) {
            if (entries[i].lpCompletionKey == wake_key) continue;
            const ov_ptr = entries[i].lpOverlapped orelse continue;
            const req: *IoRequest = @fieldParentPtr("ov", ov_ptr);
            self.lock.lock();
            if (req.handle == 0 or req.done) {
                self.lock.unlock();
                continue;
            }
            req.bytes = entries[i].dwNumberOfBytesTransferred;
            req.done = true;
            const parked = req.parked;
            self.lock.unlock();
            if (parked) {
                be.wakeTask(req.task);
                woken += 1;
            }
        }
        return woken;
    }
};

const WSA_IO_PENDING: i32 = 997;
const WSAECONNRESET: i32 = 10054;

const WSABUF = extern struct {
    len: u32,
    buf: [*]u8,
};

const WINAPI = std.builtin.CallingConvention.winapi;

extern "ws2_32" fn WSARecv(
    s: be.Handle,
    lpBuffers: [*]WSABUF,
    dwBufferCount: u32,
    lpNumberOfBytesRecvd: *u32,
    lpFlags: *u32,
    lpOverlapped: ?*anyopaque,
    lpCompletionRoutine: ?*anyopaque,
) callconv(WINAPI) i32;

extern "ws2_32" fn WSASend(
    s: be.Handle,
    lpBuffers: [*]WSABUF,
    dwBufferCount: u32,
    lpNumberOfBytesSent: *u32,
    dwFlags: u32,
    lpOverlapped: ?*anyopaque,
    lpCompletionRoutine: ?*anyopaque,
) callconv(WINAPI) i32;

extern "ws2_32" fn WSAGetLastError() callconv(WINAPI) i32;
extern "ws2_32" fn WSAStartup(wVersionRequested: u16, lpWSAData: *WSAData) callconv(WINAPI) i32;

const WSAData = extern struct {
    wVersion: u16,
    wHighVersion: u16,
    szDescription: [257]u8,
    szSystemStatus: [129]u8,
    iMaxSockets: u16,
    iMaxUdpDg: u16,
    lpVendorInfo: ?[*]u8,
};

var wsa_ready = std.atomic.Value(bool).init(false);

fn ensureWsa() !void {
    if (comptime !is_windows) return;
    if (wsa_ready.load(.acquire)) return;
    var d: WSAData = undefined;
    if (WSAStartup(0x0202, &d) != 0) return error.Unexpected;
    wsa_ready.store(true, .release);
}
