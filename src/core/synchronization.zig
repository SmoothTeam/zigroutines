const std = @import("std");
const task_mod = @import("task.zig");
const list = @import("../utils/intrusive_list.zig");

pub const SpinLock = struct {
    state: std.atomic.Value(u8) = .init(0),

    pub fn lock(self: *SpinLock) void {
        var spins: u32 = 0;
        while (self.state.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
            spins +%= 1;
            if (spins > 100) {
                std.Thread.yield() catch {};
                spins = 0;
            }
        }
    }

    pub fn unlock(self: *SpinLock) void {
        self.state.store(0, .release);
    }
};

fn wakeTask(t: *task_mod.Task) void {
    task_mod.waitUntilOffCpu(t);
    if (t.state == .blocked) {
        if (t.executor) |ex| {
            ex.enqueue(t) catch {};
        }
    }
}

fn requireTask() *task_mod.Task {
    return task_mod.current() orelse @panic("zigroutines: sync primitive outside a task");
}

fn multiWorkerRuntime() bool {
    const runtime = @import("runtime.zig");
    if (runtime.currentRuntime()) |rt| return rt.worker_count > 1;
    return false;
}

const Waiter = struct {
    node: list.Node = .{},
    task: *task_mod.Task,
    done: bool = false,
    parked: bool = false,
};

pub const ParkingLot = struct {
    lock: SpinLock = .{},
    waiters: list.List = .{},

    pub fn init(allocator: std.mem.Allocator) ParkingLot {
        _ = allocator;
        return .{};
    }

    pub fn deinit(self: *ParkingLot) void {
        self.* = undefined;
    }

    pub fn park(self: *ParkingLot) void {
        const me = requireTask();
        var w = Waiter{ .task = me };
        self.lock.lock();
        self.waiters.pushBack(&w.node);
        w.parked = true;
        self.lock.unlock();

        const ex = me.executor orelse @panic("zigroutines: park without executor");
        ex.parkFromRunning(.manual_park);
        std.debug.assert(w.done);
    }

    pub fn wakeOne(self: *ParkingLot) void {
        self.lock.lock();
        const node = self.waiters.popFront();
        if (node) |n| {
            const waiter: *Waiter = @fieldParentPtr("node", n);
            waiter.done = true;
            const parked = waiter.parked;
            const t = waiter.task;
            self.lock.unlock();
            if (parked) wakeTask(t);
            return;
        }
        self.lock.unlock();
    }

    pub fn wakeAll(self: *ParkingLot) void {
        self.lock.lock();
        var batch: [64]*Waiter = undefined;
        var n: usize = 0;
        while (self.waiters.popFront()) |node| {
            const w: *Waiter = @fieldParentPtr("node", node);
            if (n < batch.len) {
                batch[n] = w;
                n += 1;
            } else {
                w.done = true;
                const parked = w.parked;
                const t = w.task;
                self.lock.unlock();
                if (parked) wakeTask(t);
                self.lock.lock();
            }
        }
        self.lock.unlock();
        for (batch[0..n]) |w| {
            w.done = true;
            if (w.parked) wakeTask(w.task);
        }
    }
};

pub const Semaphore = struct {
    lock: SpinLock = .{},
    count: std.atomic.Value(isize),
    waiters: list.List = .{},

    pub fn init(allocator: std.mem.Allocator, initial: isize) Semaphore {
        _ = allocator;
        return .{ .count = .init(initial) };
    }

    pub fn deinit(self: *Semaphore) void {
        self.* = undefined;
    }

    pub fn acquire(self: *Semaphore) void {
        const me = requireTask();
        var spins: u32 = 0;
        const max_spin: u32 = if (multiWorkerRuntime()) 64 else 0;
        while (true) {
            var c = self.count.load(.monotonic);
            while (c > 0) {
                if (self.count.cmpxchgWeak(c, c - 1, .acquire, .monotonic)) |cur| {
                    c = cur;
                } else {
                    return;
                }
            }
            if (spins < max_spin) {
                std.atomic.spinLoopHint();
                spins +%= 1;
                continue;
            }
            break;
        }

        while (true) {
            self.lock.lock();
            var c = self.count.load(.monotonic);
            if (c > 0) {
                if (self.count.cmpxchgWeak(c, c - 1, .acquire, .monotonic) == null) {
                    self.lock.unlock();
                    return;
                }
                self.lock.unlock();
                continue;
            }
            var w = Waiter{ .task = me };
            self.waiters.pushBack(&w.node);
            c = self.count.load(.monotonic);
            if (c > 0) {
                self.waiters.remove(&w.node);
                if (self.count.cmpxchgWeak(c, c - 1, .acquire, .monotonic) == null) {
                    self.lock.unlock();
                    return;
                }
                self.lock.unlock();
                continue;
            }
            w.parked = true;
            self.lock.unlock();
            if (w.done) return;

            const ex = me.executor orelse @panic("zigroutines: semaphore without executor");
            ex.parkFromRunning(.manual_park);
            if (w.done) return;
        }
    }

    pub fn tryAcquire(self: *Semaphore) bool {
        var c = self.count.load(.monotonic);
        while (c > 0) {
            if (self.count.cmpxchgWeak(c, c - 1, .acquire, .monotonic)) |cur| {
                c = cur;
            } else {
                return true;
            }
        }
        return false;
    }

    pub fn release(self: *Semaphore) void {
        self.lock.lock();
        if (self.waiters.popFront()) |node| {
            const w: *Waiter = @fieldParentPtr("node", node);
            w.done = true;
            const parked = w.parked;
            const t = w.task;
            self.lock.unlock();
            if (parked) wakeTask(t);
            return;
        }
        _ = self.count.fetchAdd(1, .release);
        self.lock.unlock();
    }
};

pub const Mutex = struct {
    state: std.atomic.Value(u8) = .init(0),
    wait_lock: SpinLock = .{},
    waiters: list.List = .{},

    const unlocked: u8 = 0;
    const locked: u8 = 1;
    const contested: u8 = 2;

    pub fn init(allocator: std.mem.Allocator) Mutex {
        _ = allocator;
        return .{};
    }

    pub fn deinit(self: *Mutex) void {
        self.* = undefined;
    }

    pub fn tryLock(self: *Mutex) bool {
        return self.state.cmpxchgStrong(unlocked, locked, .acquire, .monotonic) == null;
    }

    pub fn lock(self: *Mutex) void {
        if (self.tryLock()) return;

        const max_spin: u32 = if (multiWorkerRuntime()) 100 else 0;
        var spins: u32 = 0;
        while (spins < max_spin) : (spins += 1) {
            if (self.state.load(.monotonic) == unlocked) {
                if (self.tryLock()) return;
            }
            std.atomic.spinLoopHint();
        }

        const me = requireTask();
        while (true) {
            self.wait_lock.lock();
            const prev = self.state.swap(contested, .acquire);
            if (prev == unlocked) {
                self.state.store(locked, .release);
                self.wait_lock.unlock();
                return;
            }
            var w = Waiter{ .task = me };
            self.waiters.pushBack(&w.node);
            w.parked = true;
            self.wait_lock.unlock();

            if (w.done) return;

            const ex = me.executor orelse @panic("zigroutines: mutex without executor");
            ex.parkFromRunning(.manual_park);
            if (w.done) return;
        }
    }

    pub fn unlock(self: *Mutex) void {
        if (self.state.cmpxchgStrong(locked, unlocked, .release, .monotonic) == null) return;

        self.wait_lock.lock();
        if (self.waiters.popFront()) |node| {
            const w: *Waiter = @fieldParentPtr("node", node);
            w.done = true;
            const parked = w.parked;
            const t = w.task;
            if (self.waiters.isEmpty()) {
                self.state.store(locked, .release);
            } else {
                self.state.store(contested, .release);
            }
            self.wait_lock.unlock();
            if (parked) wakeTask(t);
            return;
        }
        self.state.store(unlocked, .release);
        self.wait_lock.unlock();
    }
};

pub const Notify = struct {
    lot: ParkingLot = .{},

    pub fn init(allocator: std.mem.Allocator) Notify {
        _ = allocator;
        return .{};
    }

    pub fn deinit(self: *Notify) void {
        self.* = undefined;
    }

    pub fn wait(self: *Notify) void {
        self.lot.park();
    }

    pub fn notifyOne(self: *Notify) void {
        self.lot.wakeOne();
    }

    pub fn notifyAll(self: *Notify) void {
        self.lot.wakeAll();
    }
};

pub fn Watch(comptime T: type) type {
    return struct {
        lock: SpinLock = .{},
        value: T = undefined,
        version: u64 = 0,
        has_value: bool = false,
        waiters: list.List = .{},

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            _ = allocator;
            return .{};
        }

        pub fn deinit(self: *Self) void {
            self.* = undefined;
        }

        pub fn send(self: *Self, v: T) void {
            self.lock.lock();
            self.value = v;
            self.has_value = true;
            self.version +%= 1;
            var batch: [32]*Waiter = undefined;
            var n: usize = 0;
            while (self.waiters.popFront()) |node| {
                const w: *Waiter = @fieldParentPtr("node", node);
                if (n < batch.len) {
                    batch[n] = w;
                    n += 1;
                } else {
                    w.done = true;
                    const parked = w.parked;
                    const t = w.task;
                    self.lock.unlock();
                    if (parked) wakeTask(t);
                    self.lock.lock();
                }
            }
            self.lock.unlock();
            for (batch[0..n]) |w| {
                w.done = true;
                if (w.parked) wakeTask(w.task);
            }
        }

        pub fn recv(self: *Self, seen: u64) struct { T, u64 } {
            const me = requireTask();
            while (true) {
                self.lock.lock();
                if (self.has_value and self.version != seen) {
                    const v = self.value;
                    const ver = self.version;
                    self.lock.unlock();
                    return .{ v, ver };
                }
                var w = Waiter{ .task = me };
                self.waiters.pushBack(&w.node);
                w.parked = true;
                self.lock.unlock();
                const ex = me.executor orelse @panic("zigroutines: watch without executor");
                ex.parkFromRunning(.manual_park);
            }
        }

        pub fn tryRecv(self: *Self, seen: u64) ?struct { T, u64 } {
            self.lock.lock();
            defer self.lock.unlock();
            if (self.has_value and self.version != seen) {
                return .{ self.value, self.version };
            }
            return null;
        }
    };
}

pub const RwLock = struct {
    lock: SpinLock = .{},
    readers: i32 = 0,
    writer: bool = false,
    read_waiters: list.List = .{},
    write_waiters: list.List = .{},

    pub fn init(allocator: std.mem.Allocator) RwLock {
        _ = allocator;
        return .{};
    }

    pub fn deinit(self: *RwLock) void {
        self.* = undefined;
    }

    pub fn lockShared(self: *RwLock) void {
        const me = requireTask();
        while (true) {
            self.lock.lock();
            if (!self.writer and self.write_waiters.isEmpty()) {
                self.readers += 1;
                self.lock.unlock();
                return;
            }
            var w = Waiter{ .task = me };
            self.read_waiters.pushBack(&w.node);
            w.parked = true;
            self.lock.unlock();
            const ex = me.executor orelse @panic("zigroutines: rwlock without executor");
            ex.parkFromRunning(.manual_park);
            if (w.done) return;
        }
    }

    pub fn unlockShared(self: *RwLock) void {
        self.lock.lock();
        self.readers -= 1;
        if (self.readers == 0 and !self.write_waiters.isEmpty()) {
            const node = self.write_waiters.popFront().?;
            const w: *Waiter = @fieldParentPtr("node", node);
            self.writer = true;
            w.done = true;
            const parked = w.parked;
            const t = w.task;
            self.lock.unlock();
            if (parked) wakeTask(t);
            return;
        }
        self.lock.unlock();
    }

    pub fn lockExclusive(self: *RwLock) void {
        const me = requireTask();
        while (true) {
            self.lock.lock();
            if (!self.writer and self.readers == 0) {
                self.writer = true;
                self.lock.unlock();
                return;
            }
            var w = Waiter{ .task = me };
            self.write_waiters.pushBack(&w.node);
            w.parked = true;
            self.lock.unlock();
            const ex = me.executor orelse @panic("zigroutines: rwlock without executor");
            ex.parkFromRunning(.manual_park);
            if (w.done) return;
        }
    }

    pub fn unlockExclusive(self: *RwLock) void {
        self.lock.lock();
        self.writer = false;
        if (!self.write_waiters.isEmpty()) {
            const node = self.write_waiters.popFront().?;
            const w: *Waiter = @fieldParentPtr("node", node);
            self.writer = true;
            w.done = true;
            const parked = w.parked;
            const t = w.task;
            self.lock.unlock();
            if (parked) wakeTask(t);
            return;
        }

        var batch: [64]*Waiter = undefined;
        var total_readers: i32 = 0;
        while (true) {
            if (self.writer or !self.write_waiters.isEmpty()) {
                self.readers = total_readers;
                self.lock.unlock();
                return;
            }
            var n: usize = 0;
            while (n < batch.len) {
                const node = self.read_waiters.popFront() orelse break;
                batch[n] = @fieldParentPtr("node", node);
                n += 1;
            }
            if (n == 0) {
                self.readers = total_readers;
                self.lock.unlock();
                return;
            }
            total_readers += @intCast(n);
            self.readers = total_readers;
            self.lock.unlock();
            for (batch[0..n]) |w| {
                w.done = true;
                if (w.parked) wakeTask(w.task);
            }
            self.lock.lock();
        }
    }
};

pub const RateLimiter = struct {
    lock: SpinLock = .{},
    tokens: f64,
    max_tokens: f64,
    refill_per_ns: f64,
    last_ns: i128,
    waiters: list.List = .{},
    getNow: *const fn () i128 = defaultNow,

    fn defaultNow() i128 {
        const timer = @import("timer_queue.zig");
        return timer.nowNs();
    }

    pub fn init(allocator: std.mem.Allocator, rate_per_sec: f64, max_tokens: f64) RateLimiter {
        _ = allocator;
        const now = defaultNow();
        return .{
            .tokens = max_tokens,
            .max_tokens = max_tokens,
            .refill_per_ns = rate_per_sec / 1_000_000_000.0,
            .last_ns = now,
        };
    }

    pub fn deinit(self: *RateLimiter) void {
        self.* = undefined;
    }

    fn refill(self: *RateLimiter) void {
        const now = self.getNow();
        const dt: f64 = @floatFromInt(now - self.last_ns);
        if (dt > 0) {
            self.tokens = @min(self.max_tokens, self.tokens + dt * self.refill_per_ns);
            self.last_ns = now;
        }
    }

    pub fn acquire(self: *RateLimiter) void {
        const me = requireTask();
        while (true) {
            self.lock.lock();
            self.refill();
            if (self.tokens >= 1.0) {
                self.tokens -= 1.0;
                self.wakeWaitersUnlocked();
                self.lock.unlock();
                return;
            }
            var w = Waiter{ .task = me };
            self.waiters.pushBack(&w.node);
            w.parked = true;
            self.lock.unlock();

            const runtime = @import("runtime.zig");
            if (runtime.currentRuntime()) |rt| {
                const wait_ns: u64 = if (self.refill_per_ns > 0)
                    @intFromFloat(@max(1.0, (1.0 - self.tokens) / self.refill_per_ns))
                else
                    1 * std.time.ns_per_ms;
                rt.sleep(@min(wait_ns, 10 * std.time.ns_per_ms));
            } else {
                std.Thread.yield() catch {};
            }
            self.lock.lock();
            if (!w.done and w.node.linked) {
                self.waiters.remove(&w.node);
            }
            w.done = false;
            self.lock.unlock();
        }
    }

    pub fn tryAcquire(self: *RateLimiter) bool {
        self.lock.lock();
        defer self.lock.unlock();
        self.refill();
        if (self.tokens >= 1.0) {
            self.tokens -= 1.0;
            self.wakeWaitersUnlocked();
            return true;
        }
        return false;
    }

    fn wakeWaitersUnlocked(self: *RateLimiter) void {
        var batch: [16]*Waiter = undefined;
        var n: usize = 0;
        while (n < batch.len) {
            const node = self.waiters.popFront() orelse break;
            batch[n] = @fieldParentPtr("node", node);
            n += 1;
        }
        for (batch[0..n]) |w| {
            w.done = true;
            if (w.parked) {
                const t = w.task;
                self.lock.unlock();
                wakeTask(t);
                self.lock.lock();
            }
        }
    }
};
