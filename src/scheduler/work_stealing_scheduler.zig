const std = @import("std");
const task_mod = @import("../core/task.zig");
const context = @import("../context/context.zig");
const executor_mod = @import("../core/executor.zig");
const timer_mod = @import("../core/timer_queue.zig");
const io_backend = @import("../io/io_backend.zig");
const metrics_mod = @import("../core/metrics.zig");
const chase = @import("../utils/chase_lev.zig");
const ring = @import("../utils/ring_queue.zig");
const wake_util = @import("../utils/worker_wake.zig");
const sync = @import("../core/synchronization.zig");

const Task = task_mod.Task;
const Deque = chase.ChaseLevDeque(*Task);

threadlocal var tls_worker: ?*Worker = null;

pub const Worker = struct {
    id: u32 = 0,
    engine: *WorkStealingScheduler = undefined,
    local: Deque = undefined,
    sched_ctx: context.Context = .{},
    running: ?*Task = null,
    dead: std.ArrayListUnmanaged(*Task) = .empty,
    thread: ?std.Thread = null,
    wake: wake_util.WorkerWake = .{},
};

pub const WorkStealingScheduler = struct {
    allocator: std.mem.Allocator,
    workers: []Worker,
    inject: ring.RingQueue(*Task),
    inject_lock: sync.SpinLock = .{},
    stop: std.atomic.Value(bool) = .init(false),
    live_tasks: std.atomic.Value(usize) = .init(0),
    timers: ?*timer_mod.TimerQueue = null,
    io: ?io_backend.Backend = null,
    metrics: ?*metrics_mod.Metrics = null,

    pub fn init(allocator: std.mem.Allocator, worker_count: u32) !WorkStealingScheduler {
        const n = @max(worker_count, 1);
        const workers = try allocator.alloc(Worker, n);
        errdefer allocator.free(workers);
        for (workers, 0..) |*w, i| {
            w.* = .{
                .id = @intCast(i),
                .local = try Deque.init(allocator),
            };
        }
        return .{
            .allocator = allocator,
            .workers = workers,
            .inject = ring.RingQueue(*Task).init(allocator),
        };
    }

    pub fn bind(self: *WorkStealingScheduler) void {
        for (self.workers) |*w| w.engine = self;
    }

    pub fn deinit(self: *WorkStealingScheduler) void {
        self.stop.store(true, .release);
        for (self.workers) |*w| {
            w.wake.signalAll();
            if (w.thread) |th| {
                th.join();
                w.thread = null;
            }
        }
        for (self.workers) |*w| {
            while (w.local.pop()) |t| t.destroy();
            w.local.deinit();
            for (w.dead.items) |t| t.destroy();
            w.dead.deinit(self.allocator);
        }
        self.allocator.free(self.workers);
        while (self.inject.pop()) |t| t.destroy();
        self.inject.deinit();
        self.* = undefined;
    }

    pub fn executor(self: *WorkStealingScheduler) executor_mod.Executor {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = executor_mod.Executor.VTable{
        .enqueue = enqueueV,
        .yieldFromRunning = yieldV,
        .parkFromRunning = parkV,
        .finishFromRunning = finishV,
    };

    fn enqueueV(ptr: *anyopaque, t: *Task) anyerror!void {
        const self: *WorkStealingScheduler = @ptrCast(@alignCast(ptr));
        return self.enqueue(t);
    }
    fn yieldV(ptr: *anyopaque) void {
        const self: *WorkStealingScheduler = @ptrCast(@alignCast(ptr));
        self.yieldFromRunning();
    }
    fn parkV(ptr: *anyopaque, reason: task_mod.WaitReason) void {
        const self: *WorkStealingScheduler = @ptrCast(@alignCast(ptr));
        self.parkFromRunning(reason);
    }
    fn finishV(ptr: *anyopaque) void {
        const self: *WorkStealingScheduler = @ptrCast(@alignCast(ptr));
        self.finishFromRunning();
    }

    pub fn noteSpawn(self: *WorkStealingScheduler) void {
        _ = self.live_tasks.fetchAdd(1, .monotonic);
    }

    pub fn enqueue(self: *WorkStealingScheduler, t: *Task) !void {
        if (t.scheduled.swap(true, .acq_rel)) return;
        if (t.state == .dead or t.state == .canceled) {
            t.scheduled.store(false, .release);
            return;
        }
        t.state = .ready;
        if (t.blocked_on != .none) t.blocked_on = .none;
        if (tls_worker) |w| {
            try w.local.push(t);
            return;
        }
        self.inject_lock.lock();
        defer self.inject_lock.unlock();
        try self.inject.push(t);
        for (self.workers) |*w| w.wake.signal();
    }

    pub fn run(self: *WorkStealingScheduler) !void {
        self.bind();
        if (self.workers.len > 1) {
            var i: u32 = 1;
            while (i < self.workers.len) : (i += 1) {
                const w = &self.workers[i];
                w.thread = try std.Thread.spawn(.{}, workerMain, .{w});
            }
        }
        workerMain(&self.workers[0]);
        var i: usize = 1;
        while (i < self.workers.len) : (i += 1) {
            self.workers[i].wake.signalAll();
            if (self.workers[i].thread) |th| {
                th.join();
                self.workers[i].thread = null;
            }
        }
    }

    fn workerMain(w: *Worker) void {
        tls_worker = w;
        defer tls_worker = null;
        const engine = w.engine;
        var idle_spins: u32 = 0;
        while (!engine.stop.load(.acquire)) {
            if (engine.timers) |tq| _ = tq.fireExpired();
            if (w.local.pop() orelse engine.popInject() orelse engine.steal(w.id)) |t| {
                idle_spins = 0;
                w.running = t;
                t.scheduled.store(false, .release);
                t.state = .running;
                t.on_cpu.store(true, .release);
                task_mod.setCurrent(t);
                if (t.isLeaf()) {
                    task_mod.runLeafOnWorker(t);
                    task_mod.setCurrent(null);
                    t.on_cpu.store(false, .release);
                    t.state = .dead;
                    t.finished.store(true, .release);
                    t.finishJoiners();
                    _ = engine.live_tasks.fetchSub(1, .monotonic);
                    if (engine.metrics) |m| m.inc(.finishes);
                    t.destroy();
                    w.running = null;
                    continue;
                }
                context.swap(&w.sched_ctx, &t.ctx);
                task_mod.setCurrent(null);
                t.on_cpu.store(false, .release);
                w.running = null;
                if (task_mod.takeBounceAndRun(t)) {
                    engine.enqueue(t) catch @panic("zigroutines: OOM requeue after bounce");
                }
                continue;
            }
            if (engine.live_tasks.load(.acquire) == 0) {
                engine.stop.store(true, .release);
                for (engine.workers) |*ow| ow.wake.signalAll();
                break;
            }
            idle_spins +%= 1;
            if (engine.io) |bio| {
                _ = bio.poll(1 * std.time.ns_per_ms) catch 0;
            } else if (idle_spins < 64) {
                std.atomic.spinLoopHint();
            } else if (idle_spins < 256) {
                std.Thread.yield() catch {};
            } else {
                w.wake.wait(2 * std.time.ns_per_ms);
                idle_spins = 0;
            }
        }
    }

    fn popInject(self: *WorkStealingScheduler) ?*Task {
        self.inject_lock.lock();
        defer self.inject_lock.unlock();
        return self.inject.pop();
    }

    fn steal(self: *WorkStealingScheduler, thief_id: u32) ?*Task {
        const n = self.workers.len;
        var i: usize = 1;
        while (i < n) : (i += 1) {
            const victim = &self.workers[(thief_id + i) % n];
            if (victim.local.steal()) |t| {
                if (self.metrics) |m| m.inc(.steals);
                return t;
            }
        }
        return null;
    }

    pub fn yieldFromRunning(self: *WorkStealingScheduler) void {
        const w = tls_worker orelse @panic("zigroutines: yield outside worker");
        const t = w.running orelse @panic("zigroutines: yield with no running task");
        if (self.metrics) |m| m.inc(.yields);
        t.state = .ready;
        t.scheduled.store(true, .release);
        w.local.push(t) catch @panic("zigroutines: OOM yield");
        context.swap(&t.ctx, &w.sched_ctx);
    }

    pub fn parkFromRunning(self: *WorkStealingScheduler, reason: task_mod.WaitReason) void {
        const w = tls_worker orelse @panic("zigroutines: park outside worker");
        const t = w.running orelse @panic("zigroutines: park with no running task");
        task_mod.requireStackfulForPark();
        t.state = .blocked;
        t.blocked_on = reason;
        t.scheduled.store(false, .release);
        if (self.metrics) |m| m.inc(.parks);
        context.swap(&t.ctx, &w.sched_ctx);
    }

    pub fn finishFromRunning(self: *WorkStealingScheduler) void {
        const w = tls_worker orelse @panic("zigroutines: finish outside worker");
        const t = w.running orelse @panic("zigroutines: finish with no running task");
        t.state = .dead;
        t.finished.store(true, .release);
        t.finishJoiners();
        _ = self.live_tasks.fetchSub(1, .monotonic);
        if (self.metrics) |m| m.inc(.finishes);
        const t_ctx = &t.ctx;
        w.dead.append(self.allocator, t) catch @panic("zigroutines: OOM finish");
        for (self.workers) |*ow| {
            if (ow != w) ow.wake.signal();
        }
        context.swap(t_ctx, &w.sched_ctx);
    }
};
