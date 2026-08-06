const std = @import("std");
const zr = @import("zigroutines");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    std.debug.print("zigroutines bench  version={f}  optimize=see -Doptimize\n", .{zr.version});
    std.debug.print("---\n", .{});

    try benchYieldPingPong(alloc);
    try benchYieldLoopSingle(alloc);
    try benchYieldWorkStealing(alloc);
    try benchSpawnJoin(alloc);
    try benchChannelPipeline(alloc);
    try benchChannelRendezvous(alloc);
    try benchChannelMpmc(alloc);
    try benchChannelUncontended(alloc);
    try benchSelectFanIn(alloc);
    try benchMutexUncontended(alloc);
    try benchMutexContended(alloc);
    try benchSemaphoreHandoff(alloc);
    try benchSpawnResultJoin(alloc);
    try benchPriorityDispatch(alloc);
    try benchNurseryJoin(alloc);
    try benchSleepTimers(alloc);
    try benchActorMailbox(alloc);

    std.debug.print("---\ndone\n", .{});
}

fn nowNs() i128 {
    const io = std.Io.Threaded.global_single_threaded.io();
    return @intCast(std.Io.Clock.boot.now(io).nanoseconds);
}

fn printRate(name: []const u8, ops: usize, dt_ns: i128) void {
    const dt: f64 = @floatFromInt(dt_ns);
    const ops_f: f64 = @floatFromInt(ops);
    std.debug.print("{s}: {d} ops in {d:.3} ms → {d:.1} ns/op  ({d:.2} Mops/s)\n", .{
        name,
        ops,
        dt / 1e6,
        dt / ops_f,
        ops_f / (dt / 1e3),
    });
}

// yields/context switch
fn benchYieldPingPong(alloc: std.mem.Allocator) !void {
    const n: usize = 200_000;
    var rt = try zr.Runtime.init(alloc, .{ .workers = 1, .stack_pool = true });
    defer rt.deinit();

    const Pair = struct {
        remain: usize,
        fn a(self: *@This()) void {
            while (self.remain > 0) {
                self.remain -= 1;
                zr.yield();
            }
        }
        fn b(self: *@This()) void {
            while (self.remain > 0) {
                self.remain -= 1;
                zr.yield();
            }
        }
    };
    var pair = Pair{ .remain = n };
    _ = try rt.spawn(.{}, Pair.a, .{&pair});
    _ = try rt.spawn(.{}, Pair.b, .{&pair});

    const t0 = nowNs();
    try rt.run();
    const t1 = nowNs();
    printRate("yield_pingpong", n * 2, t1 - t0);
}

fn benchYieldLoopSingle(alloc: std.mem.Allocator) !void {
    const n: usize = 500_000;
    var rt = try zr.Runtime.init(alloc, .{ .workers = 1, .stack_pool = true });
    defer rt.deinit();

    const S = struct {
        fn worker(iters: usize) void {
            var i: usize = 0;
            while (i < iters) : (i += 1) zr.yield();
        }
    };
    _ = try rt.spawn(.{}, S.worker, .{n});

    const t0 = nowNs();
    try rt.run();
    const t1 = nowNs();
    printRate("yield_single", n, t1 - t0);
}

fn benchYieldWorkStealing(alloc: std.mem.Allocator) !void {
    const workers: u32 = 4;
    const n: usize = 20_000;
    var rt = try zr.Runtime.init(alloc, .{
        .workers = workers,
        .policy = .work_stealing,
        .stack_pool = true,
    });
    defer rt.deinit();

    const S = struct {
        fn worker(iters: usize) void {
            var i: usize = 0;
            while (i < iters) : (i += 1) zr.yield();
        }
    };
    var w: u32 = 0;
    while (w < workers) : (w += 1) {
        _ = try rt.spawn(.{}, S.worker, .{n});
    }

    const t0 = nowNs();
    try rt.run();
    const t1 = nowNs();
    printRate("yield_ws_4w", n * workers, t1 - t0);
}

// spawn
fn benchSpawnJoin(alloc: std.mem.Allocator) !void {
    const n: usize = 10_000;
    var rt = try zr.Runtime.init(alloc, .{ .workers = 1, .stack_pool = true });
    defer rt.deinit();

    const S = struct {
        fn leaf() void {}
        fn spawner(r: *zr.Runtime, count: usize) void {
            var i: usize = 0;
            while (i < count) : (i += 1) {
                const h = r.spawn(.{}, leaf, .{}) catch return;
                h.join();
            }
        }
    };
    _ = try rt.spawn(.{}, S.spawner, .{ &rt, n });

    const t0 = nowNs();
    try rt.run();
    const t1 = nowNs();
    printRate("spawn_join", n, t1 - t0);
}

fn benchSpawnResultJoin(alloc: std.mem.Allocator) !void {
    const n: usize = 5_000;
    var rt = try zr.Runtime.init(alloc, .{ .workers = 1, .stack_pool = true });
    defer rt.deinit();

    const S = struct {
        fn add(a: u32, b: u32) u32 {
            return a +% b;
        }
        fn spawner(r: *zr.Runtime, count: usize) void {
            var i: usize = 0;
            var acc: u32 = 0;
            while (i < count) : (i += 1) {
                const h = r.spawnResult(.{}, add, .{ @as(u32, @intCast(i)), 1 }) catch return;
                acc +%= h.join();
            }
            std.mem.doNotOptimizeAway(acc);
        }
    };
    _ = try rt.spawn(.{}, S.spawner, .{ &rt, n });

    const t0 = nowNs();
    try rt.run();
    const t1 = nowNs();
    printRate("spawn_result_join", n, t1 - t0);
}

// channels
fn benchChannelPipeline(alloc: std.mem.Allocator) !void {
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

    const t0 = nowNs();
    try rt.run();
    const t1 = nowNs();
    printRate("chan_pipeline_buf256", n, t1 - t0);
}

fn benchChannelRendezvous(alloc: std.mem.Allocator) !void {
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

    const t0 = nowNs();
    try rt.run();
    const t1 = nowNs();
    printRate("chan_rendezvous", n, t1 - t0);
}

fn benchChannelMpmc(alloc: std.mem.Allocator) !void {
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

    const t0 = nowNs();
    try rt.run();
    const t1 = nowNs();
    printRate("chan_mpmc_4x4", total, t1 - t0);
}

fn benchChannelUncontended(alloc: std.mem.Allocator) !void {
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

    const t0 = nowNs();
    try rt.run();
    const t1 = nowNs();
    printRate("chan_try_uncontended", n, t1 - t0);
}

// select
fn benchSelectFanIn(alloc: std.mem.Allocator) !void {
    const n: usize = 50_000;
    var rt = try zr.Runtime.init(alloc, .{ .workers = 1, .stack_pool = true });
    defer rt.deinit();

    const Ch = zr.Channel(usize);
    const a = try Ch.create(alloc, 64);
    defer a.destroy();
    const b = try Ch.create(alloc, 64);
    defer b.destroy();

    const S = struct {
        fn prod(c: *Ch, count: usize) void {
            var i: usize = 0;
            while (i < count) : (i += 1) c.send(i) catch return;
        }
        fn fanin(ca: *Ch, cb: *Ch, expect: usize) void {
            var got: usize = 0;
            while (got < expect) {
                const r = zr.select.multi(usize, .{
                    .recv = &.{ ca, cb },
                }, .{ .timers = null });
                switch (r) {
                    .recv => got += 1,
                    else => {},
                }
            }
        }
    };
    _ = try rt.spawn(.{}, S.prod, .{ a, n / 2 });
    _ = try rt.spawn(.{}, S.prod, .{ b, n - n / 2 });
    _ = try rt.spawn(.{}, S.fanin, .{ a, b, n });

    const t0 = nowNs();
    try rt.run();
    const t1 = nowNs();
    printRate("select_fanin_2", n, t1 - t0);
}

// sync

fn benchMutexUncontended(alloc: std.mem.Allocator) !void {
    const n: usize = 200_000;
    var rt = try zr.Runtime.init(alloc, .{ .workers = 1, .stack_pool = true });
    defer rt.deinit();

    var mtx = zr.Mutex.init(alloc);
    defer mtx.deinit();

    const S = struct {
        fn work(m: *zr.Mutex, count: usize) void {
            var i: usize = 0;
            while (i < count) : (i += 1) {
                m.lock();
                m.unlock();
            }
        }
    };
    _ = try rt.spawn(.{}, S.work, .{ &mtx, n });

    const t0 = nowNs();
    try rt.run();
    const t1 = nowNs();
    printRate("mutex_uncontended", n, t1 - t0);
}

fn benchMutexContended(alloc: std.mem.Allocator) !void {
    const workers: usize = 4;
    const per: usize = 25_000;
    var rt = try zr.Runtime.init(alloc, .{
        .workers = 4,
        .policy = .work_stealing,
        .stack_pool = true,
    });
    defer rt.deinit();

    var mtx = zr.Mutex.init(alloc);
    defer mtx.deinit();
    var counter: usize = 0;

    const S = struct {
        fn work(m: *zr.Mutex, c: *usize, count: usize) void {
            var i: usize = 0;
            while (i < count) : (i += 1) {
                m.lock();
                c.* += 1;
                m.unlock();
            }
        }
    };
    var w: usize = 0;
    while (w < workers) : (w += 1) {
        _ = try rt.spawn(.{}, S.work, .{ &mtx, &counter, per });
    }

    const t0 = nowNs();
    try rt.run();
    const t1 = nowNs();
    printRate("mutex_contended_4", workers * per, t1 - t0);
    if (counter != workers * per) {
        std.debug.print("  WARNING: counter={d} expected={d}\n", .{ counter, workers * per });
    }
}

fn benchSemaphoreHandoff(alloc: std.mem.Allocator) !void {
    const n: usize = 50_000;
    var rt = try zr.Runtime.init(alloc, .{ .workers = 1, .stack_pool = true });
    defer rt.deinit();

    var sem = zr.Semaphore.init(alloc, 0);
    defer sem.deinit();

    const S = struct {
        fn consumer(s: *zr.Semaphore, count: usize) void {
            var i: usize = 0;
            while (i < count) : (i += 1) s.acquire();
        }
        fn producer(s: *zr.Semaphore, count: usize) void {
            var i: usize = 0;
            while (i < count) : (i += 1) s.release();
        }
    };
    _ = try rt.spawn(.{}, S.consumer, .{ &sem, n });
    _ = try rt.spawn(.{}, S.producer, .{ &sem, n });

    const t0 = nowNs();
    try rt.run();
    const t1 = nowNs();
    printRate("sem_handoff", n, t1 - t0);
}

// scheduling policies

fn benchPriorityDispatch(alloc: std.mem.Allocator) !void {
    const n: usize = 5_000;
    var rt = try zr.Runtime.init(alloc, .{
        .workers = 1,
        .policy = .priority,
        .stack_pool = true,
    });
    defer rt.deinit();

    const S = struct {
        var ticks: usize = 0;
        fn work() void {
            ticks += 1;
        }
    };
    S.ticks = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const prio: u8 = @intCast(i % 256);
        _ = try rt.spawn(.{ .priority = prio }, S.work, .{});
    }

    const t0 = nowNs();
    try rt.run();
    const t1 = nowNs();
    printRate("priority_dispatch", n, t1 - t0);
}

fn benchNurseryJoin(alloc: std.mem.Allocator) !void {
    const n: usize = 2_000;
    var rt = try zr.Runtime.init(alloc, .{ .workers = 1, .stack_pool = true });
    defer rt.deinit();

    const S = struct {
        fn leaf() void {}
        fn parent(r: *zr.Runtime, count: usize) void {
            var nursery = zr.Nursery.init(r, .{ .cancel_on_leave = false });
            defer nursery.deinit();
            var i: usize = 0;
            while (i < count) : (i += 1) {
                _ = nursery.spawn(.{}, leaf, .{}) catch return;
            }
            _ = nursery.join() catch {};
        }
    };
    _ = try rt.spawn(.{}, S.parent, .{ &rt, n });

    const t0 = nowNs();
    try rt.run();
    const t1 = nowNs();
    printRate("nursery_join", n, t1 - t0);
}

fn benchSleepTimers(alloc: std.mem.Allocator) !void {
    const n: usize = 2_000;
    var rt = try zr.Runtime.init(alloc, .{ .workers = 1, .stack_pool = true });
    defer rt.deinit();

    const S = struct {
        fn sleeper() void {
            zr.sleep(50);
        }
    };
    var i: usize = 0;
    while (i < n) : (i += 1) {
        _ = try rt.spawn(.{}, S.sleeper, .{});
    }

    const t0 = nowNs();
    try rt.run();
    const t1 = nowNs();
    printRate("timer_sleep_batch", n, t1 - t0);
}

fn benchActorMailbox(alloc: std.mem.Allocator) !void {
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

    const t0 = nowNs();
    try rt.run();
    const t1 = nowNs();
    printRate("actor_mailbox", n, t1 - t0);
}
