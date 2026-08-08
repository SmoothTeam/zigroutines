const std = @import("std");
const zr = @import("zigroutines");
const common = @import("common.zig");

pub fn runAll(alloc: std.mem.Allocator) !void {
    try sleepBatch(alloc);
    try manyTimers(alloc);
}

fn sleepBatch(alloc: std.mem.Allocator) !void {
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

    const t0 = common.nowNs();
    try rt.run();
    const t1 = common.nowNs();
    common.printRate("timer_sleep_batch", n, t1 - t0);
}

fn manyTimers(alloc: std.mem.Allocator) !void {
    const n: usize = 100_000;
    var rt = try zr.Runtime.init(alloc, .{
        .workers = 1,
        .stack_pool = true,
    });
    defer rt.deinit();

    const S = struct {
        fn sleeper(delay_ns: u64) void {
            zr.sleep(delay_ns);
        }
    };

    const t_init0 = common.nowNs();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const delay: u64 = 1 + @as(u64, @intCast(i % 1000));
        _ = try rt.spawn(.{}, S.sleeper, .{delay});
    }
    const t_init1 = common.nowNs();

    const t_run0 = common.nowNs();
    try rt.run();
    const t_run1 = common.nowNs();

    common.printRate("timer_many_100k_spawn", n, t_init1 - t_init0);
    common.printRate("timer_many_100k_dispatch", n, t_run1 - t_run0);
    common.printWall("timer_many_100k_total", t_run1 - t_init0);
}
