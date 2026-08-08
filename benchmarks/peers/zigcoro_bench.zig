const std = @import("std");
const libcoro = @import("libcoro");
const common = @import("common");

pub fn main(init: std.process.Init) !void {
    common.init(init.io);
    const allocator = init.gpa;
    std.debug.print("peer-zigcoro  zig=0.16\n", .{});
    std.debug.print("--- fiber / spawn ---\n", .{});
    try ctxSwitch(allocator);
    try nCoros(allocator, 1_000);
    try nCoros(allocator, 10_000);
    std.debug.print("--- channel (executor Channel) ---\n", .{});
    try chanPipeline(allocator, 256);
    try chanPipeline(allocator, 1);
    std.debug.print("---\ndone\n", .{});
    std.debug.print(
        \\skipped: n_tasks_50000 (slow)
        \\n/a: yield_pingpong/single/ws, leaf_spawn, spawn_*, nursery,
        \\  skynet, priority, select_*, mutex_*, sem_*, rwlock_*, timer_*, actor, I/O, try/mpmc channel
        \\
    , .{});
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
        try std.fmt.bufPrint(&name_buf, "chan_capacity_{d}", .{capacity});
    common.printRate(name, n, t1 - t0);
}
