const std = @import("std");
const task_mod = @import("task.zig");
const runtime_mod = @import("runtime.zig");
const cancel_mod = @import("cancellation.zig");
const timer_mod = @import("timer_queue.zig");
const trace = @import("tracing.zig");

pub const Scope = struct {
    runtime: *runtime_mod.Runtime,
    allocator: std.mem.Allocator,
    children: std.ArrayListUnmanaged(task_mod.JoinHandle) = .empty,
    token: cancel_mod.CancelToken,
    cancel_on_leave: bool = true,

    pub fn init(runtime: *runtime_mod.Runtime) Scope {
        return .{
            .runtime = runtime,
            .allocator = runtime.allocator,
            .token = cancel_mod.CancelToken.initWithAllocator(runtime.allocator),
        };
    }

    pub fn deinit(self: *Scope) void {
        self.joinAll();
        self.children.deinit(self.allocator);
        self.token.deinit();
        self.* = undefined;
    }

    pub fn spawn(
        self: *Scope,
        opts: task_mod.SpawnOptions,
        comptime func: anytype,
        args: std.meta.ArgsTuple(@TypeOf(func)),
    ) !task_mod.JoinHandle {
        const h = try self.runtime.spawn(opts, func, args);
        try self.children.append(self.allocator, h);
        return h;
    }

    pub fn cancel(self: *Scope) void {
        self.token.cancel();
        trace.emit(.cancel, 1);
    }

    pub fn joinAll(self: *Scope) void {
        if (self.cancel_on_leave) {
            self.token.cancel();
        }
        while (true) {
            var any_alive = false;
            for (self.children.items) |h| {
                if (!h.isDone()) {
                    any_alive = true;
                    break;
                }
            }
            if (!any_alive) break;

            if (task_mod.current()) |cur| {
                if (cur.executor) |ex| {
                    ex.yieldFromRunning();
                    continue;
                }
            }
            std.Thread.yield() catch {};
            _ = self.runtime.timers.fireExpired();
        }
        self.children.clearRetainingCapacity();
    }

    pub fn isDone(self: *const Scope) bool {
        for (self.children.items) |h| {
            if (!h.isDone()) return false;
        }
        return true;
    }
};

pub const NurseryOpts = struct {
    deadline_ns: ?i128 = null,
    timeout_ns: ?u64 = null,
    cancel_on_leave: bool = true,
    cancel_on_first_done: bool = false,
};

pub const Nursery = struct {
    scope: Scope,
    deadline_ns: ?i128 = null,
    cancel_on_first_done: bool = false,

    pub fn init(runtime: *runtime_mod.Runtime, opts: NurseryOpts) Nursery {
        var n = Nursery{
            .scope = Scope.init(runtime),
            .cancel_on_first_done = opts.cancel_on_first_done,
        };
        n.scope.cancel_on_leave = opts.cancel_on_leave;
        if (opts.deadline_ns) |d| {
            n.deadline_ns = d;
        } else if (opts.timeout_ns) |t| {
            n.deadline_ns = timer_mod.nowNs() + @as(i128, @intCast(t));
        }
        return n;
    }

    pub fn deinit(self: *Nursery) void {
        if (self.deadlineExceeded()) {
            self.scope.cancel();
        }
        self.scope.deinit();
        self.* = undefined;
    }

    pub fn token(self: *Nursery) *cancel_mod.CancelToken {
        return &self.scope.token;
    }

    pub fn spawn(
        self: *Nursery,
        opts: task_mod.SpawnOptions,
        comptime func: anytype,
        args: std.meta.ArgsTuple(@TypeOf(func)),
    ) !task_mod.JoinHandle {
        if (self.deadlineExceeded()) {
            self.scope.cancel();
            return error.Canceled;
        }
        return self.scope.spawn(opts, func, args);
    }

    pub fn cancel(self: *Nursery) void {
        self.scope.cancel();
    }

    pub fn deadlineExceeded(self: *const Nursery) bool {
        if (self.deadline_ns) |d| {
            return timer_mod.nowNs() >= d;
        }
        return false;
    }

    pub fn join(self: *Nursery) error{ Timeout, Canceled }!void {
        while (true) {
            if (self.scope.token.isCanceled()) {
                self.scope.cancel_on_leave = true;
                self.scope.joinAll();
                return error.Canceled;
            }
            if (self.deadlineExceeded()) {
                self.scope.cancel();
                self.scope.joinAll();
                return error.Timeout;
            }
            if (self.scope.isDone()) {
                self.scope.children.clearRetainingCapacity();
                return;
            }

            if (self.cancel_on_first_done) {
                var any_done = false;
                var any_alive = false;
                for (self.scope.children.items) |h| {
                    if (h.isDone()) any_done = true else any_alive = true;
                }
                if (any_done and any_alive) {
                    self.scope.cancel();
                }
            }

            if (task_mod.current()) |cur| {
                if (cur.executor) |ex| {
                    ex.yieldFromRunning();
                    continue;
                }
            }
            std.Thread.yield() catch {};
            _ = self.scope.runtime.timers.fireExpired();
        }
    }

    pub fn tryJoin(self: *Nursery, timeout_ns: u64) error{ Timeout, Canceled }!void {
        const local_deadline = timer_mod.nowNs() + @as(i128, @intCast(timeout_ns));
        while (true) {
            if (self.scope.token.isCanceled()) {
                self.scope.cancel();
                self.scope.joinAll();
                return error.Canceled;
            }
            if (self.deadlineExceeded() or timer_mod.nowNs() >= local_deadline) {
                self.scope.cancel();
                self.scope.joinAll();
                return error.Timeout;
            }
            if (self.scope.isDone()) {
                self.scope.children.clearRetainingCapacity();
                return;
            }
            if (task_mod.current()) |cur| {
                if (cur.executor) |ex| {
                    ex.yieldFromRunning();
                    continue;
                }
            }
            std.Thread.yield() catch {};
            _ = self.scope.runtime.timers.fireExpired();
        }
    }

    pub fn joinAll(self: *Nursery) void {
        self.scope.joinAll();
    }
};
