const std = @import("std");
const zr = @import("zigroutines");

test "buffered ping between two tasks" {
    if (comptime !zr.context.supported) return error.SkipZigTest;

    var rt = try zr.Runtime.init(std.testing.allocator, .{ .workers = 1 });
    defer rt.deinit();

    const Ch = zr.Channel(u32);
    const ch = try Ch.create(std.testing.allocator, 2);
    defer ch.destroy();

    const S = struct {
        var got: u32 = 0;
        fn producer(c: *Ch) void {
            c.send(7) catch unreachable;
            c.send(8) catch unreachable;
        }
        fn consumer(c: *Ch) void {
            got = c.recv() catch unreachable;
            got += c.recv() catch unreachable;
        }
    };
    S.got = 0;

    _ = try rt.spawn(.{}, S.producer, .{ch});
    _ = try rt.spawn(.{}, S.consumer, .{ch});
    try rt.run();
    try std.testing.expectEqual(@as(u32, 15), S.got);
}

test "rendezvous handoff" {
    if (comptime !zr.context.supported) return error.SkipZigTest;

    var rt = try zr.Runtime.init(std.testing.allocator, .{ .workers = 1 });
    defer rt.deinit();

    const Ch = zr.Channel(usize);
    const ch = try Ch.create(std.testing.allocator, 0);
    defer ch.destroy();

    const S = struct {
        var sum: usize = 0;
        fn producer(c: *Ch) void {
            var i: usize = 1;
            while (i <= 5) : (i += 1) {
                c.send(i) catch unreachable;
            }
        }
        fn consumer(c: *Ch) void {
            var i: usize = 0;
            while (i < 5) : (i += 1) {
                sum += c.recv() catch unreachable;
            }
        }
    };
    S.sum = 0;

    _ = try rt.spawn(.{}, S.producer, .{ch});
    _ = try rt.spawn(.{}, S.consumer, .{ch});
    try rt.run();
    try std.testing.expectEqual(@as(usize, 15), S.sum);
}

test "close returns Closed on send and drained recv" {
    if (comptime !zr.context.supported) return error.SkipZigTest;

    var rt = try zr.Runtime.init(std.testing.allocator, .{ .workers = 1 });
    defer rt.deinit();

    const Ch = zr.Channel(u8);
    const ch = try Ch.create(std.testing.allocator, 1);

    const S = struct {
        var send_closed: bool = false;
        var recv_closed: bool = false;
        var drained: u8 = 0;

        fn closer(c: *Ch) void {
            c.close();
        }

        fn sender(c: *Ch) void {
            zr.yield();
            c.send(1) catch |err| {
                send_closed = (err == error.Closed);
                return;
            };
        }

        fn receiver(c: *Ch) void {
            while (true) {
                const v = c.recv() catch |err| {
                    recv_closed = (err == error.Closed);
                    return;
                };
                drained = v;
            }
        }
    };
    S.send_closed = false;
    S.recv_closed = false;
    S.drained = 0;

    _ = try rt.spawn(.{}, S.closer, .{ch});
    _ = try rt.spawn(.{}, S.sender, .{ch});
    _ = try rt.spawn(.{}, S.receiver, .{ch});
    try rt.run();
    ch.destroy();

    try std.testing.expect(S.send_closed);
    try std.testing.expect(S.recv_closed);
}

test "trySend tryRecv" {
    if (comptime !zr.context.supported) return error.SkipZigTest;

    var rt = try zr.Runtime.init(std.testing.allocator, .{ .workers = 1 });
    defer rt.deinit();

    const Ch = zr.Channel(i32);
    const ch = try Ch.create(std.testing.allocator, 1);
    defer ch.destroy();

    const S = struct {
        var ok: bool = false;
        fn body(c: *Ch) void {
            c.trySend(42) catch unreachable;
            const wb = c.trySend(99);
            if (wb != error.WouldBlock) unreachable;
            const v = c.tryRecv() catch unreachable;
            if (v != 42) unreachable;
            const empty = c.tryRecv();
            if (empty != error.WouldBlock) unreachable;
            ok = true;
        }
    };
    S.ok = false;

    _ = try rt.spawn(.{}, S.body, .{ch});
    try rt.run();
    try std.testing.expect(S.ok);
}

test "pipeline many messages single-thread" {
    if (comptime !zr.context.supported) return error.SkipZigTest;

    var rt = try zr.Runtime.init(std.testing.allocator, .{ .workers = 1, .stack_pool = true });
    defer rt.deinit();

    const Ch = zr.Channel(usize);
    const ch = try Ch.create(std.testing.allocator, 8);
    defer ch.destroy();

    const N: usize = 1000;
    const S = struct {
        var sum: usize = 0;
        fn producer(c: *Ch) void {
            var i: usize = 0;
            while (i < N) : (i += 1) {
                c.send(i) catch unreachable;
            }
            c.close();
        }
        fn consumer(c: *Ch) void {
            while (true) {
                const v = c.recv() catch |err| switch (err) {
                    error.Closed => break,
                    else => unreachable,
                };
                sum += v;
            }
        }
    };
    S.sum = 0;

    _ = try rt.spawn(.{}, S.producer, .{ch});
    _ = try rt.spawn(.{}, S.consumer, .{ch});
    try rt.run();
    try std.testing.expectEqual(N * (N - 1) / 2, S.sum);
}

test "multi-thread mpmc" {
    if (comptime !zr.context.supported) return error.SkipZigTest;

    var rt = try zr.Runtime.init(std.testing.allocator, .{ .workers = 4, .stack_pool = true });
    defer rt.deinit();

    const Ch = zr.Channel(usize);
    const ch = try Ch.create(std.testing.allocator, 64);
    defer ch.destroy();

    const producers: usize = 4;
    const per_prod: usize = 50;
    const total = producers * per_prod;

    const S = struct {
        var received: std.atomic.Value(usize) = .init(0);
        var sum: std.atomic.Value(usize) = .init(0);
        var producers_done: std.atomic.Value(usize) = .init(0);

        fn producer(c: *Ch, base: usize) void {
            var i: usize = 0;
            while (i < per_prod) : (i += 1) {
                c.send(base + i) catch unreachable;
            }
            if (producers_done.fetchAdd(1, .monotonic) + 1 == producers) {
                c.close();
            }
        }

        fn consumer(c: *Ch) void {
            while (true) {
                const v = c.recv() catch |err| switch (err) {
                    error.Closed => break,
                    else => unreachable,
                };
                _ = sum.fetchAdd(v, .monotonic);
                _ = received.fetchAdd(1, .monotonic);
            }
        }
    };
    S.received.store(0, .monotonic);
    S.sum.store(0, .monotonic);
    S.producers_done.store(0, .monotonic);

    var p: usize = 0;
    while (p < producers) : (p += 1) {
        _ = try rt.spawn(.{}, S.producer, .{ ch, p * per_prod });
    }
    var c: usize = 0;
    while (c < 4) : (c += 1) {
        _ = try rt.spawn(.{}, S.consumer, .{ch});
    }

    try rt.run();

    try std.testing.expectEqual(total, S.received.load(.monotonic));
    try std.testing.expectEqual(total * (total - 1) / 2, S.sum.load(.monotonic));
}
