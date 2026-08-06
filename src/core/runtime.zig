const std = @import("std");
const stack_mod = @import("../stack/stack.zig");
const fifo_mod = @import("../scheduler/fifo_scheduler.zig");
const ws_mod = @import("../scheduler/work_stealing_scheduler.zig");
const prio_mod = @import("../scheduler/priority_scheduler.zig");
const tpt_mod = @import("../scheduler/thread_per_task_scheduler.zig");
const task_mod = @import("task.zig");
const context_mod = @import("../context/context.zig");
const executor_mod = @import("executor.zig");
const timer_mod = @import("timer_queue.zig");
const io_backend = @import("../io/io_backend.zig");
const reactor_mod = @import("../io/poll_reactor.zig");
const iocp_mod = @import("../io/iocp_backend.zig");
const iouring_mod = @import("../io/io_uring_backend.zig");
const metrics_mod = @import("metrics.zig");
const preempt = @import("preemption.zig");
const trace = @import("tracing.zig");

pub const SchedulerPolicy = enum {
    auto,
    single_thread_fifo,
    work_stealing,
    priority,
    thread_per_task,
};

pub const Config = struct {
    workers: u32 = 1,
    policy: SchedulerPolicy = .auto,
    default_stack_size: usize = stack_mod.default_stack_size,
    stack_pool: bool = true,
    stack_guard_page: bool = false,
    stack_paint_canary: bool = false,
    io: IoConfig = .none,
    metrics: bool = false,
    preempt: preempt.Config = .{},

    pub const IoConfig = enum {
        none,
        poll,
        iocp,
        io_uring,
    };
};

const SchedBackend = union(enum) {
    fifo: fifo_mod.FifoScheduler,
    work_stealing: ws_mod.WorkStealingScheduler,
    priority: prio_mod.PriorityScheduler,
    thread_per_task: tpt_mod.ThreadPerTaskScheduler,
};

threadlocal var tls_runtime: ?*Runtime = null;

pub fn currentRuntime() ?*Runtime {
    return tls_runtime;
}

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    config: Config,
    backend: SchedBackend,
    pool: ?stack_mod.Pool,
    worker_count: u32,
    timers: timer_mod.TimerQueue,
    io: ?io_backend.Backend = null,
    owned_reactor: ?*reactor_mod.Reactor = null,
    owned_iocp: ?*iocp_mod.IocpBackend = null,
    owned_iouring: ?*iouring_mod.IoUringBackend = null,
    metrics: metrics_mod.Metrics = .{},

    pub fn init(allocator: std.mem.Allocator, config: Config) !Runtime {
        if (comptime !context_mod.supported) {
            return error.UnsupportedTarget;
        }

        const cpu_count: u32 = @intCast(@max(std.Thread.getCpuCount() catch 1, 1));
        var workers: u32 = if (config.workers == 0) cpu_count else config.workers;

        const policy: SchedulerPolicy = switch (config.policy) {
            .auto => if (workers <= 1) .single_thread_fifo else .work_stealing,
            else => |p| p,
        };

        if (policy == .priority or policy == .single_thread_fifo) {
            workers = 1;
        }
        if (policy == .thread_per_task) {
            workers = 0; // N threads = N tasks
        }
        if (policy == .work_stealing and workers < 2) {
            workers = cpu_count;
        }

        var pool: ?stack_mod.Pool = null;
        if (config.stack_pool) {
            pool = stack_mod.Pool.initWith(allocator, .{
                .guard_page = config.stack_guard_page,
                .paint_canary = config.stack_paint_canary,
            });
        }

        const backend: SchedBackend = switch (policy) {
            .auto, .single_thread_fifo => .{ .fifo = fifo_mod.FifoScheduler.init(allocator) },
            .work_stealing => blk: {
                var ws = try ws_mod.WorkStealingScheduler.init(allocator, workers);
                ws.bind();
                break :blk .{ .work_stealing = ws };
            },
            .priority => .{ .priority = prio_mod.PriorityScheduler.init(allocator) },
            .thread_per_task => .{ .thread_per_task = tpt_mod.ThreadPerTaskScheduler.init(allocator) },
        };

        var owned_reactor: ?*reactor_mod.Reactor = null;
        var owned_iocp: ?*iocp_mod.IocpBackend = null;
        var owned_iouring: ?*iouring_mod.IoUringBackend = null;
        var io: ?io_backend.Backend = null;

        switch (config.io) {
            .none => {},
            .poll => {
                const r = try reactor_mod.Reactor.create(allocator);
                owned_reactor = r;
                io = r.asBackend();
            },
            .iocp => {
                const b = try iocp_mod.IocpBackend.create(allocator);
                owned_iocp = b;
                io = b.backend();
            },
            .io_uring => {
                const b = try iouring_mod.IoUringBackend.create(allocator);
                owned_iouring = b;
                io = b.backend();
            },
        }

        return .{
            .allocator = allocator,
            .config = config,
            .backend = backend,
            .pool = pool,
            .worker_count = if (policy == .thread_per_task) 0 else if (workers <= 1) 1 else workers,
            .timers = timer_mod.TimerQueue.init(allocator),
            .io = io,
            .owned_reactor = owned_reactor,
            .owned_iocp = owned_iocp,
            .owned_iouring = owned_iouring,
            .metrics = metrics_mod.Metrics.init(config.metrics),
        };
    }

    pub fn setIoBackend(self: *Runtime, b: io_backend.Backend) void {
        if (self.owned_reactor) |r| {
            r.destroy();
            self.owned_reactor = null;
        }
        if (self.owned_iocp) |x| {
            x.destroy();
            self.owned_iocp = null;
        }
        if (self.owned_iouring) |x| {
            x.destroy();
            self.owned_iouring = null;
        }
        self.io = b;
        self.bindIo();
    }

    fn bindShared(self: *Runtime) void {
        switch (self.backend) {
            .fifo => |*f| {
                f.timers = &self.timers;
                f.io = self.io;
                f.metrics = &self.metrics;
            },
            .work_stealing => |*ws| {
                ws.timers = &self.timers;
                ws.io = self.io;
                ws.metrics = &self.metrics;
            },
            .priority => |*p| {
                p.timers = &self.timers;
                p.io = self.io;
                p.metrics = &self.metrics;
            },
            .thread_per_task => |*t| {
                t.timers = &self.timers;
                t.io = self.io;
                t.metrics = &self.metrics;
            },
        }
    }

    fn bindTimers(self: *Runtime) void {
        self.bindShared();
    }

    fn bindIo(self: *Runtime) void {
        self.bindShared();
    }

    pub fn deinit(self: *Runtime) void {
        switch (self.backend) {
            .fifo => |*f| f.deinit(),
            .work_stealing => |*ws| ws.deinit(),
            .priority => |*p| p.deinit(),
            .thread_per_task => |*t| t.deinit(),
        }
        if (self.owned_reactor) |r| {
            r.destroy();
            self.owned_reactor = null;
        }
        if (self.owned_iocp) |x| {
            x.destroy();
            self.owned_iocp = null;
        }
        if (self.owned_iouring) |x| {
            x.destroy();
            self.owned_iouring = null;
        }
        self.io = null;
        self.timers.deinit();
        if (self.pool) |*p| {
            p.drain();
            p.deinit();
        }
        self.* = undefined;
    }

    pub fn executor(self: *Runtime) executor_mod.Executor {
        return switch (self.backend) {
            .fifo => |*f| f.executor(),
            .work_stealing => |*ws| ws.executor(),
            .priority => |*p| p.executor(),
            .thread_per_task => |*t| t.executor(),
        };
    }

    pub fn ioBackend(self: *Runtime) ?io_backend.Backend {
        return self.io;
    }

    pub fn spawn(
        self: *Runtime,
        opts: task_mod.SpawnOptions,
        comptime func: anytype,
        args: std.meta.ArgsTuple(@TypeOf(func)),
    ) !task_mod.JoinHandle {
        var spawn_opts = opts;
        if (spawn_opts.stack_size == stack_mod.default_stack_size) {
            spawn_opts.stack_size = self.config.default_stack_size;
        }
        if (self.config.stack_guard_page) spawn_opts.guard_page = true;
        if (self.config.stack_paint_canary) spawn_opts.paint_canary = true;

        const pool_ptr: ?*stack_mod.Pool = if (self.pool) |*p| p else null;
        const ex = self.executor();

        switch (self.backend) {
            .fifo => |*f| f.noteSpawn(),
            .work_stealing => |*ws| ws.noteSpawn(),
            .priority => |*p| p.noteSpawn(),
            .thread_per_task => |*t| t.noteSpawn(),
        }
        self.metrics.inc(.spawns);
        trace.emit(.task_spawn, 0);

        return task_mod.spawnOn(ex, self.allocator, pool_ptr, spawn_opts, func, args);
    }

    pub fn spawnResult(
        self: *Runtime,
        opts: task_mod.SpawnOptions,
        comptime func: anytype,
        args: std.meta.ArgsTuple(@TypeOf(func)),
    ) !task_mod.TypedJoinHandle(task_mod.ResultTypeOfPublic(func)) {
        var spawn_opts = opts;
        if (spawn_opts.stack_size == stack_mod.default_stack_size) {
            spawn_opts.stack_size = self.config.default_stack_size;
        }
        if (self.config.stack_guard_page) spawn_opts.guard_page = true;
        if (self.config.stack_paint_canary) spawn_opts.paint_canary = true;

        const pool_ptr: ?*stack_mod.Pool = if (self.pool) |*p| p else null;
        const ex = self.executor();

        switch (self.backend) {
            .fifo => |*f| f.noteSpawn(),
            .work_stealing => |*ws| ws.noteSpawn(),
            .priority => |*p| p.noteSpawn(),
            .thread_per_task => |*t| t.noteSpawn(),
        }
        self.metrics.inc(.spawns);
        trace.emit(.task_spawn, 1);

        return task_mod.spawnOnResult(ex, self.allocator, pool_ptr, spawn_opts, func, args);
    }

    pub fn run(self: *Runtime) !void {
        self.bindShared();
        preempt.bind(self.config.preempt);
        const prev = tls_runtime;
        tls_runtime = self;
        defer tls_runtime = prev;

        switch (self.backend) {
            .fifo => |*f| f.run(),
            .work_stealing => |*ws| try ws.run(),
            .priority => |*p| p.run(),
            .thread_per_task => |*t| try t.run(),
        }
    }

    pub fn metricsSnapshot(self: *const Runtime) metrics_mod.Metrics.Snapshot {
        return self.metrics.snapshot();
    }

    pub fn yield(self: *Runtime) void {
        _ = self;
        task_mod.yield();
    }

    pub fn sleep(self: *Runtime, duration_ns: u64) void {
        self.bindTimers();
        self.timers.sleep(duration_ns);
    }
};

pub fn sleep(duration_ns: u64) void {
    const rt = tls_runtime orelse @panic("zigroutines: sleep without current runtime");
    rt.sleep(duration_ns);
}
