
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
