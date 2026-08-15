// SPDX-FileCopyrightText: 2026 Apanazar
//
// SPDX-License-Identifier: LGPL-3.0-or-later

const std = @import("std");
const task_mod = @import("../core/task.zig");
const cancel_mod = @import("../core/cancellation.zig");
const timer_mod = @import("../core/timer_queue.zig");
const channel_mod = @import("channel.zig");
const trace = @import("../core/tracing.zig");

pub const Fairness = enum { random, fifo };
pub const default_fairness: Fairness = .random;
pub const max_arms: usize = 32;

pub const Opts = struct {
    timeout_ns: ?u64 = null,
    cancel: ?*cancel_mod.CancelToken = null,
    timers: ?*timer_mod.TimerQueue = null,
    fairness: Fairness = default_fairness,
};

pub fn RecvResult(comptime T: type) type {
    return union(enum) {
        value: T,
        timeout,
        canceled,
        closed,
    };
}

pub fn SendOp(comptime T: type) type {
    return struct {
        ch: *channel_mod.Channel(T),
        value: T,
    };
}

pub fn MultiOpts(comptime T: type) type {
    return struct {
        recv: []const *channel_mod.Channel(T) = &.{},
        send: []const SendOp(T) = &.{},
        default: bool = false,
    };
}

pub fn MultiResult(comptime T: type) type {
    return union(enum) {
        recv: struct { index: usize, value: T },
        send: struct { index: usize },
        closed_recv: usize,
        closed_send: usize,
        full_send: usize,
        timeout,
        canceled,
        default,
    };
}

pub fn recv(comptime T: type, ch: *channel_mod.Channel(T), opts: Opts) RecvResult(T) {
    const me = task_mod.current() orelse @panic("zigroutines: select outside a task");
    if (opts.cancel) |tok| {
        if (tok.isCanceled()) return .canceled;
    }

    if (ch.tryRecv()) |v| {
        return .{ .value = v };
    } else |err| switch (err) {
        error.Closed => return .closed,
        error.WouldBlock, error.Full => {},
    }
    if (opts.timeout_ns == null and opts.cancel == null) {
        const v = ch.recv() catch |e| switch (e) {
            error.Closed => return .closed,
            else => return .closed,
        };
        return .{ .value = v };
    }

    var waiter: channel_mod.Channel(T).RecvWaiter = .{ .task = me };
    switch (ch.tryRecvOrRegister(&waiter)) {
        .value => |v| return .{ .value = v },
        .closed => return .closed,
        .registered => {},
    }

    var timer_entry: timer_mod.TimerEntry = undefined;
    var has_timer = false;
    if (opts.timeout_ns) |ns| {
        const tq = opts.timers orelse @panic("zigroutines: select timeout requires timers");
        timer_entry = .{
            .deadline_ns = timer_mod.nowNs() + @as(i128, @intCast(ns)),
            .task = me,
        };
        tq.add(&timer_entry);
        has_timer = true;
    }

    if (opts.cancel) |tok| {
        tok.addWaiter(me);
        if (tok.isCanceled()) {
            _ = ch.unregisterRecv(&waiter);
            if (has_timer) {
                timer_entry.canceled = true;
                if (opts.timers) |tq| tq.remove(&timer_entry);
            }
            tok.removeWaiter(me);
            return .canceled;
        }
    }

    const already = ch.markRecvParked(&waiter);
    if (has_timer) {
        if (opts.timers) |tq| {
            tq.lock.lock();
            if (!timer_entry.done) timer_entry.parked = true;
            tq.lock.unlock();
        }
    }
    if (!already) {
        const ex = me.executor orelse @panic("zigroutines: select without executor");
        ex.parkFromRunning(.chan_recv);
    }

    if (opts.cancel) |tok| {
        tok.removeWaiter(me);
        if (tok.isCanceled()) {
            _ = ch.unregisterRecv(&waiter);
            if (has_timer) {
                timer_entry.canceled = true;
                if (opts.timers) |tq| tq.remove(&timer_entry);
            }
            return .canceled;
        }
    }

    if (waiter.done) {
        if (has_timer) {
            timer_entry.canceled = true;
            if (opts.timers) |tq| tq.remove(&timer_entry);
        }
        if (waiter.closed) return .closed;
        return .{ .value = waiter.value };
    }

    if (has_timer and timer_entry.done) {
        _ = ch.unregisterRecv(&waiter);
        return .timeout;
    }

    _ = ch.unregisterRecv(&waiter);
    if (has_timer) {
        timer_entry.canceled = true;
        if (opts.timers) |tq| tq.remove(&timer_entry);
    }
    return .timeout;
}

pub fn recvAny(comptime T: type, channels: []const *channel_mod.Channel(T), opts: Opts) struct {
    index: usize,
    result: RecvResult(T),
} {
    const r = multi(T, .{ .recv = channels }, opts);
    return switch (r) {
        .recv => |x| .{ .index = x.index, .result = .{ .value = x.value } },
        .closed_recv => |i| .{ .index = i, .result = .closed },
        .timeout => .{ .index = 0, .result = .timeout },
        .canceled => .{ .index = 0, .result = .canceled },
        else => .{ .index = 0, .result = .timeout },
    };
}

pub fn multi(comptime T: type, arms: MultiOpts(T), opts: Opts) MultiResult(T) {
    const me = task_mod.current() orelse @panic("zigroutines: select outside a task");
    trace.emit(.select_enter, arms.recv.len + arms.send.len);

    if (opts.cancel) |tok| {
        if (tok.isCanceled()) {
            trace.emit(.select_leave, 0);
            return .canceled;
        }
    }

    if (arms.recv.len > max_arms or arms.send.len > max_arms) {
        @panic("zigroutines: select.multi supports at most 32 arms per kind");
    }
    if (arms.recv.len == 0 and arms.send.len == 0) {
        if (arms.default) {
            trace.emit(.select_leave, 1);
            return .default;
        }
        @panic("zigroutines: select.multi with no arms");
    }

    if (tryReady(T, arms, opts.fairness)) |hit| {
        trace.emit(.select_leave, 2);
        return hit;
    }

    if (arms.default) {
        trace.emit(.select_leave, 1);
        return .default;
    }

    const alloc = me.allocator;
    const n_recv = arms.recv.len;
    const n_send = arms.send.len;

    var recv_w: []channel_mod.Channel(T).RecvWaiter = &.{};
    var send_w: []channel_mod.Channel(T).SendWaiter = &.{};
    var recv_reg: []bool = &.{};
    var send_reg: []bool = &.{};
    defer {
        if (recv_w.len != 0) alloc.free(recv_w);
        if (send_w.len != 0) alloc.free(send_w);
        if (recv_reg.len != 0) alloc.free(recv_reg);
        if (send_reg.len != 0) alloc.free(send_reg);
    }
    if (n_recv > 0) {
        recv_w = alloc.alloc(channel_mod.Channel(T).RecvWaiter, n_recv) catch @panic("zigroutines: OOM select recv waiters");
        recv_reg = alloc.alloc(bool, n_recv) catch @panic("zigroutines: OOM select recv reg");
        @memset(recv_reg, false);
    }
    if (n_send > 0) {
        send_w = alloc.alloc(channel_mod.Channel(T).SendWaiter, n_send) catch @panic("zigroutines: OOM select send waiters");
        send_reg = alloc.alloc(bool, n_send) catch @panic("zigroutines: OOM select send reg");
        @memset(send_reg, false);
    }

    for (arms.recv, 0..) |ch, i| {
        recv_w[i] = .{ .task = me };
        switch (ch.tryRecvOrRegister(&recv_w[i])) {
            .value => |v| {
                cleanupPartial(T, arms, recv_w, send_w, recv_reg, send_reg, i, 0, null, opts);
                trace.emit(.select_leave, 2);
                return .{ .recv = .{ .index = i, .value = v } };
            },
            .closed => {
                cleanupPartial(T, arms, recv_w, send_w, recv_reg, send_reg, i, 0, null, opts);
                trace.emit(.select_leave, 3);
                return .{ .closed_recv = i };
            },
            .registered => recv_reg[i] = true,
        }
    }

    for (arms.send, 0..) |op, i| {
        send_w[i] = .{ .task = me, .value = op.value };
        switch (op.ch.trySendOrRegister(&send_w[i])) {
            .sent => {
                cleanupPartial(T, arms, recv_w, send_w, recv_reg, send_reg, n_recv, i, null, opts);
                trace.emit(.select_leave, 2);
                return .{ .send = .{ .index = i } };
            },
            .closed => {
                cleanupPartial(T, arms, recv_w, send_w, recv_reg, send_reg, n_recv, i, null, opts);
                return .{ .closed_send = i };
            },
            .full => {
                cleanupPartial(T, arms, recv_w, send_w, recv_reg, send_reg, n_recv, i, null, opts);
                return .{ .full_send = i };
            },
            .registered => send_reg[i] = true,
        }
    }

    var timer_entry: timer_mod.TimerEntry = undefined;
    var has_timer = false;
    if (opts.timeout_ns) |ns| {
        const tq = opts.timers orelse @panic("zigroutines: select timeout requires timers");
        timer_entry = .{
            .deadline_ns = timer_mod.nowNs() + @as(i128, @intCast(ns)),
            .task = me,
        };
        tq.add(&timer_entry);
        has_timer = true;
    }

    if (opts.cancel) |tok| {
        tok.addWaiter(me);
        if (tok.isCanceled()) {
            cleanupAll(T, arms, recv_w, send_w, recv_reg, send_reg, if (has_timer) &timer_entry else null, opts);
            return .canceled;
        }
    }

    var any_done = false;
    for (arms.recv, 0..) |ch, i| {
        if (recv_reg[i] and ch.markRecvParked(&recv_w[i])) any_done = true;
    }
    for (arms.send, 0..) |op, i| {
        if (send_reg[i] and op.ch.markSendParked(&send_w[i])) any_done = true;
    }

    if (has_timer) {
        if (opts.timers) |tq| {
            tq.lock.lock();
            if (!timer_entry.done) timer_entry.parked = true;
            tq.lock.unlock();
        }
    }

    if (!any_done) {
        const ex = me.executor orelse @panic("zigroutines: select without executor");
        ex.parkFromRunning(.chan_recv);
    }

    if (opts.cancel) |tok| {
        tok.removeWaiter(me);
        if (tok.isCanceled()) {
            cleanupAll(T, arms, recv_w, send_w, recv_reg, send_reg, if (has_timer) &timer_entry else null, opts);
            return .canceled;
        }
    }

    var ready_recv: [max_arms]usize = undefined;
    var ready_send: [max_arms]usize = undefined;
    var n_rr: usize = 0;
    var n_rs: usize = 0;

    for (0..n_recv) |i| {
        if (recv_reg[i] and recv_w[i].done) {
            ready_recv[n_rr] = i;
            n_rr += 1;
        }
    }
    for (0..n_send) |i| {
        if (send_reg[i] and send_w[i].done) {
            ready_send[n_rs] = i;
            n_rs += 1;
        }
    }

    if (n_rr + n_rs > 0) {
        const pick_recv = if (n_rr > 0 and n_rs > 0)
            (if (opts.fairness == .random) (simpleRand() % 2 == 0) else true)
        else
            n_rr > 0;

        if (pick_recv and n_rr > 0) {
            const idx = if (opts.fairness == .random and n_rr > 1)
                ready_recv[simpleRand() % n_rr]
            else
                ready_recv[0];
            const closed = recv_w[idx].closed;
            const val = recv_w[idx].value;
            cleanupAllExcept(T, arms, recv_w, send_w, recv_reg, send_reg, .{ .recv = idx }, if (has_timer) &timer_entry else null, opts);
            if (closed) return .{ .closed_recv = idx };
            return .{ .recv = .{ .index = idx, .value = val } };
        } else if (n_rs > 0) {
            const idx = if (opts.fairness == .random and n_rs > 1)
                ready_send[simpleRand() % n_rs]
            else
                ready_send[0];
            const closed = send_w[idx].closed;
            cleanupAllExcept(T, arms, recv_w, send_w, recv_reg, send_reg, .{ .send = idx }, if (has_timer) &timer_entry else null, opts);
            if (closed) return .{ .closed_send = idx };
            return .{ .send = .{ .index = idx } };
        }
    }

    if (has_timer and timer_entry.done) {
        cleanupAll(T, arms, recv_w, send_w, recv_reg, send_reg, &timer_entry, opts);
        return .timeout;
    }

    cleanupAll(T, arms, recv_w, send_w, recv_reg, send_reg, if (has_timer) &timer_entry else null, opts);
    return .timeout;
}

fn tryReady(comptime T: type, arms: MultiOpts(T), fairness: Fairness) ?MultiResult(T) {
    _ = fairness;
    var closed_recv: ?usize = null;
    var closed_send: ?usize = null;

    for (arms.recv, 0..) |ch, i| {
        if (ch.tryRecv()) |v| {
            return .{ .recv = .{ .index = i, .value = v } };
        } else |err| switch (err) {
            error.Closed => {
                if (closed_recv == null) closed_recv = i;
            },
            error.WouldBlock, error.Full => {},
        }
    }
    for (arms.send, 0..) |op, i| {
        if (op.ch.trySend(op.value)) {
            return .{ .send = .{ .index = i } };
        } else |err| switch (err) {
            error.Closed => {
                if (closed_send == null) closed_send = i;
            },
            error.WouldBlock, error.Full => {},
        }
    }

    if (closed_recv) |i| return .{ .closed_recv = i };
    if (closed_send) |i| return .{ .closed_send = i };
    return null;
}

const Keep = union(enum) {
    recv: usize,
    send: usize,
    none,
};

fn cleanupPartial(
    comptime T: type,
    arms: MultiOpts(T),
    recv_w: []channel_mod.Channel(T).RecvWaiter,
    send_w: []channel_mod.Channel(T).SendWaiter,
    recv_reg: []bool,
    send_reg: []bool,
    recv_end: usize,
    send_end: usize,
    timer_entry: ?*timer_mod.TimerEntry,
    opts: Opts,
) void {
    var i: usize = 0;
    while (i < recv_end) : (i += 1) {
        if (recv_reg[i]) {
            _ = arms.recv[i].unregisterRecv(&recv_w[i]);
            recv_reg[i] = false;
        }
    }
    i = 0;
    while (i < send_end) : (i += 1) {
        if (send_reg[i]) {
            _ = arms.send[i].ch.unregisterSend(&send_w[i]);
            send_reg[i] = false;
        }
    }
    if (timer_entry) |te| {
        te.canceled = true;
        if (opts.timers) |tq| tq.remove(te);
    }
}

fn cleanupAll(
    comptime T: type,
    arms: MultiOpts(T),
    recv_w: []channel_mod.Channel(T).RecvWaiter,
    send_w: []channel_mod.Channel(T).SendWaiter,
    recv_reg: []bool,
    send_reg: []bool,
    timer_entry: ?*timer_mod.TimerEntry,
    opts: Opts,
) void {
    for (arms.recv, 0..) |ch, i| {
        if (recv_reg[i]) {
            _ = ch.unregisterRecv(&recv_w[i]);
            recv_reg[i] = false;
        }
    }
    for (arms.send, 0..) |op, i| {
        if (send_reg[i]) {
            _ = op.ch.unregisterSend(&send_w[i]);
            send_reg[i] = false;
        }
    }
    if (timer_entry) |te| {
        te.canceled = true;
        if (opts.timers) |tq| tq.remove(te);
    }
    if (opts.cancel) |tok| {
        if (task_mod.current()) |me| tok.removeWaiter(me);
    }
}

fn cleanupAllExcept(
    comptime T: type,
    arms: MultiOpts(T),
    recv_w: []channel_mod.Channel(T).RecvWaiter,
    send_w: []channel_mod.Channel(T).SendWaiter,
    recv_reg: []bool,
    send_reg: []bool,
    keep: Keep,
    timer_entry: ?*timer_mod.TimerEntry,
    opts: Opts,
) void {
    for (arms.recv, 0..) |ch, i| {
        if (keep == .recv and keep.recv == i) continue;
        if (recv_reg[i]) {
            _ = ch.unregisterRecv(&recv_w[i]);
            recv_reg[i] = false;
        }
    }
    for (arms.send, 0..) |op, i| {
        if (keep == .send and keep.send == i) continue;
        if (send_reg[i]) {
            _ = op.ch.unregisterSend(&send_w[i]);
            send_reg[i] = false;
        }
    }
    if (timer_entry) |te| {
        te.canceled = true;
        if (opts.timers) |tq| tq.remove(te);
    }
}

var rng_state: u64 = 0xC0FFEE;

fn simpleRand() usize {
    // xorshift64*
    var x = rng_state;
    if (x == 0) x = @as(u64, @truncate(@as(u128, @bitCast(timer_mod.nowNs())))) | 1;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    rng_state = x;
    return @intCast(x *% 0x2545F4914F6CDD1D);
}
