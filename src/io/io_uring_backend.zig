const std = @import("std");
const builtin = @import("builtin");
const be = @import("io_backend.zig");
const reactor_mod = @import("poll_reactor.zig");
const task_mod = @import("../core/task.zig");
const sync = @import("../core/synchronization.zig");

const is_linux = builtin.os.tag == .linux;

const LinuxIoUring = if (is_linux) std.os.linux.IoUring else struct {};

pub const IoUringBackend = struct {
    allocator: std.mem.Allocator,
    reactor: *reactor_mod.Reactor,
    lock: sync.SpinLock = .{},
    ring: if (is_linux) ?LinuxIoUring else void = if (is_linux) null else {},
    uring_active: bool = false,

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
        if (comptime is_linux) {
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
        .async_read = if (is_linux) asyncReadV else null,
        .async_write = if (is_linux) asyncWriteV else null,
        .supports_async = supportsAsyncV,
    };

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
                woken += self.harvestCqes(timeout_ns) catch 0;
            }
            const t: u64 = if (woken > 0) 0 else timeout_ns;
            woken += self.reactor.asBackend().poll(t) catch 0;
        } else {
            woken += self.reactor.asBackend().poll(timeout_ns) catch 0;
        }
        return woken;
    }

    fn supportsAsyncV(ptr: *anyopaque) bool {
        const self: *IoUringBackend = @ptrCast(@alignCast(ptr));
        return self.uring_active;
    }

    const UringReq = struct {
        task: *task_mod.Task,
        done: bool = false,
        parked: bool = false,
        res: i32 = 0,
    };

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
        var req = UringReq{ .task = me };
        const ud: u64 = @intFromPtr(&req);
        const fd: std.os.linux.fd_t = @intCast(handle);

        self.lock.lock();
        const ring = &(self.ring orelse {
            self.lock.unlock();
            return error.Unsupported;
        });
        _ = ring.recv(ud, fd, .{ .buffer = buf }, 0) catch {
            self.lock.unlock();
            return error.Unexpected;
        };
        _ = ring.submit() catch {
            self.lock.unlock();
            return error.Unexpected;
        };
        self.lock.unlock();

        self.lock.lock();
        _ = self.harvestCqesUnlocked(0) catch {};
        if (req.done) {
            self.lock.unlock();
            return resultToLen(req.res);
        }
        req.parked = true;
        self.lock.unlock();

        const ex = me.executor orelse @panic("zigroutines: async_read without executor");
        ex.parkFromRunning(.io);

        return resultToLen(req.res);
    }

    fn asyncWrite(self: *IoUringBackend, handle: be.Handle, buf: []const u8) be.BackendError!usize {
        if (comptime !is_linux) return error.Unsupported;
        if (!self.uring_active) return error.Unsupported;

        const me = task_mod.current() orelse @panic("zigroutines: async_write outside task");
        var req = UringReq{ .task = me };
        const ud: u64 = @intFromPtr(&req);
        const fd: std.os.linux.fd_t = @intCast(handle);

        self.lock.lock();
        const ring = &(self.ring orelse {
            self.lock.unlock();
            return error.Unsupported;
        });
        _ = ring.send(ud, fd, buf, 0) catch {
            self.lock.unlock();
            return error.Unexpected;
        };
        _ = ring.submit() catch {
            self.lock.unlock();
            return error.Unexpected;
        };
        self.lock.unlock();

        self.lock.lock();
        _ = self.harvestCqesUnlocked(0) catch {};
        if (req.done) {
            self.lock.unlock();
            return resultToLen(req.res);
        }
        req.parked = true;
        self.lock.unlock();

        const ex = me.executor orelse @panic("zigroutines: async_write without executor");
        ex.parkFromRunning(.io);

        return resultToLen(req.res);
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
        const wait_nr: u32 = if (timeout_ns > 0) 1 else 0;
        const n = ring.copy_cqes(&cqes, wait_nr) catch |err| switch (err) {
            error.SignalInterrupt => return 0,
            else => return error.Unexpected,
        };

        var woken: usize = 0;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const cqe = cqes[i];
            if (cqe.user_data == 0) continue;
            const req: *UringReq = @ptrFromInt(cqe.user_data);
            req.res = cqe.res;
            req.done = true;
            if (req.parked) {
                be.wakeTask(req.task);
                woken += 1;
            }
        }
        return woken;
    }

    fn resultToLen(res: i32) be.BackendError!usize {
        if (res < 0) {
            if (res == -std.os.linux.E.CONNRESET) return error.ConnectionReset;
            if (res == -std.os.linux.E.PIPE) return error.ConnectionReset;
            return error.Unexpected;
        }
        return @intCast(res);
    }
};
