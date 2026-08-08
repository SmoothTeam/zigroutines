const std = @import("std");
const zr = @import("zigroutines");
const common = @import("common.zig");

pub fn runAll(alloc: std.mem.Allocator) !void {
    try selectFanIn(alloc);
    try selectUncontended(alloc);
    try selectNonblock(alloc);
    try selectSyncContended(alloc);
}

fn selectFanIn(alloc: std.mem.Allocator) !void {
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

    const t0 = common.nowNs();
    try rt.run();
    const t1 = common.nowNs();
    common.printRate("select_fanin_2", n, t1 - t0);
}

fn selectUncontended(alloc: std.mem.Allocator) !void {
    const n: usize = 100_000;
    var rt = try zr.Runtime.init(alloc, .{ .workers = 1, .stack_pool = true });
    defer rt.deinit();

    const Ch = zr.Channel(usize);
    const a = try Ch.create(alloc, 1);
    defer a.destroy();
    const b = try Ch.create(alloc, 1);
    defer b.destroy();

    const S = struct {
        fn work(ca: *Ch, cb: *Ch, count: usize) void {
            ca.trySend(0) catch {};
            var i: usize = 0;
            while (i < count) : (i += 1) {
                const r = zr.select.multi(usize, .{
                    .recv = &.{ ca, cb },
                }, .{});
                switch (r) {
                    .recv => |x| {
                        if (x.index == 0) {
                            cb.trySend(0) catch {};
                        } else {
                            ca.trySend(0) catch {};
                        }
                    },
                    else => {},
                }
            }
        }
    };
    _ = try rt.spawn(.{}, S.work, .{ a, b, n });

    const t0 = common.nowNs();
    try rt.run();
    const t1 = common.nowNs();
    common.printRate("select_uncontended", n, t1 - t0);
}

fn selectNonblock(alloc: std.mem.Allocator) !void {
    const n: usize = 200_000;
    var rt = try zr.Runtime.init(alloc, .{ .workers = 1, .stack_pool = true });
    defer rt.deinit();

    const Ch = zr.Channel(usize);
    const a = try Ch.create(alloc, 0);
    defer a.destroy();
    const b = try Ch.create(alloc, 0);
    defer b.destroy();

    const S = struct {
        fn work(ca: *Ch, cb: *Ch, count: usize) void {
            var i: usize = 0;
            while (i < count) : (i += 1) {
                const r = zr.select.multi(usize, .{
                    .recv = &.{ ca, cb },
                    .default = true,
                }, .{});
                std.mem.doNotOptimizeAway(r);
            }
        }
    };
    _ = try rt.spawn(.{}, S.work, .{ a, b, n });

    const t0 = common.nowNs();
    try rt.run();
    const t1 = common.nowNs();
    common.printRate("select_nonblock", n, t1 - t0);
}

fn selectSyncContended(alloc: std.mem.Allocator) !void {
    const n: usize = 30_000;
    var rt = try zr.Runtime.init(alloc, .{ .workers = 1, .stack_pool = true });
    defer rt.deinit();

    const Ch = zr.Channel(usize);
    const a = try Ch.create(alloc, 32);
    defer a.destroy();
    const b = try Ch.create(alloc, 32);
    defer b.destroy();
    const c = try Ch.create(alloc, 32);
    defer c.destroy();

    const S = struct {
        fn feeder(ch: *Ch, count: usize) void {
            var i: usize = 0;
            while (i < count) : (i += 1) {
                ch.send(i) catch return;
            }
        }
        fn receiver(ca: *Ch, cb: *Ch, cc: *Ch, count: usize) void {
            var got: usize = 0;
            while (got < count) {
                const r = zr.select.multi(usize, .{
                    .recv = &.{ ca, cb, cc },
                }, .{});
                switch (r) {
                    .recv => got += 1,
                    else => {},
                }
            }
        }
    };
    const per = n / 3;
    _ = try rt.spawn(.{}, S.feeder, .{ a, per });
    _ = try rt.spawn(.{}, S.feeder, .{ b, per });
    _ = try rt.spawn(.{}, S.feeder, .{ c, n - 2 * per });
    _ = try rt.spawn(.{}, S.receiver, .{ a, b, c, n });

    const t0 = common.nowNs();
    try rt.run();
    const t1 = common.nowNs();
    common.printRate("select_sync_contended", n, t1 - t0);
}
