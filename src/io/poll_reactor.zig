const std = @import("std");
const builtin = @import("builtin");
const task_mod = @import("../core/task.zig");
const sync = @import("../core/synchronization.zig");
const backend = @import("io_backend.zig");
const timer_mod = @import("../core/timer_queue.zig");
const task_wake = @import("../utils/task_wake.zig");

const Handle = backend.Handle;
const Interest = backend.Interest;
const Waiter = backend.Waiter;
const Backend = backend.Backend;
const BackendError = backend.BackendError;

const is_windows = builtin.os.tag == .windows;
const is_linux = builtin.os.tag == .linux;

const Entry = struct {
    handle: Handle,
    waiters: std.ArrayListUnmanaged(*Waiter) = .empty,
};

pub const Reactor = struct {
    allocator: std.mem.Allocator,
    lock: sync.SpinLock = .{},
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    epoll_fd: if (is_linux) std.posix.fd_t else void = if (is_linux) -1 else {},
    wsa_started: bool = false,

    pub fn create(allocator: std.mem.Allocator) !*Reactor {
        const self = try allocator.create(Reactor);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator };

        if (comptime is_windows) {
            try ensureWsa();
            self.wsa_started = true;
        } else if (comptime is_linux) {
            const rc = std.os.linux.epoll_create1(std.os.linux.EPOLL.CLOEXEC);
            const err = std.posix.errno(rc);
            if (err != .SUCCESS) return error.Unexpected;
            self.epoll_fd = @intCast(rc);
        }

        return self;
    }

    pub fn destroy(self: *Reactor) void {
        self.lock.lock();
        for (self.entries.items) |*e| {
            e.waiters.deinit(self.allocator);
        }
        self.entries.deinit(self.allocator);
        self.lock.unlock();

        if (comptime is_linux) {
            if (self.epoll_fd >= 0) {
                std.posix.close(self.epoll_fd);
            }
        }

        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn asBackend(self: *Reactor) Backend {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    const vtable = Backend.VTable{
        .deinit = deinitV,
        .wait = waitV,
        .poll = pollV,
        .cancel_all = cancelAllV,
    };

    fn cancelAllV(ptr: *anyopaque) void {
        const self: *Reactor = @ptrCast(@alignCast(ptr));
        self.cancelAll();
    }

    pub fn cancelAll(self: *Reactor) void {
        var to_wake: std.ArrayListUnmanaged(*task_mod.Task) = .empty;
        defer to_wake.deinit(self.allocator);

        self.lock.lock();
        for (self.entries.items) |*e| {
            for (e.waiters.items) |w| {
                w.done = true;
                w.err = error.Closed;
                if (w.parked) {
                    to_wake.append(self.allocator, w.task) catch {};
                }
            }
            e.waiters.clearRetainingCapacity();
            e.waiters.deinit(self.allocator);
        }
        self.entries.clearRetainingCapacity();
        self.lock.unlock();

        for (to_wake.items) |t| {
            task_wake.wakeTask(t);
        }
    }

    fn deinitV(ptr: *anyopaque) void {
        const self: *Reactor = @ptrCast(@alignCast(ptr));
        self.destroy();
    }

    fn waitV(ptr: *anyopaque, handle: Handle, interest: Interest) BackendError!void {
        const self: *Reactor = @ptrCast(@alignCast(ptr));
        return self.wait(handle, interest);
    }

    fn pollV(ptr: *anyopaque, timeout_ns: u64) BackendError!usize {
        const self: *Reactor = @ptrCast(@alignCast(ptr));
        return self.poll(timeout_ns);
    }

    pub fn wait(self: *Reactor, handle: Handle, interest: Interest) BackendError!void {
        const me = task_mod.current() orelse @panic("zigroutines: I/O wait outside a task");
        var waiter = Waiter{
            .task = me,
            .interest = interest,
        };

        try self.register(handle, &waiter);

        self.lock.lock();
        if (waiter.done) {
            self.lock.unlock();
            self.unregister(handle, &waiter);
            if (waiter.err) |e| return e;
            return;
        }
        waiter.parked = true;
        self.lock.unlock();

        const ex = me.executor orelse @panic("zigroutines: I/O wait without executor");
        ex.parkFromRunning(.io);

        self.unregister(handle, &waiter);

        if (waiter.err) |e| return e;
        if (!waiter.done) return error.Unexpected;
    }

    fn register(self: *Reactor, handle: Handle, waiter: *Waiter) BackendError!void {
        self.lock.lock();
        defer self.lock.unlock();

        const entry = try self.getOrCreateEntry(handle);
        entry.waiters.append(self.allocator, waiter) catch return error.OutOfMemory;

        if (comptime is_linux) {
            self.epollAddOrMod(handle, entry) catch {};
        }
    }

    fn unregister(self: *Reactor, handle: Handle, waiter: *Waiter) void {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.findEntry(handle)) |idx| {
            const entry = &self.entries.items[idx];
            for (entry.waiters.items, 0..) |w, i| {
                if (w == waiter) {
                    _ = entry.waiters.orderedRemove(i);
                    break;
                }
            }
            if (entry.waiters.items.len == 0) {
                if (comptime is_linux) {
                    self.epollDel(handle);
                }
                entry.waiters.deinit(self.allocator);
                _ = self.entries.orderedRemove(idx);
            } else if (comptime is_linux) {
                self.epollAddOrMod(handle, entry) catch {};
            }
        }
    }

    fn getOrCreateEntry(self: *Reactor, handle: Handle) BackendError!*Entry {
        if (self.findEntry(handle)) |idx| return &self.entries.items[idx];
        self.entries.append(self.allocator, .{ .handle = handle }) catch return error.OutOfMemory;
        return &self.entries.items[self.entries.items.len - 1];
    }

    fn findEntry(self: *Reactor, handle: Handle) ?usize {
        for (self.entries.items, 0..) |e, i| {
            if (e.handle == handle) return i;
        }
        return null;
    }

    pub fn poll(self: *Reactor, timeout_ns: u64) BackendError!usize {
        if (comptime is_windows) {
            return self.pollWindows(timeout_ns);
        } else if (comptime is_linux) {
            return self.pollEpoll(timeout_ns);
        } else {
            return self.pollPosix(timeout_ns);
        }
    }

    fn timeoutMs(timeout_ns: u64) i32 {
        if (timeout_ns == 0) return 0;
        const ms = timeout_ns / std.time.ns_per_ms;
        if (ms == 0) return 1;
        return @intCast(@min(ms, std.math.maxInt(i32)));
    }

    fn completeWaiters(
        self: *Reactor,
        handle: Handle,
        ready_read: bool,
        ready_write: bool,
        ready_err: bool,
        to_wake: *std.ArrayListUnmanaged(*task_mod.Task),
    ) void {
        const idx = self.findEntry(handle) orelse return;
        const entry = &self.entries.items[idx];
        var wi: usize = 0;
        while (wi < entry.waiters.items.len) {
            const w = entry.waiters.items[wi];
            const ready = switch (w.interest) {
                .read => ready_read or ready_err,
                .write => ready_write or ready_err,
            };
            if (!ready) {
                wi += 1;
                continue;
            }
            w.done = true;
            if (w.parked) {
                to_wake.append(self.allocator, w.task) catch {};
            }
            _ = entry.waiters.orderedRemove(wi);
        }
        if (entry.waiters.items.len == 0) {
            if (comptime is_linux) {
                self.epollDel(handle);
            }
            entry.waiters.deinit(self.allocator);
            _ = self.entries.orderedRemove(idx);
        } else if (comptime is_linux) {
            self.epollAddOrMod(handle, entry) catch {};
        }
    }

    fn pollWindows(self: *Reactor, timeout_ns: u64) BackendError!usize {
        self.lock.lock();
        const n = self.entries.items.len;
        if (n == 0) {
            self.lock.unlock();
            if (timeout_ns > 0) {
                std.Thread.yield() catch {};
            }
            return 0;
        }

        var handles: [FD_SETSIZE]Handle = undefined;
        var want_read: [FD_SETSIZE]bool = undefined;
        var want_write: [FD_SETSIZE]bool = undefined;
        if (n > FD_SETSIZE) {
            self.lock.unlock();
            return error.Unexpected;
        }

        var i: usize = 0;
        while (i < n) : (i += 1) {
            const e = self.entries.items[i];
            handles[i] = e.handle;
            want_read[i] = false;
            want_write[i] = false;
            for (e.waiters.items) |w| {
                switch (w.interest) {
                    .read => want_read[i] = true,
                    .write => want_write[i] = true,
                }
            }
        }
        self.lock.unlock();

        var read_set: FdSet = .{};
        var write_set: FdSet = .{};
        var except_set: FdSet = .{};
        fdZero(&read_set);
        fdZero(&write_set);
        fdZero(&except_set);

        i = 0;
        while (i < n) : (i += 1) {
            const h = handles[i];
            if (want_read[i]) fdSet(h, &read_set);
            if (want_write[i]) {
                fdSet(h, &write_set);
                fdSet(h, &except_set);
            }
        }

        var tv: TimeVal = undefined;
        const tv_ptr: ?*TimeVal = if (timeout_ns == 0) blk: {
            tv = .{ .tv_sec = 0, .tv_usec = 0 };
            break :blk &tv;
        } else blk: {
            const ms = timeoutMs(timeout_ns);
            tv = .{
                .tv_sec = @divTrunc(ms, 1000),
                .tv_usec = @rem(ms, 1000) * 1000,
            };
            break :blk &tv;
        };

        const rc = winSelect(0, &read_set, &write_set, &except_set, tv_ptr);
        if (rc == SOCKET_ERROR) return error.Unexpected;
        if (rc == 0) return 0;

        var to_wake: std.ArrayListUnmanaged(*task_mod.Task) = .empty;
        defer to_wake.deinit(self.allocator);

        self.lock.lock();
        i = 0;
        while (i < n) : (i += 1) {
            const h = handles[i];
            const r = fdIsSet(h, &read_set);
            const w = fdIsSet(h, &write_set);
            const e = fdIsSet(h, &except_set);
            if (!r and !w and !e) continue;
            self.completeWaiters(h, r, w or e, e, &to_wake);
        }
        self.lock.unlock();

        var woken: usize = 0;
        for (to_wake.items) |t| {
            task_wake.wakeTask(t);
            woken += 1;
        }
        return woken;
    }

    fn pollEpoll(self: *Reactor, timeout_ns: u64) BackendError!usize {
        if (comptime !is_linux) return error.Unsupported;

        var events: [64]std.os.linux.epoll_event = undefined;
        const timeout_ms = timeoutMs(timeout_ns);

        const rc = std.os.linux.epoll_wait(self.epoll_fd, &events, events.len, timeout_ms);
        const err = std.posix.errno(rc);
        if (err != .SUCCESS) {
            if (err == .INTR) return 0;
            return error.Unexpected;
        }
        const n: usize = @intCast(rc);
        if (n == 0) return 0;

        var to_wake: std.ArrayListUnmanaged(*task_mod.Task) = .empty;
        defer to_wake.deinit(self.allocator);

        self.lock.lock();
        for (events[0..n]) |ev| {
            const handle: Handle = @intCast(ev.data.fd);
            const rev = ev.events;
            const ready_read = (rev & (std.os.linux.EPOLL.IN | std.os.linux.EPOLL.HUP | std.os.linux.EPOLL.RDHUP)) != 0;
            const ready_write = (rev & std.os.linux.EPOLL.OUT) != 0;
            const ready_err = (rev & std.os.linux.EPOLL.ERR) != 0;
            self.completeWaiters(handle, ready_read, ready_write, ready_err, &to_wake);
        }
        self.lock.unlock();

        var woken: usize = 0;
        for (to_wake.items) |t| {
            task_wake.wakeTask(t);
            woken += 1;
        }
        return woken;
    }

    fn epollAddOrMod(self: *Reactor, handle: Handle, entry: *Entry) !void {
        if (comptime !is_linux) return;
        var events: u32 = 0;
        for (entry.waiters.items) |w| {
            switch (w.interest) {
                .read => events |= std.os.linux.EPOLL.IN | std.os.linux.EPOLL.RDHUP | std.os.linux.EPOLL.HUP | std.os.linux.EPOLL.ERR,
                .write => events |= std.os.linux.EPOLL.OUT | std.os.linux.EPOLL.ERR,
            }
        }
        var ev = std.os.linux.epoll_event{
            .events = events,
            .data = .{ .fd = @intCast(handle) },
        };

        var rc = std.os.linux.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_MOD, @intCast(handle), &ev);
        if (std.posix.errno(rc) == .NOENT) {
            rc = std.os.linux.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_ADD, @intCast(handle), &ev);
        }
    }

    fn epollDel(self: *Reactor, handle: Handle) void {
        if (comptime !is_linux) return;
        var ev: std.os.linux.epoll_event = undefined;
        _ = std.os.linux.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_DEL, @intCast(handle), &ev);
    }

    fn pollPosix(self: *Reactor, timeout_ns: u64) BackendError!usize {
        if (comptime is_windows or is_linux) return error.Unsupported;

        self.lock.lock();
        const n = self.entries.items.len;
        if (n == 0) {
            self.lock.unlock();
            return 0;
        }
        var fds = self.allocator.alloc(std.posix.pollfd, n) catch {
            self.lock.unlock();
            return error.OutOfMemory;
        };
        defer self.allocator.free(fds);

        for (self.entries.items, 0..) |e, i| {
            var events: i16 = 0;
            for (e.waiters.items) |w| {
                switch (w.interest) {
                    .read => events |= std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR,
                    .write => events |= std.posix.POLL.OUT | std.posix.POLL.ERR,
                }
            }
            fds[i] = .{
                .fd = @intCast(e.handle),
                .events = events,
                .revents = 0,
            };
        }
        self.lock.unlock();

        const timeout_ms = timeoutMs(timeout_ns);
        _ = std.posix.poll(fds, timeout_ms) catch return error.Unexpected;

        var to_wake: std.ArrayListUnmanaged(*task_mod.Task) = .empty;
        defer to_wake.deinit(self.allocator);

        self.lock.lock();
        for (fds) |pfd| {
            if (pfd.revents == 0) continue;
            const handle: Handle = @intCast(pfd.fd);
            const ready_read = (pfd.revents & (std.posix.POLL.IN | std.posix.POLL.HUP)) != 0;
            const ready_write = (pfd.revents & std.posix.POLL.OUT) != 0;
            const ready_err = (pfd.revents & std.posix.POLL.ERR) != 0;
            self.completeWaiters(handle, ready_read, ready_write, ready_err, &to_wake);
        }
        self.lock.unlock();

        var woken: usize = 0;
        for (to_wake.items) |t| {
            task_wake.wakeTask(t);
            woken += 1;
        }
        return woken;
    }
};

// Windows select() FFI
const FD_SETSIZE: usize = 64;
const SOCKET_ERROR: i32 = -1;

const TimeVal = extern struct {
    tv_sec: i32,
    tv_usec: i32,
};

/// Winsock fd_set: fd_count + fixed array of SOCKET.
const FdSet = extern struct {
    fd_count: u32 = 0,
    fd_array: [FD_SETSIZE]usize = @splat(0),
};

fn fdZero(set: *FdSet) void {
    set.fd_count = 0;
}

fn fdSet(socket: Handle, set: *FdSet) void {
    if (set.fd_count >= FD_SETSIZE) return;
    var i: u32 = 0;
    while (i < set.fd_count) : (i += 1) {
        if (set.fd_array[i] == socket) return;
    }
    set.fd_array[set.fd_count] = socket;
    set.fd_count += 1;
}

fn fdIsSet(socket: Handle, set: *const FdSet) bool {
    var i: u32 = 0;
    while (i < set.fd_count) : (i += 1) {
        if (set.fd_array[i] == socket) return true;
    }
    return false;
}

const WSAData = extern struct {
    wVersion: u16,
    wHighVersion: u16,
    szDescription: [257]u8,
    szSystemStatus: [129]u8,
    iMaxSockets: u16,
    iMaxUdpDg: u16,
    lpVendorInfo: ?[*]u8,
};

const WINAPI = if (is_windows) std.builtin.CallingConvention.winapi else .c;

extern "ws2_32" fn WSAStartup(wVersionRequested: u16, lpWSAData: *WSAData) callconv(WINAPI) i32;
extern "ws2_32" fn select(
    nfds: i32,
    readfds: ?*FdSet,
    writefds: ?*FdSet,
    exceptfds: ?*FdSet,
    timeout: ?*TimeVal,
) callconv(WINAPI) i32;

fn winSelect(
    nfds: i32,
    readfds: ?*FdSet,
    writefds: ?*FdSet,
    exceptfds: ?*FdSet,
    timeout: ?*TimeVal,
) i32 {
    if (comptime !is_windows) return SOCKET_ERROR;
    return select(nfds, readfds, writefds, exceptfds, timeout);
}

fn ensureWsa() !void {
    if (comptime !is_windows) return;
    var data: WSAData = undefined;
    const rc = WSAStartup(0x0202, &data);
    if (rc != 0) return error.Unexpected;
}

comptime {
    _ = timer_mod;
}
