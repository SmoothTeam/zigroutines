// SPDX-FileCopyrightText: 2026 Apanazar
//
// SPDX-License-Identifier: LGPL-3.0-or-later

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
const runtime_mod = @import("../core/runtime.zig");

const Task = task_mod.Task;
const Deque = chase.ChaseLevDeque(*Task);
const no_poller: u32 = std.math.maxInt(u32);

threadlocal var tls_worker: ?*Worker = null;

pub const Worker = struct {
    id: u32 = 0,
    engine: *WorkStealingScheduler = undefined,
    local: Deque = undefined,
    sched_ctx: context.Context = .{},
    running: ?*Task = null,
    handoff_cont: ?*Task = null,
    dead: std.ArrayListUnmanaged(*Task) = .empty,
    thread: ?std.Thread = null,
    wake: wake_util.WorkerWake = .{},

    fn takeHandoff(self: *Worker) ?*Task {
        const t = self.handoff_cont orelse return null;
        self.handoff_cont = t.requeue_next;
        t.requeue_next = null;
        return t;
    }

    fn collectFinishedVoid(self: *Worker) void {
        var i: usize = 0;
        while (i < self.dead.items.len) {
            const t = self.dead.items[i];
            if (t.recycled) {
                _ = self.dead.orderedRemove(i);
                continue;
            }
            if (t.result_slot == null) {
                _ = self.dead.orderedRemove(i);
                t.destroy();
            } else {
                i += 1;
            }
        }
    }
};

pub const WorkStealingScheduler = struct {
    allocator: std.mem.Allocator,
    workers: []Worker,
    inject: ring.RingQueue(*Task),
    inject_lock: sync.SpinLock = .{},
    next_wake: std.atomic.Value(u32) = .init(0),
    stop: std.atomic.Value(bool) = .init(false),
    live_tasks: std.atomic.Value(usize) = .init(0),
    timers: ?*timer_mod.TimerQueue = null,
    io: ?io_backend.Backend = null,
    metrics: ?*metrics_mod.Metrics = null,
    runtime: ?*runtime_mod.Runtime = null,
    poller: std.atomic.Value(u32) = .init(no_poller),

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
        .handoffFromRunning = handoffV,
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
    fn handoffV(ptr: *anyopaque, next: *Task) bool {
        const self: *WorkStealingScheduler = @ptrCast(@alignCast(ptr));
        return self.handoffFromRunning(next);
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
            self.signalOne();
            return;
        }
        self.inject_lock.lock();
        defer self.inject_lock.unlock();
        try self.inject.push(t);
        self.signalOne();
    }

    fn signalOne(self: *WorkStealingScheduler) void {
        const n = self.workers.len;
        if (n == 0) return;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const w = &self.workers[i];
            if (w.wake.waiting.load(.monotonic) > 0) {
                w.wake.signal();
                return;
            }
        }
        const idx = self.next_wake.fetchAdd(1, .monotonic) % n;
        self.workers[idx].wake.signal();
    }

    pub fn run(self: *WorkStealingScheduler) !void {
        self.stop.store(false, .release);
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
        const prev_rt = if (w.engine.runtime) |rt| runtime_mod.enter(rt) else null;
        defer {
            runtime_mod.leave(prev_rt);
            task_mod.flushTlsTaskCache(w.engine.allocator);
            tls_worker = null;
        }
        const engine = w.engine;
        while (!engine.stop.load(.acquire)) {
            if (engine.timers) |tq| {
                if (tq.hasDue()) _ = tq.fireExpired();
            }
            if (w.takeHandoff() orelse w.local.pop() orelse engine.popInject() orelse engine.steal(w.id)) |t| {
                if (w.handoff_cont == null and !w.local.isEmptyApprox()) engine.signalOne();
                if (t.on_cpu.load(.acquire)) task_mod.waitUntilOffCpu(t);
                var again: ?*Task = t;
                while (again) |cur| {
                    if (cur.on_cpu.load(.acquire)) task_mod.waitUntilOffCpu(cur);
                    w.running = cur;
                    cur.home_worker = w.id;
                    cur.scheduled.store(false, .release);
                    cur.state = .running;
                    cur.on_cpu.store(true, .release);
                    task_mod.setCurrent(cur);
                    if (cur.isLeaf()) {
                        task_mod.runLeafOnWorker(cur);
                        task_mod.setCurrent(null);
                        cur.on_cpu.store(false, .release);
                        cur.state = .dead;
                        cur.finished.store(true, .release);
                        cur.finishJoiners();
                        _ = engine.live_tasks.fetchSub(1, .monotonic);
                        if (engine.metrics) |m| m.inc(.finishes);
                        cur.destroy();
                        w.running = null;
                        again = null;
                        break;
                    }
                    context.swap(&w.sched_ctx, cur.ctxPtr());
                    task_mod.setCurrent(null);
                    if (w.running) |r| {
                        r.on_cpu.store(false, .release);
                        w.running = null;
                    }
                    var bounced: ?*Task = null;
                    if (task_mod.takePendingBounce()) |b| {
                        if (task_mod.takeBounceAndRun(b)) bounced = b;
                    } else if (task_mod.takeBounceAndRun(cur)) {
                        bounced = cur;
                    }
                    if (bounced) |b| {
                        if (w.local.isEmptyApprox() and w.handoff_cont == null) {
                            again = b;
                        } else {
                            engine.enqueue(b) catch @panic("zigroutines: OOM requeue after bounce");
                            again = null;
                        }
                    } else {
                        again = null;
                    }
                }
                w.collectFinishedVoid();
                continue;
            }
            if (engine.live_tasks.load(.acquire) == 0) {
                engine.stop.store(true, .release);
                for (engine.workers) |*ow| ow.wake.signalAll();
                break;
            }
            engine.idlePark(w);
        }
    }

    fn idleTimeoutNs(self: *WorkStealingScheduler) u64 {
        const cap: u64 = 10 * std.time.ns_per_ms;
        if (self.timers) |tq| {
            if (tq.nextDeadlineNs()) |deadline| {
                const now = timer_mod.nowNs();
                if (deadline <= now) return 0;
                return @intCast(@min(@as(u64, @intCast(deadline - now)), cap));
            }
        }
        return cap;
    }

    fn tryBecomePoller(self: *WorkStealingScheduler, id: u32) bool {
        return self.poller.cmpxchgStrong(no_poller, id, .acquire, .monotonic) == null;
    }

    fn releasePoller(self: *WorkStealingScheduler, id: u32) void {
        _ = self.poller.cmpxchgStrong(id, no_poller, .release, .monotonic);
    }

    fn idlePark(self: *WorkStealingScheduler, w: *Worker) void {
        const timeout_ns = self.idleTimeoutNs();
        if (self.io) |bio| {
            if (self.tryBecomePoller(w.id)) {
                defer self.releasePoller(w.id);
                if (timeout_ns == 0) {
                    _ = bio.poll(0) catch 0;
                } else {
                    _ = bio.poll(timeout_ns) catch 0;
                }
                return;
            }
        }
        if (timeout_ns == 0) return;
        w.wake.wait(timeout_ns);
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

    pub fn handoffFromRunning(self: *WorkStealingScheduler, next: *Task) bool {
        _ = self;
        const w = tls_worker orelse return false;
        const t = w.running orelse return false;
        if (next == t) return false;
        if (next.state == .dead or next.state == .canceled) return false;
        if (next.isLeaf()) return false;
        if (next.on_cpu.load(.acquire)) return false;
        if (next.scheduled.swap(true, .acq_rel)) return false;

        t.checkProtect();
        t.state = .ready;
        t.scheduled.store(true, .release);
        t.requeue_next = w.handoff_cont;
        w.handoff_cont = t;

        w.running = next;
        next.home_worker = w.id;
        next.scheduled.store(false, .release);
        next.state = .running;
        if (next.blocked_on != .none) next.blocked_on = .none;
        next.on_cpu.store(true, .release);
        task_mod.setCurrent(next);
        t.on_cpu.store(false, .release);
        context.swap(t.ctxPtr(), next.ctxPtr());
        w.running = t;
        t.on_cpu.store(true, .release);
        t.state = .running;
        t.scheduled.store(false, .release);
        task_mod.setCurrent(t);
        return true;
    }

    pub fn yieldFromRunning(self: *WorkStealingScheduler) void {
        const w = tls_worker orelse @panic("zigroutines: yield outside worker");
        const t = w.running orelse @panic("zigroutines: yield with no running task");
        t.checkProtect();
        if (self.metrics) |m| m.inc(.yields);
        t.state = .ready;
        t.scheduled.store(true, .release);
        w.local.push(t) catch @panic("zigroutines: OOM yield");

        if (w.local.pop()) |next| {
            if (next == t) {
                t.scheduled.store(false, .release);
                t.state = .running;
                return;
            }
            if (!next.isLeaf()) {
                w.running = next;
                next.home_worker = w.id;
                next.scheduled.store(false, .release);
                next.state = .running;
                next.on_cpu.store(true, .release);
                task_mod.setCurrent(next);
                t.on_cpu.store(false, .release);
                context.swap(t.ctxPtr(), next.ctxPtr());
                w.running = t;
                t.on_cpu.store(true, .release);
                task_mod.setCurrent(t);
                return;
            }
            w.local.push(next) catch @panic("zigroutines: OOM yield");
        }

        w.running = null;
        t.on_cpu.store(false, .release);
        context.swap(t.ctxPtr(), &w.sched_ctx);
    }

    pub fn parkFromRunning(self: *WorkStealingScheduler, reason: task_mod.WaitReason) void {
        const w = tls_worker orelse @panic("zigroutines: park outside worker");
        const t = w.running orelse @panic("zigroutines: park with no running task");
        t.checkProtect();
        task_mod.requireStackfulForPark();
        t.state = .blocked;
        t.blocked_on = reason;
        t.scheduled.store(false, .release);
        if (self.metrics) |m| m.inc(.parks);
        if (reason == .worker_bounce) task_mod.noteBounce(t);
        w.running = null;
        t.on_cpu.store(false, .release);
        context.swap(t.ctxPtr(), &w.sched_ctx);
    }

    pub fn finishFromRunning(self: *WorkStealingScheduler) void {
        const w = tls_worker orelse @panic("zigroutines: finish outside worker");
        const t = w.running orelse @panic("zigroutines: finish with no running task");
        t.checkProtect();
        t.state = .dead;
        t.finished.store(true, .release);
        t.finishJoiners();
        _ = self.live_tasks.fetchSub(1, .monotonic);
        if (self.metrics) |m| m.inc(.finishes);
        const t_ctx = t.ctxPtr();
        w.dead.append(self.allocator, t) catch @panic("zigroutines: OOM finish");
        self.signalOne();
        w.running = null;
        t.on_cpu.store(false, .release);
        context.swap(t_ctx, &w.sched_ctx);
    }
};
