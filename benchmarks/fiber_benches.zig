const std = @import("std");
const zr = @import("zigroutines");
const common = @import("common.zig");

pub fn runAll(alloc: std.mem.Allocator) !void {
    try pureCtxSwitchBounce(alloc);
    try yieldPingPong(alloc);
    try yieldLoopSingle(alloc);
    try yieldWorkStealing(alloc);
    try leafSpawnBatch(alloc);
    try spawnJoin(alloc);
    try spawnResultJoin(alloc);
    try priorityDispatch(alloc);
    try nurseryJoin(alloc);
    try nTasksScale(alloc);
    try skynetJoin(alloc);
    try stackProtectDensity(alloc);
}

fn pureCtxSwitchBounce(alloc: std.mem.Allocator) !void {
    if (comptime !zr.context.supported) return;
    const n: usize = 400_000;
    const stack_bytes: usize = 8 * 1024;

    const Pair = struct {
        a: zr.context.Context = .{},
        b: zr.context.Context = .{},
        main: zr.context.Context = .{},
        remain: usize = 0,

        fn entryA(arg: *anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(arg));
            while (self.remain > 0) {
                self.remain -= 1;
                zr.context.swap(&self.a, &self.b);
            }
            zr.context.swap(&self.a, &self.main);
        }
        fn entryB(arg: *anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(arg));
            while (true) {
                zr.context.swap(&self.b, &self.a);
            }
        }
    };

    var pair: Pair = .{ .remain = n };
    const sa = try alloc.alignedAlloc(u8, .fromByteUnits(16), stack_bytes);
    defer alloc.free(sa);
    const sb = try alloc.alignedAlloc(u8, .fromByteUnits(16), stack_bytes);
    defer alloc.free(sb);

    zr.context.make(&pair.a, sa, Pair.entryA, &pair);
    zr.context.make(&pair.b, sb, Pair.entryB, &pair);

    const t0 = common.nowNs();
    zr.context.swap(&pair.main, &pair.a);
    const t1 = common.nowNs();
    common.printRate("ctx_switch_bounce", n * 2, t1 - t0);
}

fn leafSpawnBatch(alloc: std.mem.Allocator) !void {
    const n: usize = 50_000;
    var rt = try zr.Runtime.init(alloc, .{ .workers = 1, .stack_pool = true, .task_freelist = true });
    defer rt.deinit();

    const S = struct {
        fn leaf() void {}
        fn spawner(r: *zr.Runtime, count: usize) void {
            var i: usize = 0;
            while (i < count) : (i += 1) {
                _ = r.spawnLeaf(.{}, leaf, .{}) catch return;
            }
        }
    };
    _ = try rt.spawn(.{}, S.spawner, .{ &rt, n });

    const t0 = common.nowNs();
    try rt.run();
    const t1 = common.nowNs();
    common.printRate("leaf_spawn_batch", n, t1 - t0);
}

fn yieldPingPong(alloc: std.mem.Allocator) !void {
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

    const t0 = common.nowNs();
    try rt.run();
    const t1 = common.nowNs();
    common.printRate("yield_pingpong", n * 2, t1 - t0);
}

fn yieldLoopSingle(alloc: std.mem.Allocator) !void {
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

    const t0 = common.nowNs();
    try rt.run();
    const t1 = common.nowNs();
    common.printRate("yield_single", n, t1 - t0);
}

fn yieldWorkStealing(alloc: std.mem.Allocator) !void {
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

    const t0 = common.nowNs();
    try rt.run();
    const t1 = common.nowNs();
    common.printRate("yield_ws_4w", n * workers, t1 - t0);
}

fn spawnJoin(alloc: std.mem.Allocator) !void {
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

    const t0 = common.nowNs();
    try rt.run();
    const t1 = common.nowNs();
    common.printRate("spawn_join", n, t1 - t0);
}

fn spawnResultJoin(alloc: std.mem.Allocator) !void {
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

    const t0 = common.nowNs();
    try rt.run();
    const t1 = common.nowNs();
    common.printRate("spawn_result_join", n, t1 - t0);
}

fn priorityDispatch(alloc: std.mem.Allocator) !void {
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

    const t0 = common.nowNs();
    try rt.run();
    const t1 = common.nowNs();
    common.printRate("priority_dispatch", n, t1 - t0);
}

fn nurseryJoin(alloc: std.mem.Allocator) !void {
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

    const t0 = common.nowNs();
    try rt.run();
    const t1 = common.nowNs();
    common.printRate("nursery_join", n, t1 - t0);
}

fn nTasksScale(alloc: std.mem.Allocator) !void {
    const counts = [_]usize{ 1_000, 10_000, 50_000 };
    const rounds: usize = 20;

    for (counts) |n| {
        var rt = try zr.Runtime.init(alloc, .{
            .workers = 1,
            .stack_pool = true,
        });
        defer rt.deinit();

        const S = struct {
            fn worker(iters: usize) void {
                var i: usize = 0;
                while (i < iters) : (i += 1) zr.yield();
            }
        };
        var i: usize = 0;
        while (i < n) : (i += 1) {
            _ = try rt.spawn(.{}, S.worker, .{rounds});
        }

        const t0 = common.nowNs();
        try rt.run();
        const t1 = common.nowNs();
        const ops = n * rounds;
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "n_tasks_{d}", .{n});
        common.printRate(name, ops, t1 - t0);
    }
}

fn skynetJoin(alloc: std.mem.Allocator) !void {
    const size: usize = 10_000;
    var rt = try zr.Runtime.init(alloc, .{
        .workers = 0,
        .policy = .work_stealing,
        .stack_pool = true,
        .task_freelist = true,
    });
    defer rt.deinit();

    const S = struct {
        fn skynet(r: *zr.Runtime, num: usize, sz: usize) usize {
            if (sz == 1) return num;
            const div: usize = 10;
            const next = sz / div;
            var sum: usize = 0;
            var i: usize = 0;
            var handles: [div]zr.TypedJoinHandle(usize) = undefined;
            while (i < div) : (i += 1) {
                const opts: zr.SpawnOptions = .{ .mode = if (next == 1) .leaf else .stackful };
                handles[i] = r.spawnResult(opts, skynet, .{ r, num + i * next, next }) catch {
                    return sum;
                };
            }
            i = 0;
            while (i < div) : (i += 1) {
                sum +%= handles[i].join();
            }
            return sum;
        }
        fn root(r: *zr.Runtime, sz: usize, out: *usize) void {
            out.* = skynet(r, 0, sz);
        }
    };

    var result: usize = 0;
    _ = try rt.spawn(.{}, S.root, .{ &rt, size, &result });

    const t0 = common.nowNs();
    try rt.run();
    const t1 = common.nowNs();
    const total_spawns = size + size / 10 + size / 100 + size / 1000 + size / 10000;
    common.printRate("skynet_join_10k", total_spawns, t1 - t0);
    std.mem.doNotOptimizeAway(result);
}

fn stackProtectDensity(alloc: std.mem.Allocator) !void {
    const n: usize = 10_000;
    try reportStackProtect("none", alloc, .none, n);
    try reportStackProtect("canary", alloc, .canary, n);
    try reportStackProtect("guard", alloc, .guard, n);

    var pool = zr.stack.Pool.initWith(alloc, .{ .protect = .guard });
    defer pool.deinit();
    const warmup = try pool.acquire(0);
    pool.release(warmup);
    const t0 = common.nowNs();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const s = try pool.acquire(0);
        pool.release(s);
    }
    const t1 = common.nowNs();
    common.printRate("spawn_guard_reuse", n, t1 - t0);
}

fn reportStackProtect(tag: []const u8, alloc: std.mem.Allocator, protect: zr.StackProtect, n: usize) !void {
    var pool = zr.stack.Pool.initWith(alloc, .{ .protect = protect });
    defer pool.deinit();
    const stacks = try alloc.alloc(zr.stack.Stack, n);
    defer alloc.free(stacks);

    const ws0 = workingSetBytes();
    for (stacks) |*s| {
        s.* = try pool.acquire(0);
        if (s.usable.len != 0) s.usable[s.usable.len - 1] = 1;
    }
    const ws1 = workingSetBytes();
    for (stacks) |s| pool.release(s);

    const delta = if (ws1 > ws0) ws1 - ws0 else 0;
    const per = if (n == 0) 0 else delta / n;
    std.debug.print("rss_stacks_{s}_{d}: working_set_delta={d} B  (~{d} B/stack, page_granule={d})\n", .{
        tag,
        n,
        delta,
        per,
        zr.stack.page_size,
    });
}

fn workingSetBytes() usize {
    if (comptime @import("builtin").os.tag != .windows) return 0;
    var pmc: ProcessMemoryCounters = .{
        .cb = @sizeOf(ProcessMemoryCounters),
    };
    if (K32GetProcessMemoryInfo(GetCurrentProcess(), &pmc, @sizeOf(ProcessMemoryCounters)) == 0) {
        return 0;
    }
    return pmc.WorkingSetSize;
}

const ProcessMemoryCounters = extern struct {
    cb: u32 = 0,
    PageFaultCount: u32 = 0,
    PeakWorkingSetSize: usize = 0,
    WorkingSetSize: usize = 0,
    QuotaPeakPagedPoolUsage: usize = 0,
    QuotaPagedPoolUsage: usize = 0,
    QuotaPeakNonPagedPoolUsage: usize = 0,
    QuotaNonPagedPoolUsage: usize = 0,
    PagefileUsage: usize = 0,
    PeakPagefileUsage: usize = 0,
};

extern "kernel32" fn GetCurrentProcess() callconv(.winapi) ?*anyopaque;
extern "kernel32" fn K32GetProcessMemoryInfo(process: ?*anyopaque, counters: *ProcessMemoryCounters, cb: u32) callconv(.winapi) i32;
