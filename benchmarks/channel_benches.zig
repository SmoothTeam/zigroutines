const std = @import("std");
const zr = @import("zigroutines");
const common = @import("common.zig");

pub fn runAll(alloc: std.mem.Allocator) !void {
    try channelPipeline(alloc);
    try channelRendezvous(alloc);
    try channelMpmc(alloc);
    try channelUncontended(alloc);
    try channelCreate(alloc);
    try channelClosedRecv(alloc);
    try channelProdConsWork(alloc);
    try channelPopular(alloc);
    try channelSem(alloc);
    try actorMailbox(alloc);
}

fn channelPipeline(alloc: std.mem.Allocator) !void {
    const n: usize = 200_000;
    var rt = try zr.Runtime.init(alloc, .{ .workers = 1, .stack_pool = true });
    defer rt.deinit();

    const Ch = zr.Channel(usize);
    const ch = try Ch.create(alloc, 256);
    defer ch.destroy();

    const S = struct {
        fn producer(c: *Ch, count: usize) void {
            var i: usize = 0;
            while (i < count) : (i += 1) c.send(i) catch return;
            c.close();
        }
        fn consumer(c: *Ch) void {
            while (true) {
                _ = c.recv() catch break;
            }
        }
    };
    _ = try rt.spawn(.{}, S.producer, .{ ch, n });
    _ = try rt.spawn(.{}, S.consumer, .{ch});

    const t0 = common.nowNs();
    try rt.run();
    const t1 = common.nowNs();
    common.printRate("chan_pipeline_buf256", n, t1 - t0);
}

fn channelRendezvous(alloc: std.mem.Allocator) !void {
    const n: usize = 100_000;
    var rt = try zr.Runtime.init(alloc, .{ .workers = 1, .stack_pool = true });
    defer rt.deinit();

    const Ch = zr.Channel(usize);
    const ch = try Ch.create(alloc, 0);
    defer ch.destroy();

    const S = struct {
        fn producer(c: *Ch, count: usize) void {
            var i: usize = 0;
            while (i < count) : (i += 1) c.send(i) catch return;
            c.close();
        }
        fn consumer(c: *Ch) void {
            while (true) {
                _ = c.recv() catch break;
            }
        }
    };
    _ = try rt.spawn(.{}, S.producer, .{ ch, n });
    _ = try rt.spawn(.{}, S.consumer, .{ch});

    const t0 = common.nowNs();
    try rt.run();
    const t1 = common.nowNs();
    common.printRate("chan_rendezvous", n, t1 - t0);
}

fn channelMpmc(alloc: std.mem.Allocator) !void {
    const producers: usize = 4;
    const consumers: usize = 4;
    const per: usize = 25_000;
    const total = producers * per;

    var rt = try zr.Runtime.init(alloc, .{
        .workers = 4,
        .policy = .work_stealing,
        .stack_pool = true,
    });
    defer rt.deinit();

    const Ch = zr.Channel(usize);
    const ch = try Ch.create(alloc, 1024);
    defer ch.destroy();

    const S = struct {
        var done: std.atomic.Value(usize) = .init(0);
        fn producer(c: *Ch, count: usize) void {
            var i: usize = 0;
            while (i < count) : (i += 1) c.send(i) catch return;
            if (done.fetchAdd(1, .monotonic) + 1 == producers) c.close();
        }
        fn consumer(c: *Ch) void {
            while (true) {
                _ = c.recv() catch break;
            }
        }
    };
    S.done.store(0, .monotonic);

    var p: usize = 0;
    while (p < producers) : (p += 1) {
        _ = try rt.spawn(.{}, S.producer, .{ ch, per });
    }
    var c: usize = 0;
    while (c < consumers) : (c += 1) {
        _ = try rt.spawn(.{}, S.consumer, .{ch});
    }

    const t0 = common.nowNs();
    try rt.run();
    const t1 = common.nowNs();
    common.printRate("chan_mpmc_4x4", total, t1 - t0);
}

fn channelUncontended(alloc: std.mem.Allocator) !void {
    const n: usize = 500_000;
    var rt = try zr.Runtime.init(alloc, .{ .workers = 1, .stack_pool = true });
    defer rt.deinit();

    const Ch = zr.Channel(usize);
    const ch = try Ch.create(alloc, 1);
    defer ch.destroy();

    const S = struct {
        fn work(c: *Ch, count: usize) void {
            var i: usize = 0;
            while (i < count) : (i += 1) {
                c.trySend(i) catch {};
                _ = c.tryRecv() catch {};
            }
        }
    };
    _ = try rt.spawn(.{}, S.work, .{ ch, n });

    const t0 = common.nowNs();
    try rt.run();
    const t1 = common.nowNs();
    common.printRate("chan_try_uncontended", n, t1 - t0);
}

fn channelCreate(alloc: std.mem.Allocator) !void {
    const n: usize = 50_000;
    const Ch = zr.Channel(usize);

    const t0 = common.nowNs();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const ch = try Ch.createWith(alloc, 8, .{ .recycle = false });
        ch.destroy();
    }
    const t1 = common.nowNs();
    common.printRate("chan_create_buf8", n, t1 - t0);

    const t2 = common.nowNs();
    i = 0;
    while (i < n) : (i += 1) {
        const ch = try Ch.createPooled(alloc, 8);
        ch.destroy();
    }
    const t3 = common.nowNs();
    common.printRate("chan_create_buf8_pooled", n, t3 - t2);
}

fn channelClosedRecv(alloc: std.mem.Allocator) !void {
    const n: usize = 100_000;
    var rt = try zr.Runtime.init(alloc, .{ .workers = 1, .stack_pool = true });
    defer rt.deinit();

    const Ch = zr.Channel(usize);
    const ch = try Ch.create(alloc, n);
    defer ch.destroy();

    const S = struct {
        fn work(c: *Ch, count: usize) void {
            var i: usize = 0;
            while (i < count) : (i += 1) c.trySend(i) catch {};
            c.close();
            i = 0;
            while (i < count) : (i += 1) {
                _ = c.recv() catch break;
            }
        }
    };
    _ = try rt.spawn(.{}, S.work, .{ ch, n });

    const t0 = common.nowNs();
    try rt.run();
    const t1 = common.nowNs();
    common.printRate("chan_closed_drain", n, t1 - t0);
}

fn channelProdConsWork(alloc: std.mem.Allocator) !void {
    const n: usize = 50_000;
    const local_work: usize = 100;
    var rt = try zr.Runtime.init(alloc, .{ .workers = 1, .stack_pool = true });
    defer rt.deinit();

    const Ch = zr.Channel(usize);
    const ch = try Ch.create(alloc, 64);
    defer ch.destroy();

    const S = struct {
        fn spin(w: usize) void {
            var foo: usize = 0;
            var i: usize = 0;
            while (i < w) : (i += 1) {
                foo *%= 2;
                foo /= 2;
            }
            std.mem.doNotOptimizeAway(foo);
        }
        fn producer(c: *Ch, count: usize, work: usize) void {
            var i: usize = 0;
            while (i < count) : (i += 1) {
                spin(work);
                c.send(i) catch return;
            }
            c.close();
        }
        fn consumer(c: *Ch, work: usize) void {
            while (true) {
                _ = c.recv() catch break;
                spin(work);
            }
        }
    };
    _ = try rt.spawn(.{}, S.producer, .{ ch, n, local_work });
    _ = try rt.spawn(.{}, S.consumer, .{ ch, local_work });

    const t0 = common.nowNs();
    try rt.run();
    const t1 = common.nowNs();
    common.printRate("chan_prodcons_work", n, t1 - t0);
}

fn channelPopular(alloc: std.mem.Allocator) !void {
    const waiters: usize = 256;
    const msgs: usize = 1_000;
    var rt = try zr.Runtime.init(alloc, .{ .workers = 1, .stack_pool = true });
    defer rt.deinit();

    const Ch = zr.Channel(usize);
    const ch = try Ch.create(alloc, 0);
    defer ch.destroy();

    const S = struct {
        fn waiter(c: *Ch, count: usize) void {
            var i: usize = 0;
            while (i < count) : (i += 1) {
                _ = c.recv() catch return;
            }
        }
        fn feeder(c: *Ch, total: usize) void {
            var i: usize = 0;
            while (i < total) : (i += 1) {
                c.send(i) catch return;
            }
            c.close();
        }
    };

    var w: usize = 0;
    while (w < waiters) : (w += 1) {
        _ = try rt.spawn(.{}, S.waiter, .{ ch, msgs });
    }
    _ = try rt.spawn(.{}, S.feeder, .{ ch, waiters * msgs });

    const t0 = common.nowNs();
    try rt.run();
    const t1 = common.nowNs();
    common.printRate("chan_popular_256", waiters * msgs, t1 - t0);
}

fn channelSem(alloc: std.mem.Allocator) !void {
    const n: usize = 100_000;
    var rt = try zr.Runtime.init(alloc, .{ .workers = 1, .stack_pool = true });
    defer rt.deinit();

    const Ch = zr.Channel(u8);
    const ch = try Ch.create(alloc, 1);
    defer ch.destroy();

    const S = struct {
        fn work(c: *Ch, count: usize) void {
            var i: usize = 0;
            while (i < count) : (i += 1) {
                c.send(0) catch return;
                _ = c.recv() catch return;
            }
        }
    };
    _ = try rt.spawn(.{}, S.work, .{ ch, n });

    const t0 = common.nowNs();
    try rt.run();
    const t1 = common.nowNs();
    common.printRate("chan_sem", n, t1 - t0);
}

fn actorMailbox(alloc: std.mem.Allocator) !void {
    const n: usize = 50_000;
    var rt = try zr.Runtime.init(alloc, .{ .workers = 1, .stack_pool = true });
    defer rt.deinit();

    const S = struct {
        var sum: u64 = 0;
        fn handle(msg: u64) void {
            sum +%= msg;
        }
        fn driver(r: *zr.Runtime, count: usize) void {
            const A = zr.Actor(u64);
            const actor = A.spawn(r, .{ .mailbox_capacity = 256 }, handle) catch return;
            var i: u64 = 0;
            while (i < count) : (i += 1) {
                actor.send(i) catch break;
            }
            actor.mailbox.close();
            actor.join();
            actor.destroy();
        }
    };
    S.sum = 0;
    _ = try rt.spawn(.{}, S.driver, .{ &rt, n });

    const t0 = common.nowNs();
    try rt.run();
    const t1 = common.nowNs();
    common.printRate("actor_mailbox", n, t1 - t0);
}
