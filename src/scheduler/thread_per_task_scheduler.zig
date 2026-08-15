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
const sync = @import("../core/synchronization.zig");
const trace = @import("../core/tracing.zig");
const runtime_mod = @import("../core/runtime.zig");

const Task = task_mod.Task;

const ThreadSlot = struct {
    thread: ?std.Thread = null,
    task: *Task = undefined,
    sched: *ThreadPerTaskScheduler = undefined,
    sched_ctx: context.Context = .{},
};

pub const ThreadPerTaskScheduler = struct {
    allocator: std.mem.Allocator,
    lock: sync.SpinLock = .{},
    live: std.atomic.Value(usize) = .init(0),
    finished_count: std.atomic.Value(usize) = .init(0),
    dead: std.ArrayListUnmanaged(*Task) = .empty,
    slots: std.ArrayListUnmanaged(*ThreadSlot) = .empty,
    timers: ?*timer_mod.TimerQueue = null,
    io: ?io_backend.Backend = null,
    metrics: ?*metrics_mod.Metrics = null,
    runtime: ?*runtime_mod.Runtime = null,
    stopped: std.atomic.Value(bool) = .init(false),

    pub fn init(allocator: std.mem.Allocator) ThreadPerTaskScheduler {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ThreadPerTaskScheduler) void {
        self.stopped.store(true, .release);
        self.lock.lock();
        const slots = self.slots.items;
        self.lock.unlock();
        for (slots) |slot| {
            if (slot.thread) |th| {
                th.join();
                slot.thread = null;
            }
        }
        self.lock.lock();
        for (self.slots.items) |slot| {
            self.allocator.destroy(slot);
        }
        self.slots.deinit(self.allocator);
        for (self.dead.items) |t| t.destroy();
        self.dead.deinit(self.allocator);
        self.lock.unlock();
        self.* = undefined;
    }

    pub fn executor(self: *ThreadPerTaskScheduler) executor_mod.Executor {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = executor_mod.Executor.VTable{
        .enqueue = enqueueV,
        .yieldFromRunning = yieldV,
        .parkFromRunning = parkV,
        .finishFromRunning = finishV,
    };

    fn enqueueV(ptr: *anyopaque, t: *Task) anyerror!void {
        const self: *ThreadPerTaskScheduler = @ptrCast(@alignCast(ptr));
        return self.enqueue(t);
    }
    fn yieldV(ptr: *anyopaque) void {
        const self: *ThreadPerTaskScheduler = @ptrCast(@alignCast(ptr));
        self.yieldFromRunning();
    }
    fn parkV(ptr: *anyopaque, reason: task_mod.WaitReason) void {
        const self: *ThreadPerTaskScheduler = @ptrCast(@alignCast(ptr));
        self.parkFromRunning(reason);
    }
    fn finishV(ptr: *anyopaque) void {
        const self: *ThreadPerTaskScheduler = @ptrCast(@alignCast(ptr));
        self.finishFromRunning();
    }

    pub fn noteSpawn(self: *ThreadPerTaskScheduler) void {
        _ = self.live.fetchAdd(1, .monotonic);
    }

    pub fn enqueue(self: *ThreadPerTaskScheduler, t: *Task) !void {
        if (t.scheduled.swap(true, .acq_rel)) return;
        if (t.state == .dead or t.state == .canceled) {
            t.scheduled.store(false, .release);
            return;
        }
        t.state = .ready;
        if (t.blocked_on != .none) t.blocked_on = .none;

        if (t.on_cpu.load(.acquire)) {
            t.scheduled.store(false, .release);
            return;
        }

        const slot = try self.allocator.create(ThreadSlot);
        errdefer self.allocator.destroy(slot);
        slot.* = .{
            .task = t,
            .sched = self,
        };

        self.lock.lock();
        try self.slots.append(self.allocator, slot);
        self.lock.unlock();

        const th = try std.Thread.spawn(.{}, threadMain, .{slot});
        slot.thread = th;
    }

    fn threadMain(slot: *ThreadSlot) void {
        tls_slot = slot;
        defer tls_slot = null;
        const self = slot.sched;
        const prev_rt = if (self.runtime) |rt| runtime_mod.enter(rt) else null;
        defer runtime_mod.leave(prev_rt);
        const t = slot.task;
        t.state = .running;
        t.on_cpu.store(true, .release);
        task_mod.setCurrent(t);
        trace.emitTask(.task_start, t, 1);

        while (!t.finished.load(.acquire) and !self.stopped.load(.acquire)) {
            if (t.state == .blocked) {
                while (t.state == .blocked and !t.finished.load(.acquire) and !self.stopped.load(.acquire)) {
                    if (self.timers) |tq| {
                        if (tq.hasDue()) _ = tq.fireExpired();
                    }
                    if (self.io) |bio| _ = bio.poll(0) catch 0;
                    std.Thread.yield() catch {};
                }
                if (t.finished.load(.acquire)) break;
                t.state = .running;
            }
            context.swap(&slot.sched_ctx, t.ctxPtr());
            if (t.finished.load(.acquire)) break;
            if (task_mod.takePendingBounce()) |b| {
                _ = task_mod.takeBounceAndRun(b);
                t.state = .running;
                continue;
            }
            if (t.state == .ready) {
                t.state = .running;
                continue;
            }
            if (t.state == .blocked) {
                continue;
            }
        }
        task_mod.setCurrent(null);
        t.on_cpu.store(false, .release);
    }

    pub fn run(self: *ThreadPerTaskScheduler) !void {
        while (self.live.load(.acquire) > self.finished_count.load(.acquire)) {
            if (self.timers) |tq| {
                if (tq.hasDue()) _ = tq.fireExpired();
            }
            if (self.io) |bio| _ = bio.poll(1 * std.time.ns_per_ms) catch 0;
            std.Thread.yield() catch {};
        }
        self.lock.lock();
        const slots = try self.allocator.alloc(*ThreadSlot, self.slots.items.len);
        @memcpy(slots, self.slots.items);
        self.lock.unlock();
        defer self.allocator.free(slots);
        for (slots) |slot| {
            if (slot.thread) |th| {
                th.join();
                slot.thread = null;
            }
        }
        self.collectFinishedVoid();
    }

    pub fn yieldFromRunning(self: *ThreadPerTaskScheduler) void {
        const t = task_mod.current() orelse @panic("zigroutines: yield with no task");
        t.checkProtect();
        t.state = .ready;
        if (self.metrics) |m| m.inc(.yields);
        const slot = tls_slot orelse @panic("zigroutines: 1:1 yield without slot");
        t.on_cpu.store(false, .release);
        context.swap(t.ctxPtr(), &slot.sched_ctx);
        t.on_cpu.store(true, .release);
    }

    pub fn parkFromRunning(self: *ThreadPerTaskScheduler, reason: task_mod.WaitReason) void {
        const t = task_mod.current() orelse @panic("zigroutines: park with no task");
        t.checkProtect();
        task_mod.requireStackfulForPark();
        t.state = .blocked;
        t.blocked_on = reason;
        if (self.metrics) |m| m.inc(.parks);
        if (reason == .worker_bounce) task_mod.noteBounce(t);
        const slot = tls_slot orelse @panic("zigroutines: 1:1 park without slot");
        t.on_cpu.store(false, .release);
        context.swap(t.ctxPtr(), &slot.sched_ctx);
        t.on_cpu.store(true, .release);
    }

    pub fn finishFromRunning(self: *ThreadPerTaskScheduler) void {
        const t = task_mod.current() orelse @panic("zigroutines: finish with no task");
        t.checkProtect();
        t.state = .dead;
        t.finished.store(true, .release);
        t.finishJoiners();
        _ = self.finished_count.fetchAdd(1, .monotonic);
        if (self.metrics) |m| m.inc(.finishes);
        trace.emitTask(.task_finish, t, 1);
        self.lock.lock();
        self.dead.append(self.allocator, t) catch {};
        self.lock.unlock();
        const slot = tls_slot orelse @panic("zigroutines: 1:1 finish without slot");
        t.on_cpu.store(false, .release);
        task_mod.setCurrent(null);
        context.swap(t.ctxPtr(), &slot.sched_ctx);
        @panic("zigroutines: resumed dead task");
    }

    pub fn collectUnjoined(self: *ThreadPerTaskScheduler) void {
        self.lock.lock();
        defer self.lock.unlock();
        while (self.dead.items.len > 0) {
            const t = self.dead.pop().?;
            t.destroy();
        }
    }

    pub fn collectFinishedVoid(self: *ThreadPerTaskScheduler) void {
        self.lock.lock();
        defer self.lock.unlock();
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

threadlocal var tls_slot: ?*ThreadSlot = null;
