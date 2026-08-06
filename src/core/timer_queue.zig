const std = @import("std");
const task_mod = @import("task.zig");
const sync = @import("synchronization.zig");

pub fn nowNs() i128 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const ts = std.Io.Clock.boot.now(io);
    return @intCast(ts.nanoseconds);
}

pub const TimerEntry = struct {
    deadline_ns: i128,
    task: *task_mod.Task,
    done: bool = false,
    parked: bool = false,
    canceled: bool = false,
    heap_index: i32 = -1,
};

pub const TimerQueue = struct {
    allocator: std.mem.Allocator,
    lock: sync.SpinLock = .{},
    heap: std.ArrayListUnmanaged(*TimerEntry) = .empty,

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
        return self.heap.items.len;
    }

    pub fn nextDeadlineNs(self: *TimerQueue) ?i128 {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.heap.items.len == 0) return null;
        return self.heap.items[0].deadline_ns;
    }

    pub fn add(self: *TimerQueue, entry: *TimerEntry) void {
        self.lock.lock();
        defer self.lock.unlock();
        entry.heap_index = -1;
        entry.done = false;
        entry.canceled = false;
        self.heap.append(self.allocator, entry) catch @panic("zigroutines: OOM timer heap");
        self.siftUp(self.heap.items.len - 1);
    }

    pub fn remove(self: *TimerQueue, entry: *TimerEntry) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.removeUnlocked(entry);
    }

    fn removeUnlocked(self: *TimerQueue, entry: *TimerEntry) void {
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
    }

    pub fn fireExpired(self: *TimerQueue) usize {
        const now = nowNs();
        var woken: usize = 0;
        var to_wake: std.ArrayListUnmanaged(*task_mod.Task) = .empty;
        defer to_wake.deinit(self.allocator);

        self.lock.lock();
        while (self.heap.items.len > 0 and self.heap.items[0].deadline_ns <= now) {
            const entry = self.heap.items[0];
            self.removeUnlocked(entry);
            if (entry.canceled) {
                entry.done = true;
                continue;
            }
            entry.done = true;
            if (entry.parked) {
                to_wake.append(self.allocator, entry.task) catch {};
            }
        }
        self.lock.unlock();

        for (to_wake.items) |t| {
            wakeTask(t);
            woken += 1;
        }
        return woken;
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
    var spins: u32 = 0;
    while (t.on_cpu.load(.acquire)) {
        std.atomic.spinLoopHint();
        spins +%= 1;
        if (spins > 200) {
            std.Thread.yield() catch {};
            spins = 0;
        }
    }
    const ex = t.executor orelse @panic("zigroutines: wake timer task without executor");
    ex.enqueue(t) catch @panic("zigroutines: OOM waking timer");
}
