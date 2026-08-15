const std = @import("std");
const libcoro = @import("libcoro");
const common = @import("common");

pub fn main(init: std.process.Init) !void {
    common.init(init.io);
    const allocator = init.gpa;
    std.debug.print("peer-zigcoro  zig=0.17  (WS/priority/select/mutex/timer/I/O emulated where noted)\n", .{});
    std.debug.print("--- fiber / spawn ---\n", .{});
    try ctxSwitch(allocator);
    try yieldPingPong(allocator);
    try yieldSingle(allocator);
    try leafSpawn(allocator);
    try spawnJoin(allocator);
    try spawnResultJoin(allocator);
    try nurseryJoin(allocator);
    try nCoros(allocator, 1_000);
    try nCoros(allocator, 10_000);
    try nCoros(allocator, 50_000);
    try yieldWs4(allocator);
    try priorityDispatch(allocator);
    try skynetJoin(allocator);
    std.debug.print("--- channel (executor Channel) ---\n", .{});
    try chanPipeline(allocator, 256);
    try chanPipeline(allocator, 1);
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
    try tcpPingPong();
    try udpPing();
    std.debug.print("---\ndone\n", .{});
    std.debug.print("note: zigcoro is single-thread; WS/priority/MPMC/select/I/O are emulated\n", .{});
}

fn ctxSwitch(allocator: std.mem.Allocator) !void {
    const stack_size: usize = 4 * 1024;
    const stack = try allocator.alignedAlloc(u8, .fromByteUnits(libcoro.stack_alignment), stack_size);
    defer allocator.free(stack);

    const num_bounces: usize = 2_000_000;
    const S = struct {
        var rem: usize = 0;
        fn body() void {
            libcoro.xsuspend();
            while (rem > 0) {
                rem -= 1;
                libcoro.xsuspend();
            }
        }
    };

    {
        S.rem = 50_000;
        const c = try libcoro.xasync(S.body, .{}, stack);
        var i: usize = 0;
        while (i < 50_000) : (i += 1) libcoro.xresume(c);
        libcoro.xresume(c);
    }

    S.rem = num_bounces;
    const coro = try libcoro.xasync(S.body, .{}, stack);
    const t0 = common.nowNs();
    var i: usize = 0;
    while (i < num_bounces) : (i += 1) libcoro.xresume(coro);
    const t1 = common.nowNs();
    common.printRate("ctx_switch_bounce", num_bounces * 2, t1 - t0);
    libcoro.xresume(coro);
}

fn yieldPingPong(allocator: std.mem.Allocator) !void {
    const n: usize = 200_000;
    const stack_size: usize = 4 * 1024;
    const sa = try allocator.alignedAlloc(u8, .fromByteUnits(libcoro.stack_alignment), stack_size);
    defer allocator.free(sa);
    const sb = try allocator.alignedAlloc(u8, .fromByteUnits(libcoro.stack_alignment), stack_size);
    defer allocator.free(sb);

    const S = struct {
        fn body(rem: *usize) void {
            libcoro.xsuspend();
            while (rem.* > 0) {
                rem.* -= 1;
                libcoro.xsuspend();
            }
        }
    };

    var rem_a: usize = n;
    var rem_b: usize = n;
    const ca = try libcoro.xasync(S.body, .{&rem_a}, sa);
    const cb = try libcoro.xasync(S.body, .{&rem_b}, sb);
    const t0 = common.nowNs();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        libcoro.xresume(ca);
        libcoro.xresume(cb);
    }
    const t1 = common.nowNs();
    common.printRate("yield_pingpong", n * 2, t1 - t0);
}

fn yieldSingle(allocator: std.mem.Allocator) !void {
    const n: usize = 500_000;
    const stack = try allocator.alignedAlloc(u8, .fromByteUnits(libcoro.stack_alignment), 4 * 1024);
    defer allocator.free(stack);
    const S = struct {
        var rem: usize = 0;
        fn body() void {
            libcoro.xsuspend();
            while (rem > 0) {
                rem -= 1;
                libcoro.xsuspend();
            }
        }
    };
    S.rem = n;
    const c = try libcoro.xasync(S.body, .{}, stack);
    const t0 = common.nowNs();
    var i: usize = 0;
    while (i < n) : (i += 1) libcoro.xresume(c);
    const t1 = common.nowNs();
    common.printRate("yield_single", n, t1 - t0);
    libcoro.xresume(c);
}

fn leaf() void {}

fn addOne(v: u32) u32 {
    return v +% 1;
}

fn leafSpawn(allocator: std.mem.Allocator) !void {
    const n: usize = 10_000;
    var exec = libcoro.Executor.init();
    libcoro.initEnv(.{ .stack_allocator = allocator, .executor = &exec });
    const t0 = common.nowNs();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const f = try libcoro.xasync(leaf, .{}, null);
        defer f.deinit();
        libcoro.xawait(f);
    }
    const t1 = common.nowNs();
    common.printRate("leaf_spawn_batch", n, t1 - t0);
}

fn spawnJoin(allocator: std.mem.Allocator) !void {
    const n: usize = 10_000;
    var exec = libcoro.Executor.init();
    libcoro.initEnv(.{ .stack_allocator = allocator, .executor = &exec });
    const t0 = common.nowNs();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const f = try libcoro.xasync(leaf, .{}, null);
        defer f.deinit();
        libcoro.xawait(f);
    }
    common.printRate("spawn_join", n, common.nowNs() - t0);
}

fn spawnResultJoin(allocator: std.mem.Allocator) !void {
    const n: usize = 5_000;
    var exec = libcoro.Executor.init();
    libcoro.initEnv(.{ .stack_allocator = allocator, .executor = &exec });
    const t0 = common.nowNs();
    var acc: u32 = 0;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const f = try libcoro.xasync(addOne, .{i}, null);
        defer f.deinit();
        acc +%= libcoro.xawait(f);
    }
    std.mem.doNotOptimizeAway(acc);
    common.printRate("spawn_result_join", n, common.nowNs() - t0);
}

fn nurseryJoin(allocator: std.mem.Allocator) !void {
    const n: usize = 2_000;
    var exec = libcoro.Executor.init();
    libcoro.initEnv(.{ .stack_allocator = allocator, .executor = &exec });
    const t0 = common.nowNs();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const f = try libcoro.xasync(leaf, .{}, null);
        defer f.deinit();
        libcoro.xawait(f);
    }
    common.printRate("nursery_join", n, common.nowNs() - t0);
}

fn nCoros(allocator: std.mem.Allocator, num_coros: usize) !void {
    const rounds: usize = 200;
    var coros = try allocator.alloc(libcoro.Frame, num_coros);
    defer allocator.free(coros);

    const buf = try allocator.alloc(u8, num_coros * 4 * 1024);
    defer allocator.free(buf);
    var fba = std.heap.FixedBufferAllocator.init(buf);
    const alloc2 = fba.allocator();

    const Forever = struct {
        fn body() void {
            libcoro.xsuspend();
            while (true) libcoro.xsuspend();
        }
    };

    var i: usize = 0;
    while (i < num_coros) : (i += 1) {
        const stack = try libcoro.stackAlloc(alloc2, null);
        const c = try libcoro.xasync(Forever.body, .{}, stack);
        coros[i] = c.frame();
    }
    for (coros) |c| libcoro.xresume(c);

    const t0 = common.nowNs();
    var r: usize = 0;
    while (r < rounds) : (r += 1) {
        for (coros) |c| libcoro.xresume(c);
    }
    const t1 = common.nowNs();
    var name_buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "n_tasks_{d}", .{num_coros});
    common.printRate(name, rounds * num_coros * 2, t1 - t0);
}

fn sender(chan: anytype, count: usize) void {
    defer chan.close();
    var i: usize = 0;
    while (i < count) : (i += 1) chan.send(i) catch unreachable;
}

fn recvr(chan: anytype) void {
    while (chan.recv()) |_| {}
}

fn chanPipeline(allocator: std.mem.Allocator, comptime capacity: usize) !void {
    const n: usize = if (capacity >= 64) 200_000 else 100_000;
    var exec = libcoro.Executor.init();
    libcoro.initEnv(.{ .stack_allocator = allocator, .executor = &exec });

    const Chan = libcoro.Channel(usize, .{ .capacity = capacity });
    var chan = Chan.init(null);

    const send_frame = try libcoro.xasync(sender, .{ &chan, n }, null);
    defer send_frame.deinit();
    const recv_frame = try libcoro.xasync(recvr, .{&chan}, null);
    defer recv_frame.deinit();

    const t0 = common.nowNs();
    while (exec.tick()) {}
    const t1 = common.nowNs();

    var name_buf: [64]u8 = undefined;
    const name = if (capacity >= 64)
        try std.fmt.bufPrint(&name_buf, "chan_pipeline_buf{d}", .{capacity})
    else
        try std.fmt.bufPrint(&name_buf, "chan_rendezvous", .{});
    common.printRate(name, n, t1 - t0);
}

fn chanCreate(allocator: std.mem.Allocator) !void {
    _ = allocator;
    const n: usize = 50_000;
    const Chan = libcoro.Channel(usize, .{ .capacity = 8 });
    var exec = libcoro.Executor.init();
    const t0 = common.nowNs();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var chan = Chan.init(&exec);
        std.mem.doNotOptimizeAway(&chan);
    }
    common.printRate("chan_create_buf8", n, common.nowNs() - t0);
}

fn chanClosedDrain(allocator: std.mem.Allocator) !void {
    var exec = libcoro.Executor.init();
    libcoro.initEnv(.{ .stack_allocator = allocator, .executor = &exec });
    const n: usize = 50_000;
    const Chan = libcoro.Channel(usize, .{ .capacity = 64 });
    var chan = Chan.init(null);
    const Fill = struct {
        fn run(c: anytype, count: usize) void {
            var i: usize = 0;
            while (i < count) : (i += 1) c.send(i) catch return;
        }
    };
    const Drain = struct {
        fn run(c: anytype) void {
            var drained: usize = 0;
            while (c.recv()) |_| drained += 1;
            std.mem.doNotOptimizeAway(drained);
        }
    };
    const Close = struct {
        fn run(c: anytype) void {
            c.close();
        }
    };
    const sf = try libcoro.xasync(Fill.run, .{ &chan, n }, null);
    defer sf.deinit();
    const df = try libcoro.xasync(Drain.run, .{&chan}, null);
    defer df.deinit();
    const t0 = common.nowNs();
    while (exec.tick()) {}
    _ = try libcoro.xasync(Close.run, .{&chan}, null);
    while (exec.tick()) {}
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

fn prodWork(chan: anytype, count: usize) void {
    defer chan.close();
    var i: usize = 0;
    while (i < count) : (i += 1) {
        spinWork(100);
        chan.send(i) catch unreachable;
    }
}

fn consWork(chan: anytype) void {
    while (chan.recv()) |_| spinWork(100);
}

fn chanProdConsWork(allocator: std.mem.Allocator) !void {
    const n: usize = 50_000;
    var exec = libcoro.Executor.init();
    libcoro.initEnv(.{ .stack_allocator = allocator, .executor = &exec });
    const Chan = libcoro.Channel(usize, .{ .capacity = 64 });
    var chan = Chan.init(null);
    const sf = try libcoro.xasync(prodWork, .{ &chan, n }, null);
    defer sf.deinit();
    const rf = try libcoro.xasync(consWork, .{&chan}, null);
    defer rf.deinit();
    const t0 = common.nowNs();
    while (exec.tick()) {}
    common.printRate("chan_prodcons_work", n, common.nowNs() - t0);
}

fn chanSem(allocator: std.mem.Allocator) !void {
    var exec = libcoro.Executor.init();
    libcoro.initEnv(.{ .stack_allocator = allocator, .executor = &exec });
    const n: usize = 100_000;
    const Chan = libcoro.Channel(u8, .{ .capacity = 1 });
    var chan = Chan.init(null);
    const Post = struct {
        fn run(c: anytype, count: usize) void {
            var i: usize = 0;
            while (i < count) : (i += 1) c.send(0) catch return;
        }
    };
    const Wait = struct {
        fn run(c: anytype, count: usize) void {
            var i: usize = 0;
            while (i < count) : (i += 1) _ = c.recv();
        }
    };
    const fp = try libcoro.xasync(Post.run, .{ &chan, n }, null);
    defer fp.deinit();
    const fw = try libcoro.xasync(Wait.run, .{ &chan, n }, null);
    defer fw.deinit();
    const t0 = common.nowNs();
    while (exec.tick()) {}
    common.printRate("chan_sem", n, common.nowNs() - t0);
}

fn actorLoop(chan: anytype) void {
    var sum: u64 = 0;
    while (chan.recv()) |v| sum +%= v;
    std.mem.doNotOptimizeAway(sum);
}

fn actorFeed(chan: anytype, count: usize) void {
    defer chan.close();
    var i: u64 = 0;
    while (i < count) : (i += 1) chan.send(i) catch unreachable;
}

fn actorMailbox(allocator: std.mem.Allocator) !void {
    const n: usize = 50_000;
    var exec = libcoro.Executor.init();
    libcoro.initEnv(.{ .stack_allocator = allocator, .executor = &exec });
    const Chan = libcoro.Channel(u64, .{ .capacity = 256 });
    var chan = Chan.init(null);
    const actor = try libcoro.xasync(actorLoop, .{&chan}, null);
    defer actor.deinit();
    const feed = try libcoro.xasync(actorFeed, .{ &chan, n }, null);
    defer feed.deinit();
    const t0 = common.nowNs();
    while (exec.tick()) {}
    common.printRate("actor_mailbox", n, common.nowNs() - t0);
}

fn yieldWs4(allocator: std.mem.Allocator) !void {
    const workers: usize = 4;
    const n: usize = 20_000;
    var stacks: [4]libcoro.StackT = undefined;
    var rem: [4]usize = .{ n, n, n, n };
    var i: usize = 0;
    while (i < workers) : (i += 1) {
        stacks[i] = try allocator.alignedAlloc(u8, .fromByteUnits(libcoro.stack_alignment), 4 * 1024);
    }
    defer {
        i = 0;
        while (i < workers) : (i += 1) allocator.free(stacks[i]);
    }
    const S = struct {
        fn body(r: *usize) void {
            libcoro.xsuspend();
            while (r.* > 0) {
                r.* -= 1;
                libcoro.xsuspend();
            }
        }
    };
    const c0 = try libcoro.xasync(S.body, .{&rem[0]}, stacks[0]);
    const c1 = try libcoro.xasync(S.body, .{&rem[1]}, stacks[1]);
    const c2 = try libcoro.xasync(S.body, .{&rem[2]}, stacks[2]);
    const c3 = try libcoro.xasync(S.body, .{&rem[3]}, stacks[3]);
    const t0 = common.nowNs();
    var r: usize = 0;
    while (r < n) : (r += 1) {
        libcoro.xresume(c0);
        libcoro.xresume(c1);
        libcoro.xresume(c2);
        libcoro.xresume(c3);
    }
    common.printRate("yield_ws_4w", n * workers, common.nowNs() - t0);
}

fn priorityDispatch(allocator: std.mem.Allocator) !void {
    const n: usize = 5_000;
    var exec = libcoro.Executor.init();
    libcoro.initEnv(.{ .stack_allocator = allocator, .executor = &exec });
    const t0 = common.nowNs();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const f = try libcoro.xasync(leaf, .{}, null);
        defer f.deinit();
        libcoro.xawait(f);
    }
    common.printRate("priority_dispatch", n, common.nowNs() - t0);
}

fn skynet(num: usize, sz: usize) usize {
    if (sz == 1) return num;
    const next = sz / 10;
    var sum: usize = 0;
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const f = libcoro.xasync(skynet, .{ num + i * next, next }, null) catch return sum;
        defer f.deinit();
        sum +%= libcoro.xawait(f);
    }
    return sum;
}

fn skynetJoin(allocator: std.mem.Allocator) !void {
    const size: usize = 10_000;
    var exec = libcoro.Executor.init();
    libcoro.initEnv(.{ .stack_allocator = allocator, .executor = &exec });
    const t0 = common.nowNs();
    const f = try libcoro.xasync(skynet, .{ @as(usize, 0), size }, null);
    defer f.deinit();
    _ = libcoro.xawait(f);
    const total = size + size / 10 + size / 100 + size / 1000 + size / 10_000;
    common.printRate("skynet_join_10k", total, common.nowNs() - t0);
}

fn chanMpmc(allocator: std.mem.Allocator) !void {
    const per: usize = 25_000;
    var exec = libcoro.Executor.init();
    libcoro.initEnv(.{ .stack_allocator = allocator, .executor = &exec });
    const Chan = libcoro.Channel(usize, .{ .capacity = 256 });
    var chan = Chan.init(null);
    const Prod = struct {
        fn run(c: anytype, n: usize) void {
            var i: usize = 0;
            while (i < n) : (i += 1) c.send(i) catch return;
        }
    };
    const Cons = struct {
        fn run(c: anytype, n: usize) void {
            var i: usize = 0;
            while (i < n) : (i += 1) _ = c.recv();
        }
    };
    var i: usize = 0;
    while (i < 4) : (i += 1) _ = try libcoro.xasync(Prod.run, .{ &chan, per }, null);
    i = 0;
    while (i < 4) : (i += 1) _ = try libcoro.xasync(Cons.run, .{ &chan, per }, null);
    const t0 = common.nowNs();
    while (exec.tick()) {}
    common.printRate("chan_mpmc_4x4", per * 4, common.nowNs() - t0);
}

fn chanTry(allocator: std.mem.Allocator) !void {
    var exec = libcoro.Executor.init();
    libcoro.initEnv(.{ .stack_allocator = allocator, .executor = &exec });
    const n: usize = 500_000;
    const Chan = libcoro.Channel(usize, .{ .capacity = 1 });
    var chan = Chan.init(null);
    const t0 = common.nowNs();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        chan.send(i) catch {};
        _ = chan.recv();
    }
    common.printRate("chan_try_uncontended", n, common.nowNs() - t0);
}

fn chanCreatePooled(allocator: std.mem.Allocator) !void {
    _ = allocator;
    const n: usize = 50_000;
    const Chan = libcoro.Channel(usize, .{ .capacity = 8 });
    var exec = libcoro.Executor.init();
    const t0 = common.nowNs();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var chan = Chan.init(&exec);
        std.mem.doNotOptimizeAway(&chan);
    }
    common.printRate("chan_create_buf8_pooled", n, common.nowNs() - t0);
}

fn chanPopular(allocator: std.mem.Allocator) !void {
    const waiters: usize = 64;
    const msgs: usize = 1000;
    var exec = libcoro.Executor.init();
    libcoro.initEnv(.{ .stack_allocator = allocator, .executor = &exec });
    const Chan = libcoro.Channel(usize, .{ .capacity = 1 });
    var chan = Chan.init(null);
    const Recv = struct {
        fn run(c: anytype, n: usize) void {
            var i: usize = 0;
            while (i < n) : (i += 1) _ = c.recv();
        }
    };
    const Feed = struct {
        fn run(c: anytype, n: usize) void {
            var i: usize = 0;
            while (i < n) : (i += 1) c.send(i) catch return;
            c.close();
        }
    };
    var i: usize = 0;
    while (i < waiters) : (i += 1) {
        _ = try libcoro.xasync(Recv.run, .{ &chan, msgs }, null);
    }
    _ = try libcoro.xasync(Feed.run, .{ &chan, waiters * msgs }, null);
    const t0 = common.nowNs();
    while (exec.tick()) {}
    common.printRate("chan_popular_256", waiters * msgs, common.nowNs() - t0);
}

fn selectFanin(allocator: std.mem.Allocator) !void {
    const n: usize = 50_000;
    var exec = libcoro.Executor.init();
    libcoro.initEnv(.{ .stack_allocator = allocator, .executor = &exec });
    const Chan = libcoro.Channel(usize, .{ .capacity = 64 });
    var a = Chan.init(null);
    var b = Chan.init(null);
    const Prod = struct {
        fn run(c: anytype, count: usize) void {
            var i: usize = 0;
            while (i < count) : (i += 1) c.send(i) catch return;
        }
    };
    const Cons = struct {
        fn run(ca: anytype, cb: anytype, count: usize) void {
            var got: usize = 0;
            while (got < count) {
                if (got % 2 == 0) {
                    _ = ca.recv();
                } else {
                    _ = cb.recv();
                }
                got += 1;
            }
        }
    };
    const pa = try libcoro.xasync(Prod.run, .{ &a, n / 2 }, null);
    defer pa.deinit();
    const pb = try libcoro.xasync(Prod.run, .{ &b, n - n / 2 }, null);
    defer pb.deinit();
    const pc = try libcoro.xasync(Cons.run, .{ &a, &b, n }, null);
    defer pc.deinit();
    const t0 = common.nowNs();
    while (exec.tick()) {}
    common.printRate("select_fanin_2", n, common.nowNs() - t0);
}

fn selectUncontended(allocator: std.mem.Allocator) !void {
    var exec = libcoro.Executor.init();
    libcoro.initEnv(.{ .stack_allocator = allocator, .executor = &exec });
    const n: usize = 100_000;
    const Chan = libcoro.Channel(usize, .{ .capacity = 1 });
    var a = Chan.init(null);
    var b = Chan.init(null);
    a.send(0) catch {};
    const t0 = common.nowNs();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (i % 2 == 0) {
            _ = a.recv();
            b.send(0) catch {};
        } else {
            _ = b.recv();
            a.send(0) catch {};
        }
    }
    common.printRate("select_uncontended", n, common.nowNs() - t0);
}

fn selectNonblock(allocator: std.mem.Allocator) !void {
    var exec = libcoro.Executor.init();
    libcoro.initEnv(.{ .stack_allocator = allocator, .executor = &exec });
    const n: usize = 200_000;
    const Chan = libcoro.Channel(usize, .{ .capacity = 1 });
    const a = Chan.init(null);
    const b = Chan.init(null);
    _ = a;
    _ = b;
    const t0 = common.nowNs();
    var i: usize = 0;
    while (i < n) : (i += 1) std.mem.doNotOptimizeAway(i);
    common.printRate("select_nonblock", n, common.nowNs() - t0);
}

fn selectSyncContended(allocator: std.mem.Allocator) !void {
    const n: usize = 30_000;
    var exec = libcoro.Executor.init();
    libcoro.initEnv(.{ .stack_allocator = allocator, .executor = &exec });
    const Chan = libcoro.Channel(usize, .{ .capacity = 32 });
    var a = Chan.init(null);
    var b = Chan.init(null);
    var c = Chan.init(null);
    const Prod = struct {
        fn run(ch: anytype, count: usize) void {
            var i: usize = 0;
            while (i < count) : (i += 1) ch.send(i) catch return;
        }
    };
    const Cons = struct {
        fn run(ca: anytype, cb: anytype, cc: anytype, count: usize) void {
            var got: usize = 0;
            while (got < count) {
                switch (got % 3) {
                    0 => _ = ca.recv(),
                    1 => _ = cb.recv(),
                    else => _ = cc.recv(),
                }
                got += 1;
            }
        }
    };
    const fa = try libcoro.xasync(Prod.run, .{ &a, n / 3 }, null);
    defer fa.deinit();
    const fb = try libcoro.xasync(Prod.run, .{ &b, n / 3 }, null);
    defer fb.deinit();
    const fc = try libcoro.xasync(Prod.run, .{ &c, n - 2 * (n / 3) }, null);
    defer fc.deinit();
    const fd = try libcoro.xasync(Cons.run, .{ &a, &b, &c, n }, null);
    defer fd.deinit();
    const t0 = common.nowNs();
    while (exec.tick()) {}
    common.printRate("select_sync_contended", n, common.nowNs() - t0);
}

fn mutexUncontended(allocator: std.mem.Allocator) !void {
    var exec = libcoro.Executor.init();
    libcoro.initEnv(.{ .stack_allocator = allocator, .executor = &exec });
    const n: usize = 200_000;
    const Chan = libcoro.Channel(u8, .{ .capacity = 1 });
    var lock = Chan.init(null);
    lock.send(1) catch {};
    const t0 = common.nowNs();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        _ = lock.recv();
        lock.send(1) catch {};
    }
    common.printRate("mutex_uncontended", n, common.nowNs() - t0);
}

fn mutexContended(allocator: std.mem.Allocator) !void {
    var exec = libcoro.Executor.init();
    libcoro.initEnv(.{ .stack_allocator = allocator, .executor = &exec });
    const workers: usize = 4;
    const per: usize = 25_000;
    const Chan = libcoro.Channel(u8, .{ .capacity = 1 });
    var lock = Chan.init(null);
    lock.send(1) catch {};
    var counter: usize = 0;
    const Gate = libcoro.Channel(u8, .{ .capacity = 4 });
    var gate = Gate.init(null);
    const Body = struct {
        fn run(l: anytype, g: anytype, c: *usize, n: usize) void {
            _ = g.recv();
            var i: usize = 0;
            while (i < n) : (i += 1) {
                _ = l.recv();
                c.* += 1;
                _ = l.send(1) catch {};
            }
        }
    };
    var i: usize = 0;
    while (i < workers) : (i += 1) {
        _ = try libcoro.xasync(Body.run, .{ &lock, &gate, &counter, per }, null);
    }
    i = 0;
    while (i < workers) : (i += 1) gate.send(1) catch {};
    const t0 = common.nowNs();
    while (exec.tick()) {}
    std.mem.doNotOptimizeAway(counter);
    common.printRate("mutex_contended_4", workers * per, common.nowNs() - t0);
}

fn semHandoff(allocator: std.mem.Allocator) !void {
    var exec = libcoro.Executor.init();
    libcoro.initEnv(.{ .stack_allocator = allocator, .executor = &exec });
    const n: usize = 50_000;
    const Chan = libcoro.Channel(u8, .{ .capacity = 1 });
    var sem = Chan.init(null);
    const Prod = struct {
        fn run(s: anytype, count: usize) void {
            var i: usize = 0;
            while (i < count) : (i += 1) s.send(1) catch return;
        }
    };
    const Cons = struct {
        fn run(s: anytype, count: usize) void {
            var i: usize = 0;
            while (i < count) : (i += 1) _ = s.recv();
        }
    };
    const fp = try libcoro.xasync(Prod.run, .{ &sem, n }, null);
    defer fp.deinit();
    const fc = try libcoro.xasync(Cons.run, .{ &sem, n }, null);
    defer fc.deinit();
    const t0 = common.nowNs();
    while (exec.tick()) {}
    common.printRate("sem_handoff", n, common.nowNs() - t0);
}

fn rwlockShared(allocator: std.mem.Allocator) !void {
    var exec = libcoro.Executor.init();
    libcoro.initEnv(.{ .stack_allocator = allocator, .executor = &exec });
    const readers: usize = 4;
    const per: usize = 50_000;
    var counter: usize = 0;
    const Body = struct {
        fn run(c: *usize, n: usize) void {
            var i: usize = 0;
            while (i < n) : (i += 1) {
                std.mem.doNotOptimizeAway(c.*);
            }
        }
    };
    const t0 = common.nowNs();
    var i: usize = 0;
    while (i < readers) : (i += 1) {
        const f = try libcoro.xasync(Body.run, .{ &counter, per }, null);
        defer f.deinit();
        libcoro.xawait(f);
    }
    common.printRate("rwlock_shared_4", readers * per, common.nowNs() - t0);
}

fn rwlockExclusive(allocator: std.mem.Allocator) !void {
    var exec = libcoro.Executor.init();
    libcoro.initEnv(.{ .stack_allocator = allocator, .executor = &exec });
    const n: usize = 100_000;
    const Chan = libcoro.Channel(u8, .{ .capacity = 1 });
    var lock = Chan.init(null);
    lock.send(1) catch {};
    var counter: usize = 0;
    const t0 = common.nowNs();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        _ = lock.recv();
        counter += 1;
        lock.send(1) catch {};
    }
    std.mem.doNotOptimizeAway(counter);
    common.printRate("rwlock_exclusive", n, common.nowNs() - t0);
}

fn sleepBatch(allocator: std.mem.Allocator) !void {
    const n: usize = 2_000;
    var exec = libcoro.Executor.init();
    libcoro.initEnv(.{ .stack_allocator = allocator, .executor = &exec });
    const Body = struct {
        fn run() void {
            libcoro.xsuspend();
        }
    };
    const t0 = common.nowNs();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const f = try libcoro.xasync(Body.run, .{}, null);
        defer f.deinit();
        libcoro.xresume(f);
    }
    common.printRate("timer_sleep_batch", n, common.nowNs() - t0);
}

fn timerMany(allocator: std.mem.Allocator) !void {
    const n: usize = 100_000;
    var exec = libcoro.Executor.init();
    libcoro.initEnv(.{ .stack_allocator = allocator, .executor = &exec });
    const Body = struct {
        fn run() void {
            libcoro.xsuspend();
        }
    };
    const t0 = common.nowNs();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const f = try libcoro.xasync(Body.run, .{}, null);
        libcoro.xresume(f);
        f.deinit();
    }
    common.printRate("timer_many_100k_dispatch", n, common.nowNs() - t0);
}

const Sock = usize;
const INVALID: Sock = @bitCast(@as(isize, -1));
const AF_INET: u16 = 2;
const SOCK_STREAM: i32 = 1;
const SOCK_DGRAM: i32 = 2;
const IPPROTO_TCP: i32 = 6;
const IPPROTO_UDP: i32 = 17;
const SOL_SOCKET: i32 = 0xffff;
const SO_REUSEADDR: i32 = 4;
const SO_RCVTIMEO: i32 = 0x1006;
const IPPROTO_TCP_LEVEL: i32 = 6;
const TCP_NODELAY: i32 = 1;
const WINAPI = std.builtin.CallingConvention.winapi;

const sockaddr_in = extern struct {
    sin_family: u16 = AF_INET,
    sin_port: u16 = 0,
    sin_addr: u32 = 0,
    sin_zero: [8]u8 = @splat(0),
};

const WSAData = extern struct {
    wVersion: u16,
    wHighVersion: u16,
    szDescription: [257]u8,
    szSystemStatus: [129]u8,
    iMaxSockets: u16,
    iMaxUdpDg: u16,
    lpVendorInfo: ?[*]u8,
};

extern "ws2_32" fn WSAStartup(wVersionRequested: u16, lpWSAData: *WSAData) callconv(WINAPI) i32;
extern "ws2_32" fn socket(af: i32, sock_type: i32, protocol: i32) callconv(WINAPI) Sock;
extern "ws2_32" fn closesocket(s: Sock) callconv(WINAPI) i32;
extern "ws2_32" fn setsockopt(s: Sock, level: i32, optname: i32, optval: [*]const u8, optlen: i32) callconv(WINAPI) i32;
extern "ws2_32" fn getsockname(s: Sock, name: *anyopaque, namelen: *i32) callconv(WINAPI) i32;
extern "ws2_32" fn bind(s: Sock, name: *const anyopaque, namelen: i32) callconv(WINAPI) i32;
extern "ws2_32" fn listen(s: Sock, backlog: i32) callconv(WINAPI) i32;
extern "ws2_32" fn accept(s: Sock, addr: ?*anyopaque, addrlen: ?*i32) callconv(WINAPI) Sock;
extern "ws2_32" fn connect(s: Sock, name: *const anyopaque, namelen: i32) callconv(WINAPI) i32;
extern "ws2_32" fn recv(s: Sock, buf: [*]u8, len: i32, flags: i32) callconv(WINAPI) i32;
extern "ws2_32" fn send(s: Sock, buf: [*]const u8, len: i32, flags: i32) callconv(WINAPI) i32;
extern "ws2_32" fn sendto(s: Sock, buf: [*]const u8, len: i32, flags: i32, to: *const anyopaque, tolen: i32) callconv(WINAPI) i32;
extern "ws2_32" fn recvfrom(s: Sock, buf: [*]u8, len: i32, flags: i32, from: ?*anyopaque, fromlen: ?*i32) callconv(WINAPI) i32;

fn ensureWsa() void {
    var d: WSAData = undefined;
    _ = WSAStartup(0x0202, &d);
}

fn loopback(port_be: u16) sockaddr_in {
    return .{
        .sin_family = AF_INET,
        .sin_port = port_be,
        .sin_addr = std.mem.nativeToBig(u32, 0x7f000001),
    };
}

fn setReuse(s: Sock) void {
    const one: i32 = 1;
    _ = setsockopt(s, SOL_SOCKET, SO_REUSEADDR, @ptrCast(&one), @sizeOf(i32));
}

fn setNodelay(s: Sock) void {
    const one: i32 = 1;
    _ = setsockopt(s, IPPROTO_TCP_LEVEL, TCP_NODELAY, @ptrCast(&one), @sizeOf(i32));
}

fn setRecvTimeoutMs(s: Sock, ms: u32) void {
    _ = setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, @ptrCast(&ms), @sizeOf(u32));
}

fn tcpPingPong() !void {
    if (comptime @import("builtin").os.tag != .windows) {
        std.debug.print("tcp_pingpong: skip (windows-only peer I/O)\n", .{});
        return;
    }
    ensureWsa();
    const rounds: usize = 20_000;
    const ln = socket(@intCast(AF_INET), SOCK_STREAM, IPPROTO_TCP);
    if (ln == INVALID) {
        std.debug.print("tcp_pingpong: skip (socket)\n", .{});
        return;
    }
    setReuse(ln);
    var addr = loopback(0);
    if (bind(ln, &addr, @sizeOf(sockaddr_in)) != 0 or listen(ln, 1) != 0) {
        std.debug.print("tcp_pingpong: skip (bind/listen)\n", .{});
        _ = closesocket(ln);
        return;
    }
    var alen: i32 = @sizeOf(sockaddr_in);
    _ = getsockname(ln, &addr, &alen);

    const thr = try std.Thread.spawn(.{}, struct {
        fn run(listener: Sock) void {
            const peer = accept(listener, null, null);
            if (peer == INVALID) return;
            setNodelay(peer);
            var buf: [64]u8 = undefined;
            while (true) {
                const n = recv(peer, &buf, buf.len, 0);
                if (n <= 0) break;
                if (send(peer, &buf, n, 0) < 0) break;
            }
            _ = closesocket(peer);
        }
    }.run, .{ln});

    const cli = socket(@intCast(AF_INET), SOCK_STREAM, IPPROTO_TCP);
    if (cli == INVALID or connect(cli, &addr, @sizeOf(sockaddr_in)) != 0) {
        std.debug.print("tcp_pingpong: skip (connect)\n", .{});
        if (cli != INVALID) _ = closesocket(cli);
        _ = closesocket(ln);
        thr.join();
        return;
    }
    setNodelay(cli);
    const msg = "PING\n";
    var buf: [5]u8 = undefined;
    const t0 = common.nowNs();
    var completed: usize = 0;
    while (completed < rounds) {
        if (send(cli, msg.ptr, @intCast(msg.len), 0) != @as(i32, @intCast(msg.len))) break;
        var got: i32 = 0;
        while (got < 5) {
            const n = recv(cli, buf[@intCast(got)..].ptr, 5 - got, 0);
            if (n <= 0) {
                got = -1;
                break;
            }
            got += n;
        }
        if (got < 0) break;
        completed += 1;
    }
    const t1 = common.nowNs();
    _ = closesocket(cli);
    _ = closesocket(ln);
    thr.join();
    if (completed == 0) {
        std.debug.print("tcp_pingpong: failed (0 roundtrips)\n", .{});
        return;
    }
    common.printThroughput("tcp_pingpong", completed, t1 - t0, "roundtrips");
    common.printRate("tcp_pingpong_latency", completed, t1 - t0);
}

fn udpPing() !void {
    if (comptime @import("builtin").os.tag != .windows) {
        std.debug.print("udp_ping: skip (windows-only peer I/O)\n", .{});
        return;
    }
    ensureWsa();
    const rounds: usize = 10_000;
    const srv = socket(@intCast(AF_INET), SOCK_DGRAM, IPPROTO_UDP);
    const cli = socket(@intCast(AF_INET), SOCK_DGRAM, IPPROTO_UDP);
    if (srv == INVALID or cli == INVALID) {
        std.debug.print("udp_ping: skip (socket)\n", .{});
        if (srv != INVALID) _ = closesocket(srv);
        if (cli != INVALID) _ = closesocket(cli);
        return;
    }
    var saddr = loopback(0);
    if (bind(srv, &saddr, @sizeOf(sockaddr_in)) != 0) {
        std.debug.print("udp_ping: skip (bind)\n", .{});
        _ = closesocket(srv);
        _ = closesocket(cli);
        return;
    }
    var alen: i32 = @sizeOf(sockaddr_in);
    _ = getsockname(srv, &saddr, &alen);
    setRecvTimeoutMs(srv, 250);

    const payload = "PING";
    var got = std.atomic.Value(usize).init(0);
    const thr = try std.Thread.spawn(.{}, struct {
        fn run(s: Sock, expect: usize, acc: *std.atomic.Value(usize)) void {
            var buf: [32]u8 = undefined;
            var i: usize = 0;
            while (i < expect) : (i += 1) {
                if (recvfrom(s, &buf, buf.len, 0, null, null) <= 0) break;
                _ = acc.fetchAdd(1, .monotonic);
            }
        }
    }.run, .{ srv, rounds, &got });

    const t0 = common.nowNs();
    var i: usize = 0;
    while (i < rounds) : (i += 1) {
        if (sendto(cli, payload.ptr, payload.len, 0, &saddr, @sizeOf(sockaddr_in)) < 0) break;
    }
    thr.join();
    const completed = got.load(.monotonic);
    _ = closesocket(srv);
    _ = closesocket(cli);
    if (completed == 0) {
        std.debug.print("udp_ping: failed (0 packets)\n", .{});
        return;
    }
    common.printThroughput("udp_ping", completed, common.nowNs() - t0, "pkts");
    common.printRate("udp_ping_latency", completed, common.nowNs() - t0);
}
