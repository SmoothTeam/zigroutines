const std = @import("std");
const zr = @import("zigroutines");

test "multi-arm select recv+send+default" {
    if (!zr.context.supported) return error.SkipZigTest;

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var rt = try zr.Runtime.init(alloc, .{ .workers = 1, .stack_pool = false });
    defer rt.deinit();

    const Ch = zr.Channel(u32);
    const S = struct {
        var ok: bool = false;
        fn work(a: *Ch, b: *Ch) void {
            const r = zr.select.multi(u32, .{
                .recv = &.{b},
                .send = &.{.{ .ch = a, .value = 42 }},
                .default = false,
            }, .{ .timers = null });
            switch (r) {
                .send => |s| {
                    _ = s;
                    ok = true;
                },
                .recv => {},
                else => {},
            }
            _ = a.recv() catch {};
        }
        fn consumer(a: *Ch) void {
            zr.yield();
            _ = a.recv() catch {};
        }
    };

    const a = try Ch.create(alloc, 1);
    defer a.destroy();
    const b = try Ch.create(alloc, 1);
    defer b.destroy();

    _ = try rt.spawn(.{}, S.work, .{ a, b });
    try rt.run();
    try std.testing.expect(S.ok);
}

test "select default arm" {
    if (!zr.context.supported) return error.SkipZigTest;

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var rt = try zr.Runtime.init(alloc, .{ .workers = 1, .stack_pool = false });
    defer rt.deinit();

    const Ch = zr.Channel(u32);
    const S = struct {
        var hit_default: bool = false;
        fn work(ch: *Ch) void {
            const r = zr.select.multi(u32, .{
                .recv = &.{ch},
                .default = true,
            }, .{});
            hit_default = (r == .default);
        }
    };

    const ch = try Ch.create(alloc, 1);
    defer ch.destroy();
    _ = try rt.spawn(.{}, S.work, .{ch});
    try rt.run();
    try std.testing.expect(S.hit_default);
}

test "channel backpressure drop_oldest" {
    if (!zr.context.supported) return error.SkipZigTest;

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var rt = try zr.Runtime.init(alloc, .{ .workers = 1, .stack_pool = false });
    defer rt.deinit();

    const Ch = zr.Channel(u32);
    const S = struct {
        var last: u32 = 0;
        var drops: u64 = 0;
        fn work(ch: *Ch) void {
            ch.send(1) catch unreachable;
            ch.send(2) catch unreachable;
            ch.send(3) catch unreachable;
            drops = ch.droppedCount();
            last = ch.recv() catch 0;
            _ = ch.recv() catch 0;
        }
    };

    const ch = try Ch.createWith(alloc, 2, .{ .full_policy = .drop_oldest });
    defer ch.destroy();
    _ = try rt.spawn(.{}, S.work, .{ch});
    try rt.run();
    try std.testing.expect(S.drops >= 1);
    try std.testing.expectEqual(@as(u32, 2), S.last);
}

test "channel error_full policy" {
    if (!zr.context.supported) return error.SkipZigTest;

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var rt = try zr.Runtime.init(alloc, .{ .workers = 1, .stack_pool = false });
    defer rt.deinit();

    const Ch = zr.Channel(u32);
    const S = struct {
        var got_full: bool = false;
        fn work(ch: *Ch) void {
            ch.send(1) catch unreachable;
            ch.send(2) catch |err| {
                got_full = (err == error.Full);
            };
        }
    };

    const ch = try Ch.createWith(alloc, 1, .{ .full_policy = .error_full });
    defer ch.destroy();
    _ = try rt.spawn(.{}, S.work, .{ch});
    try rt.run();
    try std.testing.expect(S.got_full);
}

test "nursery timeout cancels children" {
    if (!zr.context.supported) return error.SkipZigTest;

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var rt = try zr.Runtime.init(alloc, .{ .workers = 1, .stack_pool = false });
    defer rt.deinit();

    const S = struct {
        var saw_cancel: bool = false;
        fn child(tok: *zr.CancelToken) void {
            while (!tok.isCanceled()) {
                zr.yield();
            }
            saw_cancel = true;
        }
        fn parent(r: *zr.Runtime) void {
            var n = zr.Nursery.init(r, .{
                .timeout_ns = 2 * std.time.ns_per_ms,
                .cancel_on_leave = true,
            });
            defer n.deinit();
            _ = n.spawn(.{}, child, .{n.token()}) catch {};
            _ = n.join() catch {};
        }
    };

    _ = try rt.spawn(.{}, S.parent, .{&rt});
    try rt.run();
    try std.testing.expect(S.saw_cancel);
}

test "nursery tryJoin" {
    if (!zr.context.supported) return error.SkipZigTest;

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var rt = try zr.Runtime.init(alloc, .{ .workers = 1, .stack_pool = false });
    defer rt.deinit();

    const S = struct {
        var joined: bool = false;
        fn quick() void {}
        fn parent(r: *zr.Runtime) void {
            var n = zr.Nursery.init(r, .{});
            defer n.deinit();
            _ = n.spawn(.{}, quick, .{}) catch {};
            n.tryJoin(50 * std.time.ns_per_ms) catch return;
            joined = true;
        }
    };

    _ = try rt.spawn(.{}, S.parent, .{&rt});
    try rt.run();
    try std.testing.expect(S.joined);
}

test "semaphore and mutex" {
    if (!zr.context.supported) return error.SkipZigTest;

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var rt = try zr.Runtime.init(alloc, .{ .workers = 1, .stack_pool = false });
    defer rt.deinit();

    var sem = zr.Semaphore.init(alloc, 1);
    defer sem.deinit();
    var mtx = zr.Mutex.init(alloc);
    defer mtx.deinit();

    const S = struct {
        var counter: u32 = 0;
        fn work(s: *zr.Semaphore, m: *zr.Mutex) void {
            s.acquire();
            m.lock();
            counter += 1;
            m.unlock();
            s.release();
            s.acquire();
            counter += 1;
            s.release();
        }
    };

    _ = try rt.spawn(.{}, S.work, .{ &sem, &mtx });
    try rt.run();
    try std.testing.expectEqual(@as(u32, 2), S.counter);
}

test "semaphore park/wake handoff" {
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

    _ = try rt.spawn(.{}, S.consumer, .{&sem});
    _ = try rt.spawn(.{}, S.producer, .{&sem});
    try rt.run();
    try std.testing.expect(S.ok);
}

test "rwlock shared" {
    if (!zr.context.supported) return error.SkipZigTest;

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var rt = try zr.Runtime.init(alloc, .{ .workers = 1, .stack_pool = false });
    defer rt.deinit();

    var rw = zr.RwLock.init(alloc);
    defer rw.deinit();

    const S = struct {
        var n: u32 = 0;
        fn reader(l: *zr.RwLock) void {
            l.lockShared();
            n += 1;
            l.unlockShared();
        }
    };

    _ = try rt.spawn(.{}, S.reader, .{&rw});
    _ = try rt.spawn(.{}, S.reader, .{&rw});
    try rt.run();
    try std.testing.expectEqual(@as(u32, 2), S.n);
}

test "rate limiter tryAcquire" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var rl = zr.RateLimiter.init(alloc, 1000.0, 2.0);
    defer rl.deinit();
    try std.testing.expect(rl.tryAcquire());
    try std.testing.expect(rl.tryAcquire());
    try std.testing.expect(!rl.tryAcquire());
}

test "priority scheduler order" {
    if (!zr.context.supported) return error.SkipZigTest;

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var rt = try zr.Runtime.init(alloc, .{
        .workers = 1,
        .policy = .priority,
        .stack_pool = false,
    });
    defer rt.deinit();

    const S = struct {
        var order: [3]u8 = .{ 0, 0, 0 };
        var idx: usize = 0;
        fn low() void {
            order[idx] = 2;
            idx += 1;
        }
        fn high() void {
            order[idx] = 0;
            idx += 1;
        }
        fn mid() void {
            order[idx] = 1;
            idx += 1;
        }
    };

    _ = try rt.spawn(.{ .priority = 200 }, S.low, .{});
    _ = try rt.spawn(.{ .priority = 0 }, S.high, .{});
    _ = try rt.spawn(.{ .priority = 100 }, S.mid, .{});
    try rt.run();
    try std.testing.expectEqual(@as(u8, 0), S.order[0]);
    try std.testing.expectEqual(@as(u8, 1), S.order[1]);
    try std.testing.expectEqual(@as(u8, 2), S.order[2]);
}

test "thread_per_task runs" {
    if (!zr.context.supported) return error.SkipZigTest;

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var rt = try zr.Runtime.init(alloc, .{
        .policy = .thread_per_task,
        .stack_pool = false,
    });
    defer rt.deinit();

    const S = struct {
        var done: std.atomic.Value(bool) = .init(false);
        fn work() void {
            done.store(true, .release);
        }
    };

    _ = try rt.spawn(.{}, S.work, .{});
    try rt.run();
    try std.testing.expect(S.done.load(.acquire));
}

test "cooperative preempt checkpoint" {
    if (!zr.context.supported) return error.SkipZigTest;

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var rt = try zr.Runtime.init(alloc, .{
        .workers = 1,
        .stack_pool = false,
        .preempt = .{ .enabled = true, .quantum_ns = 1 },
    });
    defer rt.deinit();

    const S = struct {
        var ticks: u32 = 0;
        fn work() void {
            var i: u32 = 0;
            while (i < 5) : (i += 1) {
                ticks += 1;
                zr.checkpoint();
            }
        }
    };

    _ = try rt.spawn(.{}, S.work, .{});
    try rt.run();
    try std.testing.expectEqual(@as(u32, 5), S.ticks);
}

test "ring tracer receives events" {
    if (!zr.context.supported) return error.SkipZigTest;

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var buf: [64]zr.trace.Record = undefined;
    var ring = zr.trace.RingTracer.init(&buf);
    zr.trace.setTracer(ring.tracer());
    defer zr.trace.setTracer(null);

    var rt = try zr.Runtime.init(alloc, .{ .workers = 1, .stack_pool = false });
    defer rt.deinit();

    const S = struct {
        fn work() void {
            zr.yield();
        }
    };
    _ = try rt.spawn(.{}, S.work, .{});
    try rt.run();
    try std.testing.expect(ring.len() > 0);
}

test "actor mailbox" {
    if (!zr.context.supported) return error.SkipZigTest;

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var rt = try zr.Runtime.init(alloc, .{ .workers = 1, .stack_pool = false });
    defer rt.deinit();

    const S = struct {
        var sum: u32 = 0;
        fn handle(msg: u32) void {
            sum += msg;
        }
        fn driver(r: *zr.Runtime) void {
            const A = zr.Actor(u32);
            const actor = A.spawn(r, .{ .mailbox_capacity = 8 }, handle) catch return;
            actor.send(10) catch {};
            actor.send(5) catch {};
            actor.mailbox.close();
            actor.join();
            actor.destroy();
        }
    };

    _ = try rt.spawn(.{}, S.driver, .{&rt});
    try rt.run();
    try std.testing.expectEqual(@as(u32, 15), S.sum);
}

test "stack canary high-water" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const st = try zr.stack.allocWith(alloc, 16 * 1024, .{ .paint_canary = true });
    defer zr.stack.free(alloc, st);
    const b = st.bytes();
    b[b.len - 1] = 0x11;
    b[b.len - 64] = 0x22;
    const used = st.highWaterUsed();
    try std.testing.expect(used >= 1);
}

test "stack guard page allocates" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const st = try zr.stack.allocWith(alloc, 16 * 1024, .{ .guard_page = true, .paint_canary = true });
    defer zr.stack.free(alloc, st);
    try std.testing.expect(st.has_guard);
    try std.testing.expect(st.usable.len >= 16 * 1024);
}

test "iocp backend create/destroy" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var rt = try zr.Runtime.init(alloc, .{
        .workers = 1,
        .stack_pool = false,
        .io = .iocp,
    });
    defer rt.deinit();
    try std.testing.expect(rt.ioBackend() != null);
}

test "io_uring backend create/destroy" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var rt = try zr.Runtime.init(alloc, .{
        .workers = 1,
        .stack_pool = false,
        .io = .io_uring,
    });
    defer rt.deinit();
    try std.testing.expect(rt.ioBackend() != null);
}

test "version at least standards" {
    try std.testing.expect(zr.version.minor >= 8);
}
