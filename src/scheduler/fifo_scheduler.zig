const std = @import("std");
const task_mod = @import("../core/task.zig");
const context = @import("../context/context.zig");
const executor_mod = @import("../core/executor.zig");
const timer_mod = @import("../core/timer_queue.zig");
const io_backend = @import("../io/io_backend.zig");
const metrics_mod = @import("../core/metrics.zig");
const ring = @import("../utils/ring_queue.zig");

const Task = task_mod.Task;

pub const FifoScheduler = struct {
    allocator: std.mem.Allocator,
    ready: ring.RingQueue(*Task),
    sched_ctx: context.Context = .{},
    running: ?*Task = null,
    stopped: bool = false,
    dead: std.ArrayListUnmanaged(*Task) = .empty,
    live: usize = 0,
    timers: ?*timer_mod.TimerQueue = null,
    io: ?io_backend.Backend = null,
    metrics: ?*metrics_mod.Metrics = null,

    pub fn init(allocator: std.mem.Allocator) FifoScheduler {
        return .{
            .allocator = allocator,
            .ready = ring.RingQueue(*Task).init(allocator),
        };
    }

    pub fn deinit(self: *FifoScheduler) void {
        while (self.ready.pop()) |t| t.destroy();
        self.ready.deinit();
        self.collectUnjoined();
        self.dead.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn executor(self: *FifoScheduler) executor_mod.Executor {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = executor_mod.Executor.VTable{
        .enqueue = enqueueV,
        .yieldFromRunning = yieldV,
        .parkFromRunning = parkV,
        .finishFromRunning = finishV,
    };

    fn enqueueV(ptr: *anyopaque, t: *Task) anyerror!void {
        const self: *FifoScheduler = @ptrCast(@alignCast(ptr));
        return self.enqueue(t);
    }
    fn yieldV(ptr: *anyopaque) void {
        const self: *FifoScheduler = @ptrCast(@alignCast(ptr));
        self.yieldFromRunning();
    }
    fn parkV(ptr: *anyopaque, reason: task_mod.WaitReason) void {
        const self: *FifoScheduler = @ptrCast(@alignCast(ptr));
        self.parkFromRunning(reason);
    }
    fn finishV(ptr: *anyopaque) void {
        const self: *FifoScheduler = @ptrCast(@alignCast(ptr));
        self.finishFromRunning();
    }

    pub fn enqueue(self: *FifoScheduler, t: *Task) !void {
        if (t.scheduled.swap(true, .acq_rel)) return;
        if (t.state == .dead or t.state == .canceled) {
            t.scheduled.store(false, .release);
            return;
        }
        t.state = .ready;
        if (t.blocked_on != .none) t.blocked_on = .none;
        self.ready.push(t) catch |err| {
            t.scheduled.store(false, .release);
            return err;
        };
    }

    pub fn noteSpawn(self: *FifoScheduler) void {
        self.live += 1;
    }

    pub fn run(self: *FifoScheduler) void {
        self.stopped = false;
        while (!self.stopped) {
            if (self.timers) |tq| {
                _ = tq.fireExpired();
            }

            if (self.ready.pop()) |next| {
                self.running = next;
                next.scheduled.store(false, .release);
                next.state = .running;
                next.on_cpu.store(true, .release);
                task_mod.setCurrent(next);
                context.swap(&self.sched_ctx, &next.ctx);
                task_mod.setCurrent(null);
                next.on_cpu.store(false, .release);
                self.running = null;
                continue;
            }

            if (self.live == 0) break;

            const now = timer_mod.nowNs();
            var timeout_ns: u64 = 50 * std.time.ns_per_ms;
            if (self.timers) |tq| {
                if (tq.nextDeadlineNs()) |deadline| {
                    if (deadline <= now) {
                        _ = tq.fireExpired();
                        if (!self.ready.isEmpty()) continue;
                    } else {
                        timeout_ns = @intCast(@min(@as(u64, @intCast(deadline - now)), timeout_ns));
                    }
                }
            }

            if (self.io) |bio| {
                const woke = bio.poll(timeout_ns) catch 0;
                if (self.timers) |tq| _ = tq.fireExpired();
                if (!self.ready.isEmpty() or woke > 0) continue;
                if (self.timers) |tq| {
                    if (tq.nextDeadlineNs() != null) continue;
                }
                std.Thread.yield() catch {};
                continue;
            }

            if (self.timers) |tq| {
                if (tq.nextDeadlineNs()) |deadline| {
                    var guard: u32 = 0;
                    while (timer_mod.nowNs() < deadline and self.ready.isEmpty()) {
                        std.Thread.yield() catch {};
                        guard +%= 1;
                        if (guard > 10_000_000) break;
                    }
                    _ = tq.fireExpired();
                    if (!self.ready.isEmpty() or tq.nextDeadlineNs() != null) continue;
                }
            }
            break;
        }
    }

    pub fn stop(self: *FifoScheduler) void {
        self.stopped = true;
    }

    pub fn yieldFromRunning(self: *FifoScheduler) void {
        const t = self.running orelse @panic("zigroutines: yield with no running task");
        t.state = .ready;
        t.scheduled.store(true, .release);
        self.ready.push(t) catch @panic("zigroutines: OOM on yield enqueue");
        if (self.metrics) |m| m.inc(.yields);
        context.swap(&t.ctx, &self.sched_ctx);
    }

    pub fn parkFromRunning(self: *FifoScheduler, reason: task_mod.WaitReason) void {
        const t = self.running orelse @panic("zigroutines: park with no running task");
        t.state = .blocked;
        t.blocked_on = reason;
        t.scheduled.store(false, .release);
        if (self.metrics) |m| m.inc(.parks);
        context.swap(&t.ctx, &self.sched_ctx);
    }

    pub fn finishFromRunning(self: *FifoScheduler) void {
        const t = self.running orelse @panic("zigroutines: finish with no running task");
        t.state = .dead;
        t.finished.store(true, .release);
        t.finishJoiners();
        if (self.live > 0) self.live -= 1;
        if (self.metrics) |m| m.inc(.finishes);
        const t_ctx = &t.ctx;
        self.dead.append(self.allocator, t) catch @panic("zigroutines: OOM finishing task");
        context.swap(t_ctx, &self.sched_ctx);
    }

    pub fn collectUnjoined(self: *FifoScheduler) void {
        while (self.dead.items.len > 0) {
            const t = self.dead.pop().?;
            t.destroy();
        }
    }
};
