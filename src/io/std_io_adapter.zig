const std = @import("std");
const runtime_mod = @import("../core/runtime.zig");
const task_mod = @import("../core/task.zig");
const future_state = @import("async_future.zig");

const FutureState = future_state.FutureState;

pub const InitOptions = struct {
    threaded: std.Io.Threaded.InitOptions = .{},
};

pub const IoAdapter = struct {
    threaded: std.Io.Threaded,
    runtime: *runtime_mod.Runtime,
    allocator: std.mem.Allocator,
    vtable: std.Io.VTable,
    open_futures: std.ArrayListUnmanaged(*FutureState) = .empty,
    futures_lock: @import("../core/synchronization.zig").SpinLock = .{},

    pub fn init(allocator: std.mem.Allocator, runtime: *runtime_mod.Runtime, options: InitOptions) !IoAdapter {
        var self: IoAdapter = .{
            .threaded = .init(allocator, options.threaded),
            .runtime = runtime,
            .allocator = allocator,
            .vtable = undefined,
        };

        const base = self.threaded.io().vtable.*;
        self.vtable = base;
        self.vtable.async = vAsync;
        self.vtable.concurrent = vConcurrent;
        self.vtable.await = vAwait;
        self.vtable.cancel = vCancel;
        self.vtable.sleep = vSleep;
        self.vtable.checkCancel = vCheckCancel;

        return self;
    }

    pub fn deinit(self: *IoAdapter) void {
        self.futures_lock.lock();
        for (self.open_futures.items) |f| {
            f.destroy();
        }
        self.open_futures.deinit(self.allocator);
        self.futures_lock.unlock();

        self.threaded.deinit();
        self.* = undefined;
    }

    pub fn io(self: *IoAdapter) std.Io {
        return .{
            .userdata = self,
            .vtable = &self.vtable,
        };
    }

    fn track(self: *IoAdapter, f: *FutureState) void {
        self.futures_lock.lock();
        defer self.futures_lock.unlock();
        self.open_futures.append(self.allocator, f) catch {};
    }

    fn untrack(self: *IoAdapter, f: *FutureState) void {
        self.futures_lock.lock();
        defer self.futures_lock.unlock();
        for (self.open_futures.items, 0..) |item, i| {
            if (item == f) {
                _ = self.open_futures.orderedRemove(i);
                return;
            }
        }
    }
};

fn vAsync(
    userdata: ?*anyopaque,
    result: []u8,
    result_alignment: std.mem.Alignment,
    context: []const u8,
    context_alignment: std.mem.Alignment,
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,
) ?*std.Io.AnyFuture {
    const self: *IoAdapter = @ptrCast(@alignCast(userdata));
    return spawnFuture(self, result, result_alignment, context, context_alignment, start, false) catch {
        start(context.ptr, result.ptr);
        return null;
    };
}

fn vConcurrent(
    userdata: ?*anyopaque,
    result_len: usize,
    result_alignment: std.mem.Alignment,
    context: []const u8,
    context_alignment: std.mem.Alignment,
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,
) std.Io.ConcurrentError!*std.Io.AnyFuture {
    const self: *IoAdapter = @ptrCast(@alignCast(userdata));

    const dummy_result: []u8 = &.{};
    _ = dummy_result;

    const f = FutureState.create(
        self.allocator,
        result_len,
        result_alignment,
        context,
        context_alignment,
        start,
    ) catch return error.ConcurrencyUnavailable;

    const handle = self.runtime.spawn(.{}, futureTask, .{f}) catch {
        f.destroy();
        return error.ConcurrencyUnavailable;
    };
    f.join = handle;
    self.track(f);
    return @ptrCast(f);
}

fn vAwait(
    userdata: ?*anyopaque,
    any_future: *std.Io.AnyFuture,
    result: []u8,
    result_alignment: std.mem.Alignment,
) void {
    _ = result_alignment;
    const self: *IoAdapter = @ptrCast(@alignCast(userdata));
    const f: *FutureState = @ptrCast(@alignCast(any_future));
    f.join.join();
    const n = @min(result.len, f.result.len);
    @memcpy(result[0..n], f.result[0..n]);
    self.untrack(f);
    f.destroy();
}

fn vCancel(
    userdata: ?*anyopaque,
    any_future: *std.Io.AnyFuture,
    result: []u8,
    result_alignment: std.mem.Alignment,
) void {
    const f: *FutureState = @ptrCast(@alignCast(any_future));
    f.token.cancel();
    vAwait(userdata, any_future, result, result_alignment);
}

fn vSleep(userdata: ?*anyopaque, timeout: std.Io.Timeout) std.Io.Cancelable!void {
    const self: *IoAdapter = @ptrCast(@alignCast(userdata));
    if (task_mod.current() != null) {
        const ns = timeoutToNs(timeout, self) orelse return;
        self.runtime.sleep(ns);
        try vCheckCancel(userdata);
        return;
    }
    return self.threaded.io().vtable.sleep(@ptrCast(&self.threaded), timeout);
}

fn vCheckCancel(userdata: ?*anyopaque) std.Io.Cancelable!void {
    _ = userdata;
}

fn spawnFuture(
    self: *IoAdapter,
    result: []u8,
    result_alignment: std.mem.Alignment,
    context: []const u8,
    context_alignment: std.mem.Alignment,
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,
    must_concurrent: bool,
) !*std.Io.AnyFuture {
    _ = must_concurrent;
    const f = try FutureState.create(
        self.allocator,
        result.len,
        result_alignment,
        context,
        context_alignment,
        start,
    );
    errdefer f.destroy();

    const handle = try self.runtime.spawn(.{}, futureTask, .{f});
    f.join = handle;
    self.track(f);

    return @ptrCast(f);
}

fn futureTask(f: *FutureState) void {
    f.runBody();
}

fn timeoutToNs(timeout: std.Io.Timeout, self: *IoAdapter) ?u64 {
    const io = self.threaded.io();
    return switch (timeout) {
        .none => null,
        .duration => |d| blk: {
            if (d.raw.nanoseconds <= 0) break :blk @as(u64, 0);
            break :blk @intCast(d.raw.nanoseconds);
        },
        .deadline => |dl| blk: {
            const now = std.Io.Clock.boot.now(io);
            const rem = dl.raw.nanoseconds - now.nanoseconds;
            if (rem <= 0) break :blk @as(u64, 0);
            break :blk @intCast(rem);
        },
    };
}
