const std = @import("std");
const zr = @import("zigroutines");
const common = @import("common.zig");

pub fn runAll(alloc: std.mem.Allocator) !void {
    try mutexUncontended(alloc);
    try mutexContended(alloc);
    try semaphoreHandoff(alloc);
    try rwlockShared(alloc);
    try rwlockExclusive(alloc);
}

fn mutexUncontended(alloc: std.mem.Allocator) !void {
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

    const t0 = common.nowNs();
    try rt.run();
    const t1 = common.nowNs();
    common.printRate("mutex_uncontended", n, t1 - t0);
}

fn mutexContended(alloc: std.mem.Allocator) !void {
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

    const t0 = common.nowNs();
    try rt.run();
    const t1 = common.nowNs();
    common.printRate("mutex_contended_4", workers * per, t1 - t0);
    if (counter != workers * per) {
        std.debug.print("  WARNING: counter={d} expected={d}\n", .{ counter, workers * per });
    }
}

fn semaphoreHandoff(alloc: std.mem.Allocator) !void {
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

    const t0 = common.nowNs();
    try rt.run();
    const t1 = common.nowNs();
    common.printRate("sem_handoff", n, t1 - t0);
}

fn rwlockShared(alloc: std.mem.Allocator) !void {
    const readers: usize = 4;
    const per: usize = 50_000;
    var rt = try zr.Runtime.init(alloc, .{
        .workers = 4,
        .policy = .work_stealing,
        .stack_pool = true,
    });
    defer rt.deinit();

    var lock = zr.RwLock.init(alloc);
    defer lock.deinit();
    var counter: usize = 0;

    const S = struct {
        fn reader(l: *zr.RwLock, c: *const usize, count: usize) void {
            var i: usize = 0;
            while (i < count) : (i += 1) {
                l.lockShared();
                std.mem.doNotOptimizeAway(c.*);
                l.unlockShared();
            }
        }
    };
    var r: usize = 0;
    while (r < readers) : (r += 1) {
        _ = try rt.spawn(.{}, S.reader, .{ &lock, &counter, per });
    }

    const t0 = common.nowNs();
    try rt.run();
    const t1 = common.nowNs();
    common.printRate("rwlock_shared_4", readers * per, t1 - t0);
}

fn rwlockExclusive(alloc: std.mem.Allocator) !void {
    const n: usize = 100_000;
    var rt = try zr.Runtime.init(alloc, .{ .workers = 1, .stack_pool = true });
    defer rt.deinit();

    var lock = zr.RwLock.init(alloc);
    defer lock.deinit();
    var counter: usize = 0;

    const S = struct {
        fn writer(l: *zr.RwLock, c: *usize, count: usize) void {
            var i: usize = 0;
            while (i < count) : (i += 1) {
                l.lockExclusive();
                c.* += 1;
                l.unlockExclusive();
            }
        }
    };
    _ = try rt.spawn(.{}, S.writer, .{ &lock, &counter, n });

    const t0 = common.nowNs();
    try rt.run();
    const t1 = common.nowNs();
    common.printRate("rwlock_exclusive", n, t1 - t0);
}
