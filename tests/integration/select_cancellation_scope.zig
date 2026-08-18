// SPDX-FileCopyrightText: 2026 Apanazar
//
// SPDX-License-Identifier: LGPL-3.0-or-later

const std = @import("std");
const zr = @import("zigroutines");

test "hierarchical cancel" {
    var parent = zr.CancelToken.initWithAllocator(std.testing.allocator);
    defer parent.deinit();
    var child = zr.CancelToken.initWithAllocator(std.testing.allocator);
    defer child.deinit();
    parent.linkChild(&child);
    parent.cancel();
    try std.testing.expect(child.isCanceled());
}

test "sleep wakes task" {
    if (comptime !zr.context.supported) return error.SkipZigTest;
    var rt = try zr.Runtime.init(std.testing.allocator, .{ .workers = 1 });
    defer rt.deinit();
    const S = struct {
        var ok: bool = false;
        fn work() void {
            zr.sleep(2 * std.time.ns_per_ms);
            ok = true;
        }
    };
    S.ok = false;
    _ = try rt.spawn(.{}, S.work, .{});
    try rt.run();
    try std.testing.expect(S.ok);
}

test "select recv timeout" {
    if (comptime !zr.context.supported) return error.SkipZigTest;
    var rt = try zr.Runtime.init(std.testing.allocator, .{ .workers = 1 });
    defer rt.deinit();
    const Ch = zr.Channel(u32);
    const ch = try Ch.create(std.testing.allocator, 1);
    defer ch.destroy();
    const S = struct {
        var got_timeout: bool = false;
        fn work(c: *Ch, timers: *zr.TimerQueue) void {
            const r = zr.select.recv(u32, c, .{
                .timeout_ns = 3 * std.time.ns_per_ms,
                .timers = timers,
            });
            got_timeout = (r == .timeout);
        }
    };
    S.got_timeout = false;
    _ = try rt.spawn(.{}, S.work, .{ ch, &rt.timers });
    try rt.run();
    try std.testing.expect(S.got_timeout);
}

test "select recv value before timeout" {
    if (comptime !zr.context.supported) return error.SkipZigTest;
    var rt = try zr.Runtime.init(std.testing.allocator, .{ .workers = 1 });
    defer rt.deinit();
    const Ch = zr.Channel(u32);
    const ch = try Ch.create(std.testing.allocator, 1);
    defer ch.destroy();
    const S = struct {
        var value: u32 = 0;
        fn producer(c: *Ch) void {
            zr.sleep(1 * std.time.ns_per_ms);
            c.send(99) catch unreachable;
        }
        fn consumer(c: *Ch, timers: *zr.TimerQueue) void {
            const r = zr.select.recv(u32, c, .{
                .timeout_ns = 50 * std.time.ns_per_ms,
                .timers = timers,
            });
            switch (r) {
                .value => |v| value = v,
                else => {},
            }
        }
    };
    S.value = 0;
    _ = try rt.spawn(.{}, S.producer, .{ch});
    _ = try rt.spawn(.{}, S.consumer, .{ ch, &rt.timers });
    try rt.run();
    try std.testing.expectEqual(@as(u32, 99), S.value);
}

test "select recvAny" {
    if (comptime !zr.context.supported) return error.SkipZigTest;
    var rt = try zr.Runtime.init(std.testing.allocator, .{ .workers = 1 });
    defer rt.deinit();
    const Ch = zr.Channel(usize);
    const a = try Ch.create(std.testing.allocator, 1);
    defer a.destroy();
    const b = try Ch.create(std.testing.allocator, 1);
    defer b.destroy();
    const S = struct {
        var idx: usize = 99;
        var val: usize = 0;
        fn work(ca: *Ch, cb: *Ch, timers: *zr.TimerQueue) void {
            cb.trySend(7) catch unreachable;
            const channels = [_]*Ch{ ca, cb };
            const r = zr.select.recvAny(usize, &channels, .{
                .timeout_ns = 10 * std.time.ns_per_ms,
                .timers = timers,
            });
            idx = r.index;
            switch (r.result) {
                .value => |v| val = v,
                else => {},
            }
        }
    };
    S.idx = 99;
    S.val = 0;
    _ = try rt.spawn(.{}, S.work, .{ a, b, &rt.timers });
    try rt.run();
    try std.testing.expectEqual(@as(usize, 1), S.idx);
    try std.testing.expectEqual(@as(usize, 7), S.val);
}

test "select canceled" {
    if (comptime !zr.context.supported) return error.SkipZigTest;
    var rt = try zr.Runtime.init(std.testing.allocator, .{ .workers = 1 });
    defer rt.deinit();
    const Ch = zr.Channel(u8);
    const ch = try Ch.create(std.testing.allocator, 0);
    defer ch.destroy();
    var token = zr.CancelToken.initWithAllocator(std.testing.allocator);
    defer token.deinit();
    const S = struct {
        var got_cancel: bool = false;
        fn waiter(c: *Ch, tok: *zr.CancelToken, timers: *zr.TimerQueue) void {
            const r = zr.select.recv(u8, c, .{
                .timeout_ns = 100 * std.time.ns_per_ms,
                .cancel = tok,
                .timers = timers,
            });
            got_cancel = (r == .canceled);
        }
        fn canceler(tok: *zr.CancelToken) void {
            zr.sleep(2 * std.time.ns_per_ms);
            tok.cancel();
        }
    };
    S.got_cancel = false;
    _ = try rt.spawn(.{}, S.waiter, .{ ch, &token, &rt.timers });
    _ = try rt.spawn(.{}, S.canceler, .{&token});
    try rt.run();
    try std.testing.expect(S.got_cancel);
}

test "scope joins children" {
    if (comptime !zr.context.supported) return error.SkipZigTest;
    var rt = try zr.Runtime.init(std.testing.allocator, .{ .workers = 1 });
    defer rt.deinit();
    const S = struct {
        var n: usize = 0;
        fn child() void {
            zr.sleep(1 * std.time.ns_per_ms);
            n += 1;
        }
        fn parent(runtime: *zr.Runtime) void {
            var sc = zr.Scope.init(runtime);
            sc.cancel_on_leave = false;
            defer sc.deinit();
            _ = sc.spawn(.{}, child, .{}) catch unreachable;
            _ = sc.spawn(.{}, child, .{}) catch unreachable;
            sc.joinAll();
        }
    };
    S.n = 0;
    _ = try rt.spawn(.{}, S.parent, .{&rt});
    try rt.run();
    try std.testing.expectEqual(@as(usize, 2), S.n);
}
