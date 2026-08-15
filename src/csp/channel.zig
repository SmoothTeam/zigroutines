// SPDX-FileCopyrightText: 2026 Apanazar
//
// SPDX-License-Identifier: LGPL-3.0-or-later

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

pub const Topology = enum {
    mpmc,
    mpsc,
    spsc,
};

pub const ChannelOptions = struct {
    full_policy: FullPolicy = .block,
    recycle: bool = default_channel_recycle,
    topology: Topology = .mpmc,
};

pub fn Channel(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        capacity: usize,
        full_policy: FullPolicy = .block,
        lock: sync.SpinLock = .{},

        slots: []Slot = &.{},
        cap_mask: usize = 0,
        enq: std.atomic.Value(usize) align(64) = .init(0),
        deq: std.atomic.Value(usize) align(64) = .init(0),
        closed_flag: std.atomic.Value(u8) = .init(0),
        recv_waiters: std.atomic.Value(usize) = .init(0),
        send_waiters: std.atomic.Value(usize) = .init(0),
        topology: Topology = .mpmc,
        closed: bool = false,

        send_q: list.List = .{},
        recv_q: list.List = .{},

        dropped: u64 = 0,
        pool_next: ?*Self = null,
        may_recycle: bool = false,
        inline_slots: bool = false,

        const Self = @This();
        pub const Elem = T;

        const Slot = struct {
            seq: std.atomic.Value(usize) = .init(0),
            value: T = undefined,
        };

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
                        const kept = head.slots;
                        const inline_slots = head.inline_slots;
                        head.* = .{
                            .allocator = allocator,
                            .capacity = capacity,
                            .cap_mask = ringMask(capacity),
                            .full_policy = opts.full_policy,
                            .topology = opts.topology,
                            .slots = kept,
                            .may_recycle = true,
                            .inline_slots = inline_slots,
                        };
                        head.resetRing();
                        return head;
                    }
                    pool_lock.unlock();
                }
            }

            const self = try allocChannel(allocator, capacity);
            self.full_policy = opts.full_policy;
            self.topology = opts.topology;
            self.may_recycle = recycle and poolClass(capacity) != null;
            self.resetRing();
            return self;
        }

        fn allocChannel(allocator: std.mem.Allocator, capacity: usize) !*Self {
            const header = @sizeOf(Self);
            const extra = capacity * @sizeOf(Slot);
            const bytes = try allocator.alignedAlloc(u8, .fromByteUnits(@alignOf(Self)), header + extra);
            const self: *Self = @ptrCast(@alignCast(bytes.ptr));
            var slots: []Slot = &.{};
            if (capacity != 0) {
                const raw = bytes[header..];
                slots = @as([*]Slot, @ptrCast(@alignCast(raw.ptr)))[0..capacity];
            }
            self.* = .{
                .allocator = allocator,
                .capacity = capacity,
                .cap_mask = ringMask(capacity),
                .slots = slots,
                .inline_slots = true,
            };
            return self;
        }

        fn freeChannel(self: *Self) void {
            const allocator = self.allocator;
            if (self.inline_slots) {
                const n = @sizeOf(Self) + self.slots.len * @sizeOf(Slot);
                const bytes: []align(@alignOf(Self)) u8 = @as([*]align(@alignOf(Self)) u8, @ptrCast(self))[0..n];
                allocator.free(bytes);
                return;
            }
            if (self.slots.len != 0) allocator.free(self.slots);
            allocator.destroy(self);
        }

        fn resetRing(self: *Self) void {
            self.enq.store(0, .monotonic);
            self.deq.store(0, .monotonic);
            self.closed_flag.store(0, .monotonic);
            self.recv_waiters.store(0, .monotonic);
            self.send_waiters.store(0, .monotonic);
            for (self.slots, 0..) |*s, i| {
                s.seq.store(i, .monotonic);
                s.value = undefined;
            }
        }

        pub fn destroy(self: *Self) void {
            if (!self.send_q.isEmpty() or !self.recv_q.isEmpty() or self.closed) {
                self.close();
            }
            std.debug.assert(self.send_q.isEmpty());
            std.debug.assert(self.recv_q.isEmpty());

            if (self.may_recycle) {
                if (poolClass(self.capacity)) |idx| {
                    pool_lock.lock();
                    if (free_counts[idx] < max_pooled_per_class) {
                        self.resetRing();
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

            self.freeChannel();
        }

        pub fn isRendezvous(self: *const Self) bool {
            return self.capacity == 0;
        }

        pub fn isClosed(self: *Self) bool {
            return self.closed_flag.load(.acquire) != 0;
        }

        pub fn lenBuffered(self: *Self) usize {
            if (self.capacity == 0) return 0;
            return self.enq.load(.monotonic) -% self.deq.load(.monotonic);
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
            self.closed_flag.store(1, .release);

            var to_wake: [64]*task_mod.Task = undefined;
            var n: usize = 0;

            while (self.send_q.popFront()) |node| {
                _ = self.send_waiters.fetchSub(1, .release);
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
                _ = self.recv_waiters.fetchSub(1, .release);
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
            _ = self.recv_waiters.fetchSub(1, .release);
            return @fieldParentPtr("node", node);
        }

        fn popSend(self: *Self) ?*SendWaiter {
            const node = self.send_q.popFront() orelse return null;
            _ = self.send_waiters.fetchSub(1, .release);
            return @fieldParentPtr("node", node);
        }

        fn ringMask(capacity: usize) usize {
            if (capacity != 0 and std.math.isPowerOfTwo(capacity)) return capacity - 1;
            return 0;
        }

        fn slotAt(self: *Self, pos: usize) *Slot {
            if (self.cap_mask != 0) return &self.slots[pos & self.cap_mask];
            return &self.slots[pos % self.capacity];
        }

        fn tryEnqueueOne(self: *Self, value: T) bool {
            if (self.enq.load(.acquire) -% self.deq.load(.acquire) != 0) return false;
            const slot = &self.slots[0];
            if (slot.seq.cmpxchgStrong(0, 1, .acquire, .monotonic) != null) return false;
            slot.value = value;
            self.enq.store(self.deq.load(.monotonic) +% 1, .release);
            slot.seq.store(2, .release);
            return true;
        }

        fn tryDequeueOne(self: *Self) ?T {
            const slot = &self.slots[0];
            if (slot.seq.cmpxchgStrong(2, 3, .acquire, .monotonic) != null) return null;
            const v = slot.value;
            self.deq.store(self.enq.load(.monotonic), .release);
            slot.seq.store(0, .release);
            return v;
        }

        fn tryEnqueue(self: *Self, value: T) bool {
            if (self.capacity == 1) return self.tryEnqueueOne(value);
            var pos = self.enq.load(.monotonic);
            while (true) {
                const slot = self.slotAt(pos);
                const seq = slot.seq.load(.acquire);
                const dif: isize = @bitCast(seq -% pos);
                if (dif == 0) {
                    if (self.enq.cmpxchgWeak(pos, pos +% 1, .acq_rel, .monotonic)) |cur| {
                        pos = cur;
                        continue;
                    }
                    slot.value = value;
                    slot.seq.store(pos +% 1, .release);
                    return true;
                } else if (dif < 0) {
                    return false;
                } else {
                    pos = self.enq.load(.monotonic);
                }
            }
        }

        fn tryDequeue(self: *Self) ?T {
            if (self.capacity == 1) return self.tryDequeueOne();
            var pos = self.deq.load(.monotonic);
            while (true) {
                const slot = self.slotAt(pos);
                const seq = slot.seq.load(.acquire);
                const dif: isize = @bitCast(seq -% (pos +% 1));
                if (dif == 0) {
                    if (self.deq.cmpxchgWeak(pos, pos +% 1, .acq_rel, .monotonic)) |cur| {
                        pos = cur;
                        continue;
                    }
                    const v = slot.value;
                    slot.seq.store(pos +% self.capacity, .release);
                    return v;
                } else if (dif < 0) {
                    return null;
                } else {
                    pos = self.deq.load(.monotonic);
                }
            }
        }

        fn nudgeRecv(self: *Self) void {
            self.lock.lock();
            const rw = self.popRecv() orelse {
                self.lock.unlock();
                return;
            };
            if (rw.done) {
                self.lock.unlock();
                return;
            }
            if (self.capacity > 0) {
                if (self.tryDequeue()) |v| {
                    rw.value = v;
                    rw.done = true;
                    const parked = rw.parked;
                    const peer = rw.task;
                    self.lock.unlock();
                    if (parked) wakeTask(peer);
                    return;
                }
            }
            self.recv_q.pushBack(&rw.node);
            _ = self.recv_waiters.fetchAdd(1, .release);
            self.lock.unlock();
        }

        fn nudgeSend(self: *Self) void {
            self.lock.lock();
            const sw = self.popSend() orelse {
                self.lock.unlock();
                return;
            };
            if (sw.done) {
                self.lock.unlock();
                return;
            }
            if (self.capacity > 0 and self.tryEnqueue(sw.value)) {
                sw.done = true;
                const parked = sw.parked;
                const peer = sw.task;
                self.lock.unlock();
                if (parked) wakeTask(peer);
                return;
            }
            self.send_q.pushBack(&sw.node);
            _ = self.send_waiters.fetchAdd(1, .release);
            self.lock.unlock();
        }

        pub fn send(self: *Self, value: T) Error!void {
            const me = requireTask();
            var cur = value;
            while (true) {
                if (self.closed_flag.load(.acquire) != 0) return error.Closed;

                if (self.capacity > 0 and self.recv_waiters.load(.acquire) == 0) {
                    if (self.tryEnqueue(cur)) {
                        if (self.recv_waiters.load(.acquire) != 0) self.nudgeRecv();
                        trace.emit(.chan_send, 1);
                        return;
                    }
                }

                self.lock.lock();

                if (self.closed) {
                    self.lock.unlock();
                    return error.Closed;
                }

                if (self.popRecv()) |rw| {
                    rw.value = cur;
                    rw.done = true;
                    const parked = rw.parked;
                    const peer = rw.task;
                    self.lock.unlock();
                    if (parked) wakeTask(peer);
                    trace.emit(.chan_send, 1);
                    return;
                }

                if (self.capacity > 0) {
                    if (self.tryEnqueue(cur)) {
                        self.lock.unlock();
                        if (self.recv_waiters.load(.acquire) != 0) self.nudgeRecv();
                        trace.emit(.chan_send, 1);
                        return;
                    }
                    switch (self.full_policy) {
                        .block => {},
                        .drop_newest => {
                            self.dropped += 1;
                            self.lock.unlock();
                            trace.emit(.chan_send, 2);
                            return;
                        },
                        .drop_oldest => {
                            _ = self.tryDequeue();
                            if (self.tryEnqueue(cur)) {
                                self.dropped += 1;
                                self.lock.unlock();
                                if (self.recv_waiters.load(.acquire) != 0) self.nudgeRecv();
                                trace.emit(.chan_send, 2);
                                return;
                            }
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
                    .value = cur,
                };
                self.send_q.pushBack(&waiter.node);
                _ = self.send_waiters.fetchAdd(1, .release);
                self.lock.unlock();

                if (waitUntilDone(self, &waiter)) {
                    if (waiter.closed) return error.Closed;
                    trace.emit(.chan_send, 1);
                    return;
                }
                cur = waiter.value;
            }
        }

        pub fn trySend(self: *Self, value: T) Error!void {
            if (self.closed_flag.load(.acquire) != 0) return error.Closed;

            if (self.capacity > 0 and self.recv_waiters.load(.acquire) == 0) {
                if (self.tryEnqueue(value)) {
                    if (self.recv_waiters.load(.acquire) != 0) self.nudgeRecv();
                    return;
                }
            }

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

            if (self.capacity > 0) {
                if (self.tryEnqueue(value)) {
                    self.lock.unlock();
                    if (self.recv_waiters.load(.acquire) != 0) self.nudgeRecv();
                    return;
                }
                switch (self.full_policy) {
                    .block => {},
                    .drop_newest => {
                        self.dropped += 1;
                        self.lock.unlock();
                        return;
                    },
                    .drop_oldest => {
                        _ = self.tryDequeue();
                        if (self.tryEnqueue(value)) {
                            self.dropped += 1;
                            self.lock.unlock();
                            if (self.recv_waiters.load(.acquire) != 0) self.nudgeRecv();
                            return;
                        }
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
                if (self.capacity > 0 and self.send_waiters.load(.acquire) == 0) {
                    if (self.tryDequeue()) |v| {
                        if (self.send_waiters.load(.acquire) != 0) self.nudgeSend();
                        trace.emit(.chan_recv, 1);
                        return v;
                    }
                }

                self.lock.lock();

                if (self.capacity > 0) {
                    if (self.tryDequeue()) |v| {
                        self.lock.unlock();
                        if (self.send_waiters.load(.acquire) != 0) self.nudgeSend();
                        trace.emit(.chan_recv, 1);
                        return v;
                    }
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
                _ = self.recv_waiters.fetchAdd(1, .release);
                self.lock.unlock();

                if (waitUntilDoneRecv(self, &waiter)) {
                    if (waiter.closed) return error.Closed;
                    trace.emit(.chan_recv, 1);
                    return waiter.value;
                }
            }
        }

        pub fn tryRecv(self: *Self) Error!T {
            if (self.capacity > 0 and self.send_waiters.load(.acquire) == 0) {
                if (self.tryDequeue()) |v| {
                    if (self.send_waiters.load(.acquire) != 0) self.nudgeSend();
                    return v;
                }
            }

            self.lock.lock();

            if (self.capacity > 0) {
                if (self.tryDequeue()) |v| {
                    self.lock.unlock();
                    if (self.send_waiters.load(.acquire) != 0) self.nudgeSend();
                    return v;
                }
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

            if (self.capacity > 0) {
                if (self.tryDequeue()) |v| {
                    self.lock.unlock();
                    if (self.send_waiters.load(.acquire) != 0) self.nudgeSend();
                    return .{ .value = v };
                }
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
            _ = self.recv_waiters.fetchAdd(1, .release);
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

            if (self.capacity > 0) {
                if (self.tryEnqueue(waiter.value)) {
                    waiter.done = true;
                    self.lock.unlock();
                    if (self.recv_waiters.load(.acquire) != 0) self.nudgeRecv();
                    return .sent;
                }
                switch (self.full_policy) {
                    .block => {},
                    .drop_newest => {
                        self.dropped += 1;
                        waiter.done = true;
                        self.lock.unlock();
                        return .sent;
                    },
                    .drop_oldest => {
                        _ = self.tryDequeue();
                        if (self.tryEnqueue(waiter.value)) {
                            self.dropped += 1;
                            waiter.done = true;
                            self.lock.unlock();
                            if (self.recv_waiters.load(.acquire) != 0) self.nudgeRecv();
                            return .sent;
                        }
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
            _ = self.send_waiters.fetchAdd(1, .release);
            self.lock.unlock();
            return .registered;
        }

        pub fn unregisterRecv(self: *Self, waiter: *RecvWaiter) bool {
            self.lock.lock();
            defer self.lock.unlock();
            if (waiter.done) return false;
            if (!waiter.node.linked) return false;
            self.recv_q.remove(&waiter.node);
            _ = self.recv_waiters.fetchSub(1, .release);
            return true;
        }

        pub fn unregisterSend(self: *Self, waiter: *SendWaiter) bool {
            self.lock.lock();
            defer self.lock.unlock();
            if (waiter.done) return false;
            if (!waiter.node.linked) return false;
            self.send_q.remove(&waiter.node);
            _ = self.send_waiters.fetchSub(1, .release);
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
            task_mod.wakeTask(t);
        }
    };
}
