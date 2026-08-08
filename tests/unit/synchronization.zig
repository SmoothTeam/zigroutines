
const std = @import("std");
const zr = @import("zigroutines");

test "synchronization: mutex lock unlock" {
    if (!zr.context.supported) return error.SkipZigTest;

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var rt = try zr.Runtime.init(alloc, .{ .workers = 1, .stack_pool = false });
    defer rt.deinit();

    var mutex = zr.Mutex.init(alloc);
    defer mutex.deinit();

    const S = struct {
        var counter: u32 = 0;
        fn work(m: *zr.Mutex) void {
            m.lock();
            counter += 1;
            m.unlock();
        }
    };
    S.counter = 0;
    _ = try rt.spawn(.{}, S.work, .{&mutex});
    _ = try rt.spawn(.{}, S.work, .{&mutex});
    try rt.run();
    try std.testing.expectEqual(@as(u32, 2), S.counter);
}

test "synchronization: semaphore permit handoff" {
    if (!zr.context.supported) return error.SkipZigTest;

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var rt = try zr.Runtime.init(alloc, .{ .workers = 1, .stack_pool = false });
    defer rt.deinit();

    var sem = zr.Semaphore.init(alloc, 0);
    defer sem.deinit();

    const S = struct {
        var ok: bool = false;
        fn consumer(s: *zr.Semaphore) void {
            s.acquire();
            ok = true;
        }
        fn producer(s: *zr.Semaphore) void {
            s.release();
        }
    };
    S.ok = false;
    _ = try rt.spawn(.{}, S.consumer, .{&sem});
    _ = try rt.spawn(.{}, S.producer, .{&sem});
    try rt.run();
    try std.testing.expect(S.ok);
}

test "synchronization: rate limiter tryAcquire" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var limiter = zr.RateLimiter.init(alloc, 1000.0, 2.0);
    defer limiter.deinit();
    try std.testing.expect(limiter.tryAcquire());
    try std.testing.expect(limiter.tryAcquire());
    try std.testing.expect(!limiter.tryAcquire());
}

test "synchronization: notify wakes waiter" {
    if (!zr.context.supported) return error.SkipZigTest;

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var rt = try zr.Runtime.init(alloc, .{ .workers = 1, .stack_pool = false });
    defer rt.deinit();

    var n = zr.Notify.init(alloc);
    defer n.deinit();

    const S = struct {
        var ok: bool = false;
        fn waiter(note: *zr.Notify) void {
            note.wait();
            ok = true;
        }
        fn signaler(note: *zr.Notify) void {
            zr.yield();
            note.notifyOne();
        }
    };
    S.ok = false;
    _ = try rt.spawn(.{}, S.waiter, .{&n});
    _ = try rt.spawn(.{}, S.signaler, .{&n});
    try rt.run();
    try std.testing.expect(S.ok);
}

test "synchronization: watch broadcasts latest" {
    if (!zr.context.supported) return error.SkipZigTest;

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var rt = try zr.Runtime.init(alloc, .{ .workers = 1, .stack_pool = false });
    defer rt.deinit();

    const W = zr.Watch(u32);
    var w = W.init(alloc);
    defer w.deinit();

    const S = struct {
        var got: u32 = 0;
        fn consumer(watch: *W) void {
            const pair = watch.recv(0);
            got = pair[0];
        }
        fn producer(watch: *W) void {
            zr.yield();
            watch.send(42);
        }
    };
    S.got = 0;
    _ = try rt.spawn(.{}, S.consumer, .{&w});
    _ = try rt.spawn(.{}, S.producer, .{&w});
    try rt.run();
    try std.testing.expectEqual(@as(u32, 42), S.got);
}

test "synchronization: parking lot wakeOne" {
    if (!zr.context.supported) return error.SkipZigTest;

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var rt = try zr.Runtime.init(alloc, .{ .workers = 1, .stack_pool = false });
    defer rt.deinit();

    var lot = zr.ParkingLot.init(alloc);
    defer lot.deinit();

    const S = struct {
        var woke: bool = false;
        fn waiter(l: *zr.ParkingLot) void {
            l.park();
            woke = true;
        }
        fn waker(l: *zr.ParkingLot) void {
            zr.yield();
            l.wakeOne();
        }
    };
    S.woke = false;
    _ = try rt.spawn(.{}, S.waiter, .{&lot});
    _ = try rt.spawn(.{}, S.waker, .{&lot});
    try rt.run();
    try std.testing.expect(S.woke);
}
