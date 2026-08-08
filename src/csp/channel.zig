const std = @import("std");
const task_mod = @import("../core/task.zig");
const sync = @import("../core/synchronization.zig");
const trace = @import("../core/tracing.zig");
const list = @import("../utils/intrusive_list.zig");

pub const Error = error{
    Closed,
    WouldBlock,
    Full,
};

pub const FullPolicy = enum {
    block,
    drop_newest,
    drop_oldest,
    error_full,
};

pub const default_channel_recycle: bool = false;

pub const ChannelOptions = struct {
    full_policy: FullPolicy = .block,
    recycle: bool = default_channel_recycle,
};

pub fn Channel(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        capacity: usize,
        full_policy: FullPolicy = .block,
        lock: sync.SpinLock = .{},

        buf: []T = &.{},
        head: usize = 0,
        len: usize = 0,
        closed: bool = false,

        send_q: list.List = .{},
        recv_q: list.List = .{},

        dropped: u64 = 0,
        pool_next: ?*Self = null,
        may_recycle: bool = false,

        const Self = @This();
        pub const Elem = T;

        const pool_caps = [_]usize{ 0, 1, 8, 16, 256 };
        const max_pooled_per_class: usize = 2048;

        var pool_lock: sync.SpinLock = .{};
        var free_heads: [pool_caps.len]?*Self = @splat(null);
        var free_counts: [pool_caps.len]usize = @splat(0);

        fn poolClass(capacity: usize) ?usize {
            inline for (pool_caps, 0..) |c, i| {
                if (c == capacity) return i;
            }
            return null;
        }

        fn wantRecycle(opts: ChannelOptions) bool {
            return opts.recycle;
        }

        pub const SendWaiter = struct {
            node: list.Node = .{},
            task: *task_mod.Task,
            value: T,
            done: bool = false,
            parked: bool = false,
            closed: bool = false,
        };

        pub const RecvWaiter = struct {
            node: list.Node = .{},
            task: *task_mod.Task,
            value: T = undefined,
            done: bool = false,
            parked: bool = false,
            closed: bool = false,
        };

        pub fn create(allocator: std.mem.Allocator, capacity: usize) !*Self {
            return createWith(allocator, capacity, .{});
        }

        pub fn createPooled(allocator: std.mem.Allocator, capacity: usize) !*Self {
            return createWith(allocator, capacity, .{ .recycle = true });
        }

        pub fn createWith(allocator: std.mem.Allocator, capacity: usize, opts: ChannelOptions) !*Self {
            const recycle = wantRecycle(opts);
            if (recycle) {
                if (poolClass(capacity)) |idx| {
                    pool_lock.lock();
                    if (free_heads[idx]) |head| {
                        free_heads[idx] = head.pool_next;
                        free_counts[idx] -= 1;
                        pool_lock.unlock();
                        const kept_buf = head.buf;
                        head.* = .{
                            .allocator = allocator,
                            .capacity = capacity,
                            .full_policy = opts.full_policy,
                            .buf = kept_buf,
                            .head = 0,
                            .len = 0,
                            .closed = false,
                            .send_q = .{},
                            .recv_q = .{},
                            .dropped = 0,
                            .pool_next = null,
                            .may_recycle = true,
                        };
                        return head;
                    }
                    pool_lock.unlock();
                }
            }

            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            var buf: []T = &.{};
            if (capacity > 0) {
                buf = try allocator.alloc(T, capacity);
            }

            self.* = .{
                .allocator = allocator,
                .capacity = capacity,
                .full_policy = opts.full_policy,
                .buf = buf,
                .may_recycle = recycle and poolClass(capacity) != null,
            };
            return self;
        }

        pub fn destroy(self: *Self) void {
            self.close();
            std.debug.assert(self.send_q.isEmpty());
            std.debug.assert(self.recv_q.isEmpty());

            if (self.may_recycle) {
                if (poolClass(self.capacity)) |idx| {
                    pool_lock.lock();
                    if (free_counts[idx] < max_pooled_per_class) {
                        self.head = 0;
                        self.len = 0;
                        self.closed = false;
                        self.dropped = 0;
                        self.send_q = .{};
                        self.recv_q = .{};
                        self.full_policy = .block;
                        self.pool_next = free_heads[idx];
                        free_heads[idx] = self;
                        free_counts[idx] += 1;
                        pool_lock.unlock();
                        return;
                    }
                    pool_lock.unlock();
                }
            }

            if (self.buf.len != 0) {
                self.allocator.free(self.buf);
            }
            const allocator = self.allocator;
            allocator.destroy(self);
        }

        pub fn isRendezvous(self: *const Self) bool {
            return self.capacity == 0;
        }

        pub fn isClosed(self: *Self) bool {
            self.lock.lock();
            defer self.lock.unlock();
            return self.closed;
        }

        pub fn lenBuffered(self: *Self) usize {
            self.lock.lock();
            defer self.lock.unlock();
            return self.len;
        }

        pub fn droppedCount(self: *Self) u64 {
            self.lock.lock();
            defer self.lock.unlock();
            return self.dropped;
        }

        pub fn close(self: *Self) void {
            self.lock.lock();
            if (self.closed) {
                self.lock.unlock();
                return;
            }
            self.closed = true;

            var to_wake: [64]*task_mod.Task = undefined;
            var n: usize = 0;

            while (self.send_q.popFront()) |node| {
                const w: *SendWaiter = @fieldParentPtr("node", node);
                w.done = true;
                w.closed = true;
                if (w.parked) {
                    if (n < to_wake.len) {
                        to_wake[n] = w.task;
                        n += 1;
                    } else {
                        self.lock.unlock();
                        wakeTask(w.task);
                        self.lock.lock();
                    }
                }
            }
            while (self.recv_q.popFront()) |node| {
                const w: *RecvWaiter = @fieldParentPtr("node", node);
                w.done = true;
                w.closed = true;
                if (w.parked) {
                    if (n < to_wake.len) {
                        to_wake[n] = w.task;
                        n += 1;
                    } else {
                        self.lock.unlock();
                        wakeTask(w.task);
                        self.lock.lock();
                    }
                }
            }
            self.lock.unlock();

            for (to_wake[0..n]) |t| wakeTask(t);
        }

        fn popRecv(self: *Self) ?*RecvWaiter {
            const node = self.recv_q.popFront() orelse return null;
            return @fieldParentPtr("node", node);
        }

        fn popSend(self: *Self) ?*SendWaiter {
            const node = self.send_q.popFront() orelse return null;
            return @fieldParentPtr("node", node);
        }

        pub fn send(self: *Self, value: T) Error!void {
            const me = requireTask();
            while (true) {
                self.lock.lock();

                if (self.closed) {
                    self.lock.unlock();
                    return error.Closed;
                }

                if (self.popRecv()) |rw| {
                    rw.value = value;
                    rw.done = true;
                    const parked = rw.parked;
                    const peer = rw.task;
                    self.lock.unlock();
                    if (parked) wakeTask(peer);
                    trace.emit(.chan_send, 1);
                    return;
                }

                if (self.capacity > 0 and self.len < self.capacity) {
                    self.pushUnlocked(value);
                    self.lock.unlock();
                    trace.emit(.chan_send, 1);
                    return;
                }

                if (self.capacity > 0) {
                    switch (self.full_policy) {
                        .block => {},
                        .drop_newest => {
                            self.dropped += 1;
                            self.lock.unlock();
                            trace.emit(.chan_send, 2);
                            return;
                        },
                        .drop_oldest => {
                            _ = self.popUnlocked();
                            self.pushUnlocked(value);
                            self.dropped += 1;
                            self.lock.unlock();
                            trace.emit(.chan_send, 2);
                            return;
                        },
                        .error_full => {
                            self.lock.unlock();
                            return error.Full;
                        },
                    }
                }

                var waiter = SendWaiter{
                    .task = me,
                    .value = value,
                };
                self.send_q.pushBack(&waiter.node);
                self.lock.unlock();

                if (waitUntilDone(self, &waiter)) {
                    if (waiter.closed) return error.Closed;
                    trace.emit(.chan_send, 1);
                    return;
                }
            }
        }

        pub fn trySend(self: *Self, value: T) Error!void {
            self.lock.lock();

            if (self.closed) {
                self.lock.unlock();
                return error.Closed;
            }

            if (self.popRecv()) |rw| {
                rw.value = value;
                rw.done = true;
                const parked = rw.parked;
                const peer = rw.task;
                self.lock.unlock();
                if (parked) wakeTask(peer);
                return;
            }

            if (self.capacity > 0 and self.len < self.capacity) {
                self.pushUnlocked(value);
                self.lock.unlock();
                return;
            }

            if (self.capacity > 0) {
                switch (self.full_policy) {
                    .block => {},
                    .drop_newest => {
                        self.dropped += 1;
                        self.lock.unlock();
                        return;
                    },
                    .drop_oldest => {
                        _ = self.popUnlocked();
                        self.pushUnlocked(value);
                        self.dropped += 1;
                        self.lock.unlock();
                        return;
                    },
                    .error_full => {
                        self.lock.unlock();
                        return error.Full;
                    },
                }
            }

            self.lock.unlock();
            return error.WouldBlock;
        }

        pub fn recv(self: *Self) Error!T {
            const me = requireTask();
            while (true) {
                self.lock.lock();

                if (self.len > 0) {
                    const v = self.popUnlocked();
                    var wake_peer: ?*task_mod.Task = null;
                    if (self.popSend()) |sw| {
                        self.pushUnlocked(sw.value);
                        sw.done = true;
                        if (sw.parked) wake_peer = sw.task;
                    }
                    self.lock.unlock();
                    if (wake_peer) |p| wakeTask(p);
                    trace.emit(.chan_recv, 1);
                    return v;
                }

                if (self.popSend()) |sw| {
                    const v = sw.value;
                    sw.done = true;
                    const parked = sw.parked;
                    const peer = sw.task;
                    self.lock.unlock();
                    if (parked) wakeTask(peer);
                    trace.emit(.chan_recv, 1);
                    return v;
                }

                if (self.closed) {
                    self.lock.unlock();
                    return error.Closed;
                }

                var waiter = RecvWaiter{
                    .task = me,
                };
                self.recv_q.pushBack(&waiter.node);
                self.lock.unlock();

                if (waitUntilDoneRecv(self, &waiter)) {
                    if (waiter.closed) return error.Closed;
                    trace.emit(.chan_recv, 1);
                    return waiter.value;
                }
            }
        }

        pub fn tryRecv(self: *Self) Error!T {
            self.lock.lock();

            if (self.len > 0) {
                const v = self.popUnlocked();
                var wake_peer: ?*task_mod.Task = null;
                if (self.popSend()) |sw| {
                    self.pushUnlocked(sw.value);
                    sw.done = true;
                    if (sw.parked) wake_peer = sw.task;
                }
                self.lock.unlock();
                if (wake_peer) |p| wakeTask(p);
                return v;
            }

            if (self.popSend()) |sw| {
                const v = sw.value;
                sw.done = true;
                const parked = sw.parked;
                const peer = sw.task;
                self.lock.unlock();
                if (parked) wakeTask(peer);
                return v;
            }

            if (self.closed) {
                self.lock.unlock();
                return error.Closed;
            }

            self.lock.unlock();
            return error.WouldBlock;
        }

        pub const TryOrReg = union(enum) {
            value: T,
            closed,
            registered,
        };

        pub const TrySendOrReg = union(enum) {
            sent,
            closed,
            full,
            registered,
        };

        pub fn tryRecvOrRegister(self: *Self, waiter: *RecvWaiter) TryOrReg {
            self.lock.lock();

            if (self.len > 0) {
                const v = self.popUnlocked();
                var wake_peer: ?*task_mod.Task = null;
                if (self.popSend()) |sw| {
                    self.pushUnlocked(sw.value);
                    sw.done = true;
                    if (sw.parked) wake_peer = sw.task;
                }
                self.lock.unlock();
                if (wake_peer) |p| wakeTask(p);
                return .{ .value = v };
            }

            if (self.popSend()) |sw| {
                const v = sw.value;
                sw.done = true;
                const parked = sw.parked;
                const peer = sw.task;
                self.lock.unlock();
                if (parked) wakeTask(peer);
                return .{ .value = v };
            }

            if (self.closed) {
                self.lock.unlock();
                return .closed;
            }

            waiter.done = false;
            waiter.parked = false;
            waiter.closed = false;
            waiter.node = .{};
            self.recv_q.pushBack(&waiter.node);
            self.lock.unlock();
            return .registered;
        }

        pub fn trySendOrRegister(self: *Self, waiter: *SendWaiter) TrySendOrReg {
            self.lock.lock();

            if (self.closed) {
                self.lock.unlock();
                return .closed;
            }

            if (self.popRecv()) |rw| {
                rw.value = waiter.value;
                rw.done = true;
                const parked = rw.parked;
                const peer = rw.task;
                waiter.done = true;
                self.lock.unlock();
                if (parked) wakeTask(peer);
                return .sent;
            }

            if (self.capacity > 0 and self.len < self.capacity) {
                self.pushUnlocked(waiter.value);
                waiter.done = true;
                self.lock.unlock();
                return .sent;
            }

            if (self.capacity > 0) {
                switch (self.full_policy) {
                    .block => {},
                    .drop_newest => {
                        self.dropped += 1;
                        waiter.done = true;
                        self.lock.unlock();
                        return .sent;
                    },
                    .drop_oldest => {
                        _ = self.popUnlocked();
                        self.pushUnlocked(waiter.value);
                        self.dropped += 1;
                        waiter.done = true;
                        self.lock.unlock();
                        return .sent;
                    },
                    .error_full => {
                        self.lock.unlock();
                        return .full;
                    },
                }
            }

            waiter.done = false;
            waiter.parked = false;
            waiter.closed = false;
            waiter.node = .{};
            self.send_q.pushBack(&waiter.node);
            self.lock.unlock();
            return .registered;
        }

        pub fn unregisterRecv(self: *Self, waiter: *RecvWaiter) bool {
            self.lock.lock();
            defer self.lock.unlock();
            if (waiter.done) return false;
            if (!waiter.node.linked) return false;
            self.recv_q.remove(&waiter.node);
            return true;
        }

        pub fn unregisterSend(self: *Self, waiter: *SendWaiter) bool {
            self.lock.lock();
            defer self.lock.unlock();
            if (waiter.done) return false;
            if (!waiter.node.linked) return false;
            self.send_q.remove(&waiter.node);
            return true;
        }

        pub fn markRecvParked(self: *Self, waiter: *RecvWaiter) bool {
            self.lock.lock();
            defer self.lock.unlock();
            if (waiter.done) return true;
            waiter.parked = true;
            return false;
        }

        pub fn markSendParked(self: *Self, waiter: *SendWaiter) bool {
            self.lock.lock();
            defer self.lock.unlock();
            if (waiter.done) return true;
            waiter.parked = true;
            return false;
        }

        fn pushUnlocked(self: *Self, value: T) void {
            std.debug.assert(self.capacity > 0 and self.len < self.capacity);
            const idx = (self.head + self.len) % self.capacity;
            self.buf[idx] = value;
            self.len += 1;
        }

        fn popUnlocked(self: *Self) T {
            std.debug.assert(self.len > 0);
            const v = self.buf[self.head];
            self.head = (self.head + 1) % self.capacity;
            self.len -= 1;
            return v;
        }

        fn waitUntilDone(self: *Self, waiter: *SendWaiter) bool {
            self.lock.lock();
            if (waiter.done) {
                self.lock.unlock();
                return true;
            }
            waiter.parked = true;
            self.lock.unlock();

            const ex = waiter.task.executor orelse @panic("zigroutines: send without executor");
            ex.parkFromRunning(.chan_send);

            std.debug.assert(waiter.done);
            return true;
        }

        fn waitUntilDoneRecv(self: *Self, waiter: *RecvWaiter) bool {
            self.lock.lock();
            if (waiter.done) {
                self.lock.unlock();
                return true;
            }
            waiter.parked = true;
            self.lock.unlock();

            const ex = waiter.task.executor orelse @panic("zigroutines: recv without executor");
            ex.parkFromRunning(.chan_recv);

            std.debug.assert(waiter.done);
            return true;
        }

        fn requireTask() *task_mod.Task {
            return task_mod.current() orelse @panic("zigroutines: channel op outside a task");
        }

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
            const ex = t.executor orelse @panic("zigroutines: wake task without executor");
            ex.enqueue(t) catch @panic("zigroutines: OOM waking channel waiter");
        }
    };
}
