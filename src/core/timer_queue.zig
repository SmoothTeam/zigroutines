const std = @import("std");
const builtin = @import("builtin");
const task_mod = @import("task.zig");
const sync = @import("synchronization.zig");

pub fn nowNs() i128 {
    if (comptime builtin.os.tag == .windows) {
        return windowsNowNs();
    }
    return ioNowNs();
}

fn windowsNowNs() i128 {
    var counter: i64 = 0;
    if (QueryPerformanceCounter(&counter) == 0) {
        return ioNowNs();
    }
    var freq: i64 = qpc_freq.load(.monotonic);
    if (freq == 0) {
        var f: i64 = 0;
        if (QueryPerformanceFrequency(&f) == 0 or f == 0) return ioNowNs();
        _ = qpc_freq.cmpxchgStrong(0, f, .monotonic, .monotonic);
        freq = qpc_freq.load(.monotonic);
        if (freq == 0) return ioNowNs();
    }
    return @divTrunc(@as(i128, counter) * 1_000_000_000, @as(i128, freq));
}

fn ioNowNs() i128 {
    const io = std.Io.Threaded.global_single_threaded.io();
    return @intCast(std.Io.Clock.boot.now(io).nanoseconds);
}

var qpc_freq: std.atomic.Value(i64) = .init(0);

extern "kernel32" fn QueryPerformanceCounter(performance_count: *i64) callconv(.winapi) i32;
extern "kernel32" fn QueryPerformanceFrequency(frequency: *i64) callconv(.winapi) i32;

pub fn sleepUntilDeadline(deadline_ns: i128) void {
    const now = nowNs();
    if (now >= deadline_ns) return;
    const delta = deadline_ns - now;
    if (delta <= 0) return;
    const remain: u64 = @intCast(@min(@as(u64, @intCast(delta)), 50 * std.time.ns_per_ms));
    if (remain == 0) return;
    if (comptime builtin.os.tag == .windows) {
        const ms: u32 = @intCast(@max(remain / std.time.ns_per_ms, 1));
        Sleep(ms);
    } else {
        const req = std.posix.timespec{
            .sec = @intCast(remain / std.time.ns_per_s),
            .nsec = @intCast(remain % std.time.ns_per_s),
        };
        _ = std.posix.nanosleep(&req, null);
    }
}

extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;

pub const TimerEntry = struct {
    deadline_ns: i128,
    task: *task_mod.Task,
    done: bool = false,
    parked: bool = false,
    canceled: bool = false,
    heap_index: i32 = -1,
    wheel_next: ?*TimerEntry = null,
    in_wheel: bool = false,
};

pub const TimerQueue = struct {
    pub const wheel_slots: usize = 256;
    pub const tick_ns: i128 = 1_000_000;
    pub const horizon_ns: i128 = @as(i128, wheel_slots) * tick_ns;

    allocator: std.mem.Allocator,
    lock: sync.SpinLock = .{},
    heap: std.ArrayListUnmanaged(*TimerEntry) = .empty,
    wheel: [wheel_slots]?*TimerEntry = @splat(null),
    wheel_base_ns: i128 = 0,
    cursor: u32 = 0,
    wheel_inited: bool = false,
    total: usize = 0,

    pub fn init(allocator: std.mem.Allocator) TimerQueue {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *TimerQueue) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.heap.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn len(self: *TimerQueue) usize {
        self.lock.lock();
        defer self.lock.unlock();
        return self.total;
    }

    pub fn nextDeadlineNs(self: *TimerQueue) ?i128 {
        self.lock.lock();
        defer self.lock.unlock();

        var best: ?i128 = null;
        if (self.heap.items.len > 0) {
            best = self.heap.items[0].deadline_ns;
        }
        if (self.wheel_inited) {
            var i: u32 = 0;
            while (i < wheel_slots) : (i += 1) {
                const slot = (self.cursor + i) % wheel_slots;
                if (self.wheel[slot] != null) {
                    const cand = self.wheel_base_ns + @as(i128, i) * tick_ns;
                    if (best == null or cand < best.?) best = cand;
                    break;
                }
            }
        }
        return best;
    }

    pub fn add(self: *TimerQueue, entry: *TimerEntry) void {
        self.lock.lock();
        defer self.lock.unlock();
        entry.heap_index = -1;
        entry.done = false;
        entry.canceled = false;
        entry.parked = false;
        entry.wheel_next = null;
        entry.in_wheel = false;

        const now = nowNs();
        if (!self.wheel_inited) {
            self.wheel_base_ns = now;
            self.cursor = 0;
            self.wheel_inited = true;
        }

        const delta = entry.deadline_ns - now;
        if (delta < horizon_ns and entry.deadline_ns >= self.wheel_base_ns) {
            const ticks_from_base = @divTrunc(entry.deadline_ns - self.wheel_base_ns, tick_ns);
            const slot = wheelSlot(self.cursor, ticks_from_base);
            entry.wheel_next = self.wheel[slot];
            self.wheel[slot] = entry;
            entry.in_wheel = true;
            self.total += 1;
            return;
        }

        self.heap.append(self.allocator, entry) catch @panic("zigroutines: OOM timer heap");
        self.siftUp(self.heap.items.len - 1);
        self.total += 1;
    }

    fn wheelSlot(cursor: u32, ticks_from_base: i128) usize {
        const t: i128 = @as(i128, cursor) + ticks_from_base;
        const m = @mod(t, @as(i128, wheel_slots));
        return @intCast(m);
    }

    pub fn remove(self: *TimerQueue, entry: *TimerEntry) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.removeUnlocked(entry);
    }

    fn removeUnlocked(self: *TimerQueue, entry: *TimerEntry) void {
        if (entry.in_wheel) {
            self.removeFromWheel(entry);
            if (self.total > 0) self.total -= 1;
            return;
        }
        if (entry.heap_index < 0) return;
        const idx: usize = @intCast(entry.heap_index);
        const last = self.heap.items.len - 1;
        if (idx != last) {
            self.heap.items[idx] = self.heap.items[last];
            self.heap.items[idx].heap_index = @intCast(idx);
            self.heap.items.len = last;
            self.siftDown(idx);
            self.siftUp(idx);
        } else {
            _ = self.heap.pop();
        }
        entry.heap_index = -1;
        if (self.total > 0) self.total -= 1;
    }

    fn removeFromWheel(self: *TimerQueue, entry: *TimerEntry) void {
        var s: usize = 0;
        while (s < wheel_slots) : (s += 1) {
            var prev: ?*TimerEntry = null;
            var cur = self.wheel[s];
            while (cur) |c| {
                if (c == entry) {
                    if (prev) |p| {
                        p.wheel_next = c.wheel_next;
                    } else {
                        self.wheel[s] = c.wheel_next;
                    }
                    entry.wheel_next = null;
                    entry.in_wheel = false;
                    return;
                }
                prev = c;
                cur = c.wheel_next;
            }
        }
        entry.in_wheel = false;
        entry.wheel_next = null;
    }

    pub fn fireExpired(self: *TimerQueue) usize {
        const now = nowNs();
        var stack_wake: [128]*task_mod.Task = undefined;
        var n_stack: usize = 0;
        var heap_wake: std.ArrayListUnmanaged(*task_mod.Task) = .empty;
        defer heap_wake.deinit(self.allocator);

        self.lock.lock();

        if (self.wheel_inited) {
            while (self.wheel_base_ns + tick_ns <= now) {
                var cur = self.wheel[self.cursor];
                self.wheel[self.cursor] = null;
                while (cur) |entry| {
                    const next = entry.wheel_next;
                    entry.wheel_next = null;
                    entry.in_wheel = false;
                    if (self.total > 0) self.total -= 1;
                    if (entry.canceled) {
                        entry.done = true;
                    } else if (entry.deadline_ns <= now) {
                        entry.done = true;
                        if (entry.parked) {
                            if (n_stack < stack_wake.len) {
                                stack_wake[n_stack] = entry.task;
                                n_stack += 1;
                            } else {
                                heap_wake.append(self.allocator, entry.task) catch {};
                            }
                        }
                    } else {
                        self.reinsertUnlocked(entry, now);
                    }
                    cur = next;
                }
                self.cursor = @intCast((@as(usize, self.cursor) + 1) % wheel_slots);
                self.wheel_base_ns += tick_ns;
            }
            var cur = self.wheel[self.cursor];
            var prev: ?*TimerEntry = null;
            while (cur) |entry| {
                const next = entry.wheel_next;
                if (!entry.canceled and entry.deadline_ns <= now) {
                    if (prev) |p| p.wheel_next = next else self.wheel[self.cursor] = next;
                    entry.wheel_next = null;
                    entry.in_wheel = false;
                    if (self.total > 0) self.total -= 1;
                    entry.done = true;
                    if (entry.parked) {
                        if (n_stack < stack_wake.len) {
                            stack_wake[n_stack] = entry.task;
                            n_stack += 1;
                        } else {
                            heap_wake.append(self.allocator, entry.task) catch {};
                        }
                    }
                    cur = next;
                    continue;
                }
                if (entry.canceled) {
                    if (prev) |p| p.wheel_next = next else self.wheel[self.cursor] = next;
                    entry.wheel_next = null;
                    entry.in_wheel = false;
                    if (self.total > 0) self.total -= 1;
                    entry.done = true;
                    cur = next;
                    continue;
                }
                prev = entry;
                cur = next;
            }
        }

        while (self.heap.items.len > 0 and self.heap.items[0].deadline_ns <= now) {
            const entry = self.heap.items[0];
            self.removeUnlocked(entry);
            if (entry.canceled) {
                entry.done = true;
                continue;
            }
            entry.done = true;
            if (entry.parked) {
                if (n_stack < stack_wake.len) {
                    stack_wake[n_stack] = entry.task;
                    n_stack += 1;
                } else {
                    heap_wake.append(self.allocator, entry.task) catch {};
                }
            }
        }

        self.promoteHeapToWheel(now);

        self.lock.unlock();

        var woken: usize = 0;
        for (stack_wake[0..n_stack]) |t| {
            wakeTask(t);
            woken += 1;
        }
        for (heap_wake.items) |t| {
            wakeTask(t);
            woken += 1;
        }
        return woken;
    }

    fn reinsertUnlocked(self: *TimerQueue, entry: *TimerEntry, now: i128) void {
        entry.done = false;
        entry.canceled = false;
        entry.heap_index = -1;
        entry.in_wheel = false;
        entry.wheel_next = null;
        const delta = entry.deadline_ns - now;
        if (delta < horizon_ns and entry.deadline_ns >= self.wheel_base_ns) {
            const ticks_from_base = @divTrunc(entry.deadline_ns - self.wheel_base_ns, tick_ns);
            const slot = wheelSlot(self.cursor, ticks_from_base);
            entry.wheel_next = self.wheel[slot];
            self.wheel[slot] = entry;
            entry.in_wheel = true;
            self.total += 1;
            return;
        }
        self.heap.append(self.allocator, entry) catch @panic("zigroutines: OOM timer heap");
        self.siftUp(self.heap.items.len - 1);
        self.total += 1;
    }

    fn promoteHeapToWheel(self: *TimerQueue, now: i128) void {
        while (self.heap.items.len > 0) {
            const e = self.heap.items[0];
            const delta = e.deadline_ns - now;
            if (delta >= horizon_ns or e.deadline_ns < self.wheel_base_ns) break;
            self.removeUnlocked(e);
            self.reinsertUnlocked(e, now);
            if (!e.in_wheel) break;
        }
    }

    pub fn wait(self: *TimerQueue, entry: *TimerEntry) void {
        const me = entry.task;

        self.lock.lock();
        if (entry.done) {
            self.lock.unlock();
            return;
        }
        entry.parked = true;
        self.lock.unlock();

        const ex = me.executor orelse @panic("zigroutines: timer wait without executor");
        ex.parkFromRunning(.timer);
    }

    pub fn sleep(self: *TimerQueue, duration_ns: u64) void {
        const me = task_mod.current() orelse @panic("zigroutines: sleep outside a task");
        var entry = TimerEntry{
            .deadline_ns = nowNs() + @as(i128, @intCast(duration_ns)),
            .task = me,
        };
        self.add(&entry);
        self.wait(&entry);
        self.remove(&entry);
    }

    fn siftUp(self: *TimerQueue, start: usize) void {
        var i = start;
        while (i > 0) {
            const p = (i - 1) / 2;
            if (self.heap.items[i].deadline_ns >= self.heap.items[p].deadline_ns) break;
            self.swap(i, p);
            i = p;
        }
        self.heap.items[i].heap_index = @intCast(i);
    }

    fn siftDown(self: *TimerQueue, start: usize) void {
        var i = start;
        const n = self.heap.items.len;
        while (true) {
            var smallest = i;
            const l = 2 * i + 1;
            const r = 2 * i + 2;
            if (l < n and self.heap.items[l].deadline_ns < self.heap.items[smallest].deadline_ns) smallest = l;
            if (r < n and self.heap.items[r].deadline_ns < self.heap.items[smallest].deadline_ns) smallest = r;
            if (smallest == i) break;
            self.swap(i, smallest);
            i = smallest;
        }
        if (n > 0) self.heap.items[i].heap_index = @intCast(i);
    }

    fn swap(self: *TimerQueue, a: usize, b: usize) void {
        const tmp = self.heap.items[a];
        self.heap.items[a] = self.heap.items[b];
        self.heap.items[b] = tmp;
        self.heap.items[a].heap_index = @intCast(a);
        self.heap.items[b].heap_index = @intCast(b);
    }
};

fn wakeTask(t: *task_mod.Task) void {
    task_mod.waitUntilOffCpu(t);
    const ex = t.executor orelse @panic("zigroutines: wake timer task without executor");
    ex.enqueue(t) catch @panic("zigroutines: OOM waking timer");
}
