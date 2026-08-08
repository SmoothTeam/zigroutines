const std = @import("std");
const zio = @import("zio");
const common = @import("common");

pub fn main(init: std.process.Init) !void {
    common.init(init.io);
    const allocator = init.gpa;
    std.debug.print("peer-zio  zig=0.16\n", .{});

    std.debug.print("--- fiber / spawn ---\n", .{});
    try yieldPingPong(allocator);
    try yieldSingle(allocator);
    try leafSpawnBatch(allocator);
    try spawnJoin(allocator);
    try nurseryJoin(allocator);
    try nTasks(allocator, 1_000);
    try nTasks(allocator, 10_000);

    std.debug.print("--- channel ---\n", .{});
    try chanPipeline(allocator);
    try chanRendezvous(allocator);
    try chanTry(allocator);
    try chanClosedDrain(allocator);

    std.debug.print("--- sync / timers ---\n", .{});
    try mutexUncontended(allocator);
    try semHandoff(allocator);
    try rwlockExclusive(allocator);
    try sleepBatch(allocator);

    std.debug.print("---\ndone\n", .{});
    std.debug.print(
        \\skipped (slow/flaky): n_tasks_50k, chan_mpmc, select_*, mutex_contended, rwlock_shared, I/O
        \\n/a: ctx_switch_bounce, yield_ws_4w, priority, skynet, actor_mailbox,
        \\  chan_create_pooled, timer_many_100k bulk wheel
        \\
    , .{});
}

fn joinOk(h: anytype) void {
    var handle = h;
    const result = handle.join();
    switch (@typeInfo(@TypeOf(result))) {
        .error_union => _ = result catch {},
        else => {},
    }
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
    var rt = try zio.Runtime.init(alloc, .{});
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
    var rt = try zio.Runtime.init(alloc, .{});
    defer rt.deinit();
    const t0 = common.nowNs();
    joinOk(try rt.spawn(yieldWork, .{n}));
    common.printRate("yield_single", n, common.nowNs() - t0);
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
    var rt = try zio.Runtime.init(alloc, .{});
    defer rt.deinit();
    const t0 = common.nowNs();
    joinOk(try rt.spawn(leafBatchRoot, .{n}));
    common.printRate("leaf_spawn_batch", n, common.nowNs() - t0);
}

fn spawnJoin(alloc: std.mem.Allocator) !void {
    const n: usize = 10_000;
    var rt = try zio.Runtime.init(alloc, .{});
    defer rt.deinit();
    const t0 = common.nowNs();
    var i: usize = 0;
    while (i < n) : (i += 1) joinOk(try rt.spawn(leaf, .{}));
    common.printRate("spawn_join", n, common.nowNs() - t0);
}

fn nurseryJoin(alloc: std.mem.Allocator) !void {
    const n: usize = 5_000;
    var rt = try zio.Runtime.init(alloc, .{});
    defer rt.deinit();
    const t0 = common.nowNs();
    joinOk(try rt.spawn(leafBatchRoot, .{n}));
    common.printRate("nursery_join", n, common.nowNs() - t0);
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
    var rt = try zio.Runtime.init(alloc, .{});
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
    var rt = try zio.Runtime.init(alloc, .{});
    defer rt.deinit();
    var buf: [256]usize = undefined;
    var ch = zio.Channel(usize).init(&buf);
    const t0 = common.nowNs();
    joinOk(try rt.spawn(chanRoot, .{ &ch, n }));
    common.printRate("chan_pipeline_buf256", n, common.nowNs() - t0);
}
fn chanRendezvous(alloc: std.mem.Allocator) !void {
    const n: usize = 100_000;
    var rt = try zio.Runtime.init(alloc, .{});
    defer rt.deinit();
    var empty: [0]usize = .{};
    var ch = zio.Channel(usize).init(&empty);
    const t0 = common.nowNs();
    joinOk(try rt.spawn(chanRoot, .{ &ch, n }));
    common.printRate("chan_rendezvous", n, common.nowNs() - t0);
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
    var rt = try zio.Runtime.init(alloc, .{});
    defer rt.deinit();
    const t0 = common.nowNs();
    joinOk(try rt.spawn(chanTryWork, .{n}));
    common.printRate("chan_try_uncontended", n, common.nowNs() - t0);
}

fn drainWork(count: usize) !void {
    var buf: [64]usize = undefined;
    var ch = zio.Channel(usize).init(&buf);
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
    var rt = try zio.Runtime.init(alloc, .{});
    defer rt.deinit();
    const t0 = common.nowNs();
    joinOk(try rt.spawn(drainWork, .{n}));
    common.printRate("chan_closed_drain", n, common.nowNs() - t0);
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
    var rt = try zio.Runtime.init(alloc, .{});
    defer rt.deinit();
    const t0 = common.nowNs();
    joinOk(try rt.spawn(mutexWork, .{n}));
    common.printRate("mutex_uncontended", n, common.nowNs() - t0);
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
    var rt = try zio.Runtime.init(alloc, .{});
    defer rt.deinit();
    const t0 = common.nowNs();
    joinOk(try rt.spawn(semRoot, .{n}));
    common.printRate("sem_handoff", n, common.nowNs() - t0);
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
    var rt = try zio.Runtime.init(alloc, .{});
    defer rt.deinit();
    const t0 = common.nowNs();
    joinOk(try rt.spawn(rwExclWork, .{n}));
    common.printRate("rwlock_exclusive", n, common.nowNs() - t0);
}

fn sleepWork(count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) try zio.sleep(.fromMilliseconds(0));
}
fn sleepBatch(alloc: std.mem.Allocator) !void {
    const n: usize = 2_000;
    var rt = try zio.Runtime.init(alloc, .{});
    defer rt.deinit();
    const t0 = common.nowNs();
    joinOk(try rt.spawn(sleepWork, .{n}));
    common.printRate("timer_sleep_batch", n, common.nowNs() - t0);
}
