const std = @import("std");
const zio = @import("zio");
const common = @import("common");

pub fn main(init: std.process.Init) !void {
    common.init(init.io);
    const allocator = init.gpa;
    std.debug.print("peer-zio  zig=0.17  (priority_dispatch = FIFO; pooled create = stack Channel.init)\n", .{});

    std.debug.print("--- fiber / spawn ---\n", .{});
    try ctxSwitchBounce(allocator);
    try yieldPingPong(allocator);
    try yieldSingle(allocator);
    try yieldWs4(allocator);
    try leafSpawnBatch(allocator);
    try spawnJoin(allocator);
    try spawnResultJoin(allocator);
    try nurseryJoin(allocator);
    try priorityDispatch(allocator);
    try skynetJoin(allocator);
    try nTasks(allocator, 1_000);
    try nTasks(allocator, 10_000);
    try nTasks(allocator, 50_000);

    std.debug.print("--- channel / actor ---\n", .{});
    try chanPipeline(allocator);
    try chanRendezvous(allocator);
    try chanMpmc(allocator);
    try chanTry(allocator);
    try chanCreate(allocator);
    try chanCreatePooled(allocator);
    try chanClosedDrain(allocator);
    try chanProdConsWork(allocator);
    try chanPopular(allocator);
    try chanSem(allocator);
    try actorMailbox(allocator);

    std.debug.print("--- select ---\n", .{});
    try selectFanin(allocator);
    try selectUncontended(allocator);
    try selectNonblock(allocator);
    try selectSyncContended(allocator);

    std.debug.print("--- sync / timers ---\n", .{});
    try mutexUncontended(allocator);
    try mutexContended(allocator);
    try semHandoff(allocator);
    try rwlockShared(allocator);
    try rwlockExclusive(allocator);
    try sleepBatch(allocator);
    try timerMany(allocator);

    std.debug.print("--- io ---\n", .{});
    try tcpPingPong(allocator);
    try udpPing(allocator);

    std.debug.print("---\ndone\n", .{});
    std.debug.print("note: priority_dispatch is FIFO spawn (zio has no priority scheduler)\n", .{});
}

fn joinOk(h: anytype) void {
    var handle = h;
    const result = handle.join();
    switch (@typeInfo(@TypeOf(result))) {
        .error_union => _ = result catch {},
        else => {},
    }
}

fn compactOpts(executors: u8) zio.RuntimeOptions {
    return .{
        .executors = .exact(executors),
        .stack_pool = .{
            .maximum_size = 64 * 1024,
            .committed_size = 16 * 1024,
        },
    };
}

fn ctxA(ch: *zio.Channel(u8), n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        try ch.send(0);
        _ = try ch.receive();
    }
}
fn ctxB(ch: *zio.Channel(u8), n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        _ = try ch.receive();
        try ch.send(0);
    }
}
fn ctxRoot(n: usize) !void {
    var empty: [0]u8 = .{};
    var ch = zio.Channel(u8).init(&empty);
    var g: zio.Group = .init;
    defer g.cancel();
    try g.spawn(ctxA, .{ &ch, n });
    try g.spawn(ctxB, .{ &ch, n });
    try g.wait();
}
fn ctxSwitchBounce(alloc: std.mem.Allocator) !void {
    const n: usize = 200_000;
    var rt = try zio.Runtime.init(alloc, compactOpts(1));
    defer rt.deinit();
    const t0 = common.nowNs();
    joinOk(try rt.spawn(ctxRoot, .{n}));
    common.printRate("ctx_switch_bounce", n * 2, common.nowNs() - t0);
}

fn yieldA(remain: *usize) zio.Cancelable!void {
    while (remain.* > 0) {
        remain.* -= 1;
        try zio.yield();
    }
}
fn yieldB(remain: *usize) zio.Cancelable!void {
    while (remain.* > 0) {
        remain.* -= 1;
        try zio.yield();
    }
}
fn yieldPingPongRoot(rem: *usize) !void {
    var g: zio.Group = .init;
    defer g.cancel();
    try g.spawn(yieldA, .{rem});
    try g.spawn(yieldB, .{rem});
    try g.wait();
}
fn yieldPingPong(alloc: std.mem.Allocator) !void {
    const n: usize = 200_000;
    var rt = try zio.Runtime.init(alloc, compactOpts(1));
    defer rt.deinit();
    var remain: usize = n;
    const t0 = common.nowNs();
    joinOk(try rt.spawn(yieldPingPongRoot, .{&remain}));
    common.printRate("yield_pingpong", n * 2, common.nowNs() - t0);
}

fn yieldWork(count: usize) zio.Cancelable!void {
    var i: usize = 0;
    while (i < count) : (i += 1) try zio.yield();
}
fn yieldSingle(alloc: std.mem.Allocator) !void {
    const n: usize = 500_000;
    var rt = try zio.Runtime.init(alloc, compactOpts(1));
    defer rt.deinit();
    const t0 = common.nowNs();
    joinOk(try rt.spawn(yieldWork, .{n}));
    common.printRate("yield_single", n, common.nowNs() - t0);
}

fn yieldWs4(alloc: std.mem.Allocator) !void {
    const workers: usize = 4;
    const n: usize = 20_000;
    var rt = try zio.Runtime.init(alloc, compactOpts(4));
    defer rt.deinit();
    const Root = struct {
        fn run(count: usize, iters: usize) !void {
            var g: zio.Group = .init;
            defer g.cancel();
            var i: usize = 0;
            while (i < count) : (i += 1) try g.spawn(yieldWork, .{iters});
            try g.wait();
        }
    };
    const t0 = common.nowNs();
    joinOk(try rt.spawn(Root.run, .{ workers, n }));
    common.printRate("yield_ws_4w", n * workers, common.nowNs() - t0);
}

fn leaf() void {}
fn leafBatchRoot(count: usize) !void {
    var g: zio.Group = .init;
    defer g.cancel();
    var i: usize = 0;
    while (i < count) : (i += 1) try g.spawn(leaf, .{});
    try g.wait();
}
fn leafSpawnBatch(alloc: std.mem.Allocator) !void {
    const n: usize = 10_000;
    var rt = try zio.Runtime.init(alloc, compactOpts(1));
    defer rt.deinit();
    const t0 = common.nowNs();
    joinOk(try rt.spawn(leafBatchRoot, .{n}));
    common.printRate("leaf_spawn_batch", n, common.nowNs() - t0);
}

fn spawnJoin(alloc: std.mem.Allocator) !void {
    const n: usize = 10_000;
    var rt = try zio.Runtime.init(alloc, compactOpts(1));
    defer rt.deinit();
    const t0 = common.nowNs();
    var i: usize = 0;
    while (i < n) : (i += 1) joinOk(try rt.spawn(leaf, .{}));
    common.printRate("spawn_join", n, common.nowNs() - t0);
}

fn addOne(v: u32) u32 {
    return v +% 1;
}
fn spawnResultRoot(count: usize) !void {
    var i: u32 = 0;
    var acc: u32 = 0;
    while (i < count) : (i += 1) {
        var h = try zio.spawn(addOne, .{i});
        acc +%= h.join();
    }
    std.mem.doNotOptimizeAway(acc);
}
fn spawnResultJoin(alloc: std.mem.Allocator) !void {
    const n: usize = 5_000;
    var rt = try zio.Runtime.init(alloc, compactOpts(1));
    defer rt.deinit();
    const t0 = common.nowNs();
    joinOk(try rt.spawn(spawnResultRoot, .{n}));
    common.printRate("spawn_result_join", n, common.nowNs() - t0);
}

fn priorityDispatch(alloc: std.mem.Allocator) !void {
    const n: usize = 5_000;
    var rt = try zio.Runtime.init(alloc, compactOpts(1));
    defer rt.deinit();
    const t0 = common.nowNs();
    joinOk(try rt.spawn(leafBatchRoot, .{n}));
    common.printRate("priority_dispatch", n, common.nowNs() - t0);
}

fn nurseryJoin(alloc: std.mem.Allocator) !void {
    const n: usize = 5_000;
    var rt = try zio.Runtime.init(alloc, compactOpts(1));
    defer rt.deinit();
    const t0 = common.nowNs();
    joinOk(try rt.spawn(leafBatchRoot, .{n}));
    common.printRate("nursery_join", n, common.nowNs() - t0);
}

fn skynet(num: usize, size: usize) anyerror!usize {
    if (size == 1) return num;
    const div: usize = 10;
    const next = size / div;
    var sum: usize = 0;
    var handles: [div]zio.JoinHandle(anyerror!usize) = undefined;
    var i: usize = 0;
    while (i < div) : (i += 1) {
        handles[i] = try zio.spawn(skynet, .{ num + i * next, next });
    }
    i = 0;
    while (i < div) : (i += 1) {
        sum +%= handles[i].join() catch 0;
    }
    return sum;
}
fn skynetRoot(size: usize) anyerror!usize {
    return skynet(0, size);
}
fn skynetJoin(alloc: std.mem.Allocator) !void {
    const size: usize = 10_000;
    var rt = try zio.Runtime.init(alloc, compactOpts(1));
    defer rt.deinit();
    const t0 = common.nowNs();
    joinOk(try rt.spawn(skynetRoot, .{size}));
    const total = size + size / 10 + size / 100 + size / 1000 + size / 10_000;
    common.printRate("skynet_join_10k", total, common.nowNs() - t0);
}

fn nTasksWorker(iters: usize) zio.Cancelable!void {
    var i: usize = 0;
    while (i < iters) : (i += 1) try zio.yield();
}
fn nTasksRoot(count: usize, iters: usize) !void {
    var g: zio.Group = .init;
    defer g.cancel();
    var i: usize = 0;
    while (i < count) : (i += 1) try g.spawn(nTasksWorker, .{iters});
    try g.wait();
}
fn nTasks(alloc: std.mem.Allocator, num: usize) !void {
    const rounds: usize = 20;
    var rt = try zio.Runtime.init(alloc, compactOpts(1));
    defer rt.deinit();
    const t0 = common.nowNs();
    joinOk(try rt.spawn(nTasksRoot, .{ num, rounds }));
    var name_buf: [64]u8 = undefined;
    common.printRate(try std.fmt.bufPrint(&name_buf, "n_tasks_{d}", .{num}), num * rounds, common.nowNs() - t0);
}

fn chanProducer(ch: *zio.Channel(usize), count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) try ch.send(i);
    ch.close(.graceful);
}
fn chanConsumer(ch: *zio.Channel(usize)) !void {
    while (true) {
        _ = ch.receive() catch |err| switch (err) {
            error.ChannelClosed => return,
            else => return err,
        };
    }
}
fn chanRoot(ch: *zio.Channel(usize), count: usize) !void {
    var g: zio.Group = .init;
    defer g.cancel();
    try g.spawn(chanProducer, .{ ch, count });
    try g.spawn(chanConsumer, .{ch});
    try g.wait();
}
fn chanPipeline(alloc: std.mem.Allocator) !void {
    const n: usize = 200_000;
    var rt = try zio.Runtime.init(alloc, compactOpts(1));
    defer rt.deinit();
    var buf: [256]usize = undefined;
    var ch = zio.Channel(usize).init(&buf);
    const t0 = common.nowNs();
    joinOk(try rt.spawn(chanRoot, .{ &ch, n }));
    common.printRate("chan_pipeline_buf256", n, common.nowNs() - t0);
}
fn chanRendezvous(alloc: std.mem.Allocator) !void {
    const n: usize = 100_000;
    var rt = try zio.Runtime.init(alloc, compactOpts(1));
    defer rt.deinit();
    var empty: [0]usize = .{};
    var ch = zio.Channel(usize).init(&empty);
    const t0 = common.nowNs();
    joinOk(try rt.spawn(chanRoot, .{ &ch, n }));
    common.printRate("chan_rendezvous", n, common.nowNs() - t0);
}

fn mpmcProd(ch: *zio.Channel(usize), per: usize, done: *std.atomic.Value(usize), producers: usize) !void {
    var i: usize = 0;
    while (i < per) : (i += 1) try ch.send(i);
    if (done.fetchAdd(1, .monotonic) + 1 == producers) ch.close(.graceful);
}
fn mpmcCons(ch: *zio.Channel(usize)) !void {
    while (true) {
        _ = ch.receive() catch |err| switch (err) {
            error.ChannelClosed => return,
            else => return err,
        };
    }
}
fn mpmcRoot(count_per: usize) !void {
    const producers: usize = 4;
    const consumers: usize = 4;
    var buf: [1024]usize = undefined;
    var ch = zio.Channel(usize).init(&buf);
    var done = std.atomic.Value(usize).init(0);
    var g: zio.Group = .init;
    defer g.cancel();
    var i: usize = 0;
    while (i < producers) : (i += 1) try g.spawn(mpmcProd, .{ &ch, count_per, &done, producers });
    i = 0;
    while (i < consumers) : (i += 1) try g.spawn(mpmcCons, .{&ch});
    try g.wait();
}
fn chanMpmc(alloc: std.mem.Allocator) !void {
    const per: usize = 25_000;
    var rt = try zio.Runtime.init(alloc, compactOpts(4));
    defer rt.deinit();
    const t0 = common.nowNs();
    joinOk(try rt.spawn(mpmcRoot, .{per}));
    common.printRate("chan_mpmc_4x4", per * 4, common.nowNs() - t0);
}

fn chanTryWork(count: usize) !void {
    var buf: [1]usize = undefined;
    var ch = zio.Channel(usize).init(&buf);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        ch.trySend(i) catch {};
        _ = ch.tryReceive() catch {};
    }
}
fn chanTry(alloc: std.mem.Allocator) !void {
    const n: usize = 500_000;
    var rt = try zio.Runtime.init(alloc, compactOpts(1));
    defer rt.deinit();
    const t0 = common.nowNs();
    joinOk(try rt.spawn(chanTryWork, .{n}));
    common.printRate("chan_try_uncontended", n, common.nowNs() - t0);
}

fn chanCreateWork(count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        var buf: [8]usize = undefined;
        var ch = zio.Channel(usize).init(&buf);
        std.mem.doNotOptimizeAway(&ch);
    }
}
fn chanCreate(alloc: std.mem.Allocator) !void {
    const n: usize = 50_000;
    var rt = try zio.Runtime.init(alloc, compactOpts(1));
    defer rt.deinit();
    const t0 = common.nowNs();
    joinOk(try rt.spawn(chanCreateWork, .{n}));
    common.printRate("chan_create_buf8", n, common.nowNs() - t0);
}

fn chanCreatePooled(alloc: std.mem.Allocator) !void {
    const n: usize = 50_000;
    var rt = try zio.Runtime.init(alloc, compactOpts(1));
    defer rt.deinit();
    const t0 = common.nowNs();
    joinOk(try rt.spawn(chanCreateWork, .{n}));
    common.printRate("chan_create_buf8_pooled", n, common.nowNs() - t0);
}

fn drainWork(alloc: std.mem.Allocator, count: usize) !void {
    const storage = try alloc.alloc(usize, count);
    defer alloc.free(storage);
    var ch = zio.Channel(usize).init(storage);
    var i: usize = 0;
    while (i < count) : (i += 1) ch.trySend(i) catch {};
    ch.close(.graceful);
    while (true) {
        _ = ch.receive() catch |err| switch (err) {
            error.ChannelClosed => return,
            else => return err,
        };
    }
}
fn chanClosedDrain(alloc: std.mem.Allocator) !void {
    const n: usize = 50_000;
    var rt = try zio.Runtime.init(alloc, compactOpts(1));
    defer rt.deinit();
    const t0 = common.nowNs();
    joinOk(try rt.spawn(drainWork, .{ alloc, n }));
    common.printRate("chan_closed_drain", n, common.nowNs() - t0);
}

fn spinWork(work: usize) void {
    var foo: usize = 0;
    var i: usize = 0;
    while (i < work) : (i += 1) {
        foo *%= 2;
        foo /= 2;
    }
    std.mem.doNotOptimizeAway(foo);
}
fn prodWork(ch: *zio.Channel(usize), count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        spinWork(100);
        try ch.send(i);
    }
    ch.close(.graceful);
}
fn consWork(ch: *zio.Channel(usize)) !void {
    while (true) {
        _ = ch.receive() catch |err| switch (err) {
            error.ChannelClosed => return,
            else => return err,
        };
        spinWork(100);
    }
}
fn prodConsRoot(count: usize) !void {
    var buf: [64]usize = undefined;
    var ch = zio.Channel(usize).init(&buf);
    var g: zio.Group = .init;
    defer g.cancel();
    try g.spawn(prodWork, .{ &ch, count });
    try g.spawn(consWork, .{&ch});
    try g.wait();
}
fn chanProdConsWork(alloc: std.mem.Allocator) !void {
    const n: usize = 50_000;
    var rt = try zio.Runtime.init(alloc, compactOpts(1));
    defer rt.deinit();
    const t0 = common.nowNs();
    joinOk(try rt.spawn(prodConsRoot, .{n}));
    common.printRate("chan_prodcons_work", n, common.nowNs() - t0);
}

fn popularWaiter(ch: *zio.Channel(usize), msgs: usize) !void {
    var i: usize = 0;
    while (i < msgs) : (i += 1) _ = try ch.receive();
}
fn popularFeed(ch: *zio.Channel(usize), total: usize) !void {
    var i: usize = 0;
    while (i < total) : (i += 1) try ch.send(i);
    ch.close(.graceful);
}
fn popularRoot(waiters: usize, msgs: usize) !void {
    var empty: [0]usize = .{};
    var ch = zio.Channel(usize).init(&empty);
    var g: zio.Group = .init;
    defer g.cancel();
    var i: usize = 0;
    while (i < waiters) : (i += 1) try g.spawn(popularWaiter, .{ &ch, msgs });
    try g.spawn(popularFeed, .{ &ch, waiters * msgs });
    try g.wait();
}
fn chanPopular(alloc: std.mem.Allocator) !void {
    const waiters: usize = 256;
    const msgs: usize = 200;
    var rt = try zio.Runtime.init(alloc, compactOpts(1));
    defer rt.deinit();
    const t0 = common.nowNs();
    joinOk(try rt.spawn(popularRoot, .{ waiters, msgs }));
    common.printRate("chan_popular_256", waiters * msgs, common.nowNs() - t0);
}

fn chanSemWork(count: usize) !void {
    var buf: [1]u8 = undefined;
    var ch = zio.Channel(u8).init(&buf);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        try ch.send(0);
        _ = try ch.receive();
    }
}
fn chanSem(alloc: std.mem.Allocator) !void {
    const n: usize = 100_000;
    var rt = try zio.Runtime.init(alloc, compactOpts(1));
    defer rt.deinit();
    const t0 = common.nowNs();
    joinOk(try rt.spawn(chanSemWork, .{n}));
    common.printRate("chan_sem", n, common.nowNs() - t0);
}

fn actorLoop(ch: *zio.Channel(u64)) !void {
    var sum: u64 = 0;
    while (true) {
        const v = ch.receive() catch |err| switch (err) {
            error.ChannelClosed => break,
            else => return err,
        };
        sum +%= v;
    }
    std.mem.doNotOptimizeAway(sum);
}
fn actorFeed(ch: *zio.Channel(u64), n: usize) !void {
    var i: u64 = 0;
    while (i < n) : (i += 1) try ch.send(i);
    ch.close(.graceful);
}
fn actorRoot(n: usize) !void {
    var buf: [256]u64 = undefined;
    var ch = zio.Channel(u64).init(&buf);
    var g: zio.Group = .init;
    defer g.cancel();
    try g.spawn(actorLoop, .{&ch});
    try g.spawn(actorFeed, .{ &ch, n });
    try g.wait();
}
fn actorMailbox(alloc: std.mem.Allocator) !void {
    const n: usize = 50_000;
    var rt = try zio.Runtime.init(alloc, compactOpts(1));
    defer rt.deinit();
    const t0 = common.nowNs();
    joinOk(try rt.spawn(actorRoot, .{n}));
    common.printRate("actor_mailbox", n, common.nowNs() - t0);
}

fn selectProd(ch: *zio.Channel(usize), count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) try ch.send(i);
}
fn selectFaninRoot(n: usize) !void {
    var ba: [64]usize = undefined;
    var bb: [64]usize = undefined;
    var a = zio.Channel(usize).init(&ba);
    var b = zio.Channel(usize).init(&bb);
    var g: zio.Group = .init;
    defer g.cancel();
    try g.spawn(selectProd, .{ &a, n / 2 });
    try g.spawn(selectProd, .{ &b, n - n / 2 });
    var got: usize = 0;
    while (got < n) {
        var ra = a.asyncReceive();
        var rb = b.asyncReceive();
        const result = try zio.select(.{ .a = &ra, .b = &rb });
        switch (result) {
            .a => |v| _ = v catch break,
            .b => |v| _ = v catch break,
        }
        got += 1;
    }
    try g.wait();
}
fn selectFanin(alloc: std.mem.Allocator) !void {
    const n: usize = 50_000;
    var rt = try zio.Runtime.init(alloc, compactOpts(1));
    defer rt.deinit();
    const t0 = common.nowNs();
    joinOk(try rt.spawn(selectFaninRoot, .{n}));
    common.printRate("select_fanin_2", n, common.nowNs() - t0);
}

fn selectUncontendedWork(n: usize) !void {
    var ba: [1]usize = undefined;
    var bb: [1]usize = undefined;
    var a = zio.Channel(usize).init(&ba);
    var b = zio.Channel(usize).init(&bb);
    try a.send(0);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var ra = a.asyncReceive();
        var rb = b.asyncReceive();
        const result = try zio.select(.{ .a = &ra, .b = &rb });
        switch (result) {
            .a => |v| {
                _ = v catch {};
                try b.send(0);
            },
            .b => |v| {
                _ = v catch {};
                try a.send(0);
            },
        }
    }
}
fn selectUncontended(alloc: std.mem.Allocator) !void {
    const n: usize = 100_000;
    var rt = try zio.Runtime.init(alloc, compactOpts(1));
    defer rt.deinit();
    const t0 = common.nowNs();
    joinOk(try rt.spawn(selectUncontendedWork, .{n}));
    common.printRate("select_uncontended", n, common.nowNs() - t0);
}

fn selectNonblockWork(n: usize) !void {
    var empty_a: [0]usize = .{};
    var empty_b: [0]usize = .{};
    var a = zio.Channel(usize).init(&empty_a);
    var b = zio.Channel(usize).init(&empty_b);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        _ = a.tryReceive() catch {};
        _ = b.tryReceive() catch {};
    }
}
fn selectNonblock(alloc: std.mem.Allocator) !void {
    const n: usize = 200_000;
    var rt = try zio.Runtime.init(alloc, compactOpts(1));
    defer rt.deinit();
    const t0 = common.nowNs();
    joinOk(try rt.spawn(selectNonblockWork, .{n}));
    common.printRate("select_nonblock", n, common.nowNs() - t0);
}

fn selectSyncRoot(n: usize) !void {
    var ba: [32]usize = undefined;
    var bb: [32]usize = undefined;
    var bc: [32]usize = undefined;
    var a = zio.Channel(usize).init(&ba);
    var b = zio.Channel(usize).init(&bb);
    var c = zio.Channel(usize).init(&bc);
    const per = n / 3;
    var g: zio.Group = .init;
    defer g.cancel();
    try g.spawn(selectProd, .{ &a, per });
    try g.spawn(selectProd, .{ &b, per });
    try g.spawn(selectProd, .{ &c, n - 2 * per });
    var got: usize = 0;
    while (got < n) {
        var ra = a.asyncReceive();
        var rb = b.asyncReceive();
        var rc = c.asyncReceive();
        const result = try zio.select(.{ .a = &ra, .b = &rb, .c = &rc });
        switch (result) {
            .a => |v| _ = v catch break,
            .b => |v| _ = v catch break,
            .c => |v| _ = v catch break,
        }
        got += 1;
    }
    try g.wait();
}
fn selectSyncContended(alloc: std.mem.Allocator) !void {
    const n: usize = 30_000;
    var rt = try zio.Runtime.init(alloc, compactOpts(1));
    defer rt.deinit();
    const t0 = common.nowNs();
    joinOk(try rt.spawn(selectSyncRoot, .{n}));
    common.printRate("select_sync_contended", n, common.nowNs() - t0);
}

fn mutexWork(count: usize) !void {
    var m: zio.Mutex = .init;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        try m.lock();
        m.unlock();
    }
}
fn mutexUncontended(alloc: std.mem.Allocator) !void {
    const n: usize = 200_000;
    var rt = try zio.Runtime.init(alloc, compactOpts(1));
    defer rt.deinit();
    const t0 = common.nowNs();
    joinOk(try rt.spawn(mutexWork, .{n}));
    common.printRate("mutex_uncontended", n, common.nowNs() - t0);
}

fn mutexWorker(m: *zio.Mutex, counter: *usize, per: usize) !void {
    var i: usize = 0;
    while (i < per) : (i += 1) {
        try m.lock();
        counter.* += 1;
        m.unlock();
    }
}
fn mutexContendedRoot(workers: usize, per: usize) !void {
    var m: zio.Mutex = .init;
    var counter: usize = 0;
    var g: zio.Group = .init;
    defer g.cancel();
    var i: usize = 0;
    while (i < workers) : (i += 1) try g.spawn(mutexWorker, .{ &m, &counter, per });
    try g.wait();
    std.mem.doNotOptimizeAway(counter);
}
fn mutexContended(alloc: std.mem.Allocator) !void {
    const workers: usize = 4;
    const per: usize = 25_000;
    var rt = try zio.Runtime.init(alloc, compactOpts(4));
    defer rt.deinit();
    const t0 = common.nowNs();
    joinOk(try rt.spawn(mutexContendedRoot, .{ workers, per }));
    common.printRate("mutex_contended_4", workers * per, common.nowNs() - t0);
}

fn semWaiter(sem: *zio.Semaphore, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) try sem.wait();
}
fn semPoster(sem: *zio.Semaphore, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) sem.post();
}
fn semRoot(count: usize) !void {
    var sem: zio.Semaphore = .{ .permits = 0 };
    var g: zio.Group = .init;
    defer g.cancel();
    try g.spawn(semPoster, .{ &sem, count });
    try g.spawn(semWaiter, .{ &sem, count });
    try g.wait();
}
fn semHandoff(alloc: std.mem.Allocator) !void {
    const n: usize = 100_000;
    var rt = try zio.Runtime.init(alloc, compactOpts(1));
    defer rt.deinit();
    const t0 = common.nowNs();
    joinOk(try rt.spawn(semRoot, .{n}));
    common.printRate("sem_handoff", n, common.nowNs() - t0);
}

fn rwSharedWorker(rw: *zio.RwLock, counter: *const usize, per: usize) !void {
    var i: usize = 0;
    while (i < per) : (i += 1) {
        try rw.lockShared();
        std.mem.doNotOptimizeAway(counter.*);
        rw.unlockShared();
    }
}
fn rwSharedRoot(readers: usize, per: usize) !void {
    var rw: zio.RwLock = .init;
    var counter: usize = 0;
    var g: zio.Group = .init;
    defer g.cancel();
    var i: usize = 0;
    while (i < readers) : (i += 1) try g.spawn(rwSharedWorker, .{ &rw, &counter, per });
    try g.wait();
}
fn rwlockShared(alloc: std.mem.Allocator) !void {
    const readers: usize = 4;
    const per: usize = 50_000;
    var rt = try zio.Runtime.init(alloc, compactOpts(4));
    defer rt.deinit();
    const t0 = common.nowNs();
    joinOk(try rt.spawn(rwSharedRoot, .{ readers, per }));
    common.printRate("rwlock_shared_4", readers * per, common.nowNs() - t0);
}

fn rwExclWork(count: usize) !void {
    var rw: zio.RwLock = .init;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        try rw.lock();
        rw.unlock();
    }
}
fn rwlockExclusive(alloc: std.mem.Allocator) !void {
    const n: usize = 100_000;
    var rt = try zio.Runtime.init(alloc, compactOpts(1));
    defer rt.deinit();
    const t0 = common.nowNs();
    joinOk(try rt.spawn(rwExclWork, .{n}));
    common.printRate("rwlock_exclusive", n, common.nowNs() - t0);
}

fn sleepOne() !void {
    try zio.sleep(.fromNanoseconds(50));
}
fn sleepBatchRoot(count: usize) !void {
    var g: zio.Group = .init;
    defer g.cancel();
    var i: usize = 0;
    while (i < count) : (i += 1) try g.spawn(sleepOne, .{});
    try g.wait();
}
fn sleepBatch(alloc: std.mem.Allocator) !void {
    const n: usize = 2_000;
    var rt = try zio.Runtime.init(alloc, compactOpts(1));
    defer rt.deinit();
    const t0 = common.nowNs();
    joinOk(try rt.spawn(sleepBatchRoot, .{n}));
    common.printRate("timer_sleep_batch", n, common.nowNs() - t0);
}

fn sleepNs(ns: u64) !void {
    try zio.sleep(.fromNanoseconds(ns));
}
fn timerManyRoot(count: usize) !void {
    var g: zio.Group = .init;
    defer g.cancel();
    var i: usize = 0;
    while (i < count) : (i += 1) try g.spawn(sleepNs, .{@as(u64, 1 + i % 1000)});
    try g.wait();
}
fn timerMany(alloc: std.mem.Allocator) !void {
    const n: usize = 100_000;
    var rt = try zio.Runtime.init(alloc, compactOpts(1));
    defer rt.deinit();
    const t0 = common.nowNs();
    joinOk(try rt.spawn(timerManyRoot, .{n}));
    common.printRate("timer_many_100k_dispatch", n, common.nowNs() - t0);
}

fn tcpServer(port_ch: *zio.Channel(u16), expect: usize) !void {
    const addr = try zio.net.IpAddress.parseIp4("127.0.0.1", 0);
    const server = try addr.listen(.{});
    defer server.close();
    try port_ch.send(server.socket.address.ip.getPort());
    var stream = try server.accept(.{});
    defer stream.close();
    var buf: [64]u8 = undefined;
    var got: usize = 0;
    while (got < expect) {
        const n = stream.read(&buf, .none) catch break;
        if (n == 0) break;
        stream.writeAll(buf[0..n], .none) catch break;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (buf[i] == '\n') got += 1;
        }
    }
}
fn tcpClient(port_ch: *zio.Channel(u16), done: *zio.Channel(usize), count: usize) !void {
    const port = port_ch.receive() catch {
        try done.send(0);
        return;
    };
    const addr = try zio.net.IpAddress.parseIp4("127.0.0.1", port);
    var stream = try zio.net.tcpConnectToAddress(addr, .{});
    defer stream.close();
    const msg = "PING\n";
    var buf: [5]u8 = undefined;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        stream.writeAll(msg, .none) catch {
            try done.send(i);
            return;
        };
        const n = stream.read(&buf, .none) catch {
            try done.send(i);
            return;
        };
        if (n != msg.len) {
            try done.send(i);
            return;
        }
    }
    try done.send(count);
}
fn tcpRoot(rounds: usize) !usize {
    var pbuf: [1]u16 = undefined;
    var dbuf: [1]usize = undefined;
    var port_ch = zio.Channel(u16).init(&pbuf);
    var done = zio.Channel(usize).init(&dbuf);
    var g: zio.Group = .init;
    defer g.cancel();
    try g.spawn(tcpServer, .{ &port_ch, rounds });
    try g.spawn(tcpClient, .{ &port_ch, &done, rounds });
    const completed = done.receive() catch 0;
    try g.wait();
    return completed;
}
fn tcpPingPong(alloc: std.mem.Allocator) !void {
    const rounds: usize = 20_000;
    var rt = try zio.Runtime.init(alloc, compactOpts(1));
    defer rt.deinit();
    const t0 = common.nowNs();
    var h = try rt.spawn(tcpRoot, .{rounds});
    const completed = h.join() catch 0;
    const dt = common.nowNs() - t0;
    if (completed == 0) {
        std.debug.print("tcp_pingpong: failed (0 roundtrips)\n", .{});
        return;
    }
    common.printThroughput("tcp_pingpong", completed, dt, "roundtrips");
    common.printRate("tcp_pingpong_latency", completed, dt);
}

fn udpServer(port_ch: *zio.Channel(u16), expect: usize) !void {
    const addr = try zio.net.IpAddress.parseIp4("127.0.0.1", 0);
    var sock = try addr.bind(.{});
    defer sock.close();
    try port_ch.send(sock.address.ip.getPort());
    var buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < expect) : (i += 1) {
        _ = sock.receiveFrom(&buf, .none) catch return;
    }
}
fn udpClient(port_ch: *zio.Channel(u16), done: *zio.Channel(usize), count: usize) !void {
    const port = port_ch.receive() catch {
        try done.send(0);
        return;
    };
    const dest = try zio.net.IpAddress.parseIp4("127.0.0.1", port);
    const local = try zio.net.IpAddress.parseIp4("127.0.0.1", 0);
    var sock = try local.bind(.{});
    defer sock.close();
    const payload = "PING";
    var i: usize = 0;
    while (i < count) : (i += 1) {
        _ = sock.sendTo(.{ .ip = dest }, payload, .none) catch {
            try done.send(i);
            return;
        };
    }
    try done.send(count);
}
fn udpRoot(rounds: usize) !usize {
    var pbuf: [1]u16 = undefined;
    var dbuf: [1]usize = undefined;
    var port_ch = zio.Channel(u16).init(&pbuf);
    var done = zio.Channel(usize).init(&dbuf);
    var g: zio.Group = .init;
    defer g.cancel();
    try g.spawn(udpServer, .{ &port_ch, rounds });
    try g.spawn(udpClient, .{ &port_ch, &done, rounds });
    const completed = done.receive() catch 0;
    try g.wait();
    return completed;
}
fn udpPing(alloc: std.mem.Allocator) !void {
    const rounds: usize = 10_000;
    var rt = try zio.Runtime.init(alloc, compactOpts(1));
    defer rt.deinit();
    const t0 = common.nowNs();
    var h = try rt.spawn(udpRoot, .{rounds});
    const completed = h.join() catch 0;
    const dt = common.nowNs() - t0;
    if (completed == 0) {
        std.debug.print("udp_ping: failed (0 packets)\n", .{});
        return;
    }
    common.printThroughput("udp_ping", completed, dt, "pkts");
    common.printRate("udp_ping_latency", completed, dt);
}
