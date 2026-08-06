const std = @import("std");
const builtin = @import("builtin");
const be = @import("io_backend.zig");
const reactor_mod = @import("poll_reactor.zig");
const task_mod = @import("../core/task.zig");
const sync = @import("../core/synchronization.zig");

const is_windows = builtin.os.tag == .windows;

pub const IocpBackend = struct {
    allocator: std.mem.Allocator,
    reactor: *reactor_mod.Reactor,
    lock: sync.SpinLock = .{},
    iocp: if (is_windows) ?*anyopaque else void = if (is_windows) null else {},
    associated: if (is_windows) std.AutoHashMapUnmanaged(be.Handle, void) else void =
        if (is_windows) .{} else {},
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
            self.async_enabled = true;
            ensureWsa() catch {};
        }
        return self;
    }

    pub fn destroy(self: *IocpBackend) void {
        if (comptime is_windows) {
            const win = @import("../utils/windows_api.zig");
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

    const vtable = be.Backend.VTable{
        .deinit = deinitV,
        .wait = waitV,
        .poll = pollV,
        .associate = associateV,
        .async_read = if (is_windows) asyncReadV else null,
        .async_write = if (is_windows) asyncWriteV else null,
        .supports_async = supportsAsyncV,
    };

    fn deinitV(ptr: *anyopaque) void {
        const self: *IocpBackend = @ptrCast(@alignCast(ptr));
        self.destroy();
    }

    fn waitV(ptr: *anyopaque, handle: be.Handle, interest: be.Interest) be.BackendError!void {
        const self: *IocpBackend = @ptrCast(@alignCast(ptr));
        try self.associateHandle(handle);
        return self.reactor.asBackend().wait(handle, interest);
    }

    fn pollV(ptr: *anyopaque, timeout_ns: u64) be.BackendError!usize {
        const self: *IocpBackend = @ptrCast(@alignCast(ptr));
        var woken: usize = 0;
        if (comptime is_windows) {
            woken += self.drainCompletions(timeout_ns) catch 0;
            const t: u64 = if (woken > 0) 0 else timeout_ns;
            woken += self.reactor.asBackend().poll(t) catch 0;
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

    const IoRequest = struct {
        ov: @import("../utils/windows_api.zig").OVERLAPPED = .{},
        task: *task_mod.Task,
        done: bool = false,
        parked: bool = false,
        bytes: u32 = 0,
        err: ?be.BackendError = null,
    };

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
        try self.associateHandle(handle);
        const me = task_mod.current() orelse @panic("zigroutines: async_read outside task");

        var req = IoRequest{ .task = me };
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

        if (rc == 0) {
            return transferred;
        }
        const err = WSAGetLastError();
        if (err != WSA_IO_PENDING) {
            if (err == WSAECONNRESET) return error.ConnectionReset;
            return error.Unexpected;
        }

        req.parked = true;
        const ex = me.executor orelse @panic("zigroutines: async_read without executor");
        ex.parkFromRunning(.io);

        if (req.err) |e| return e;
        if (!req.done) return error.Unexpected;
        return req.bytes;
    }

    fn asyncWrite(self: *IocpBackend, handle: be.Handle, buf: []const u8) be.BackendError!usize {
        if (comptime !is_windows) return error.Unsupported;
        try self.associateHandle(handle);
        const me = task_mod.current() orelse @panic("zigroutines: async_write outside task");

        var req = IoRequest{ .task = me };
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

        if (rc == 0) {
            return transferred;
        }
        const err = WSAGetLastError();
        if (err != WSA_IO_PENDING) {
            if (err == WSAECONNRESET) return error.ConnectionReset;
            return error.Unexpected;
        }

        req.parked = true;
        const ex = me.executor orelse @panic("zigroutines: async_write without executor");
        ex.parkFromRunning(.io);

        if (req.err) |e| return e;
        if (!req.done) return error.Unexpected;
        return req.bytes;
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
            const ov_ptr = entries[i].lpOverlapped orelse continue;
            const req: *IoRequest = @fieldParentPtr("ov", ov_ptr);
            req.bytes = entries[i].dwNumberOfBytesTransferred;
            req.done = true;
            if (req.parked) {
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
