// SPDX-FileCopyrightText: 2026 Apanazar
//
// SPDX-License-Identifier: LGPL-3.0-or-later

const std = @import("std");
const zr = @import("zigroutines");

test "runtime init multi-thread" {
    if (comptime !zr.context.supported) return error.SkipZigTest;

    var rt = try zr.Runtime.init(std.testing.allocator, .{ .workers = 4 });
    defer rt.deinit();
    try std.testing.expectEqual(@as(u32, 4), rt.worker_count);
}

test "workers=0 uses at least one CPU" {
    if (comptime !zr.context.supported) return error.SkipZigTest;

    var rt = try zr.Runtime.init(std.testing.allocator, .{ .workers = 0 });
    defer rt.deinit();
    try std.testing.expect(rt.worker_count >= 1);
}

test "parallel spawn counters" {
    if (comptime !zr.context.supported) return error.SkipZigTest;

    var rt = try zr.Runtime.init(std.testing.allocator, .{ .workers = 4, .stack_pool = true });
    defer rt.deinit();

    const Counter = struct {
        var n: std.atomic.Value(usize) = .init(0);
        fn tick() void {
            _ = n.fetchAdd(1, .monotonic);
        }
    };
    Counter.n.store(0, .monotonic);

    const N: usize = 200;
    var i: usize = 0;
    while (i < N) : (i += 1) {
        _ = try rt.spawn(.{}, Counter.tick, .{});
    }
    try rt.run();
    try std.testing.expectEqual(N, Counter.n.load(.monotonic));
}

test "yield across workers preserves task locals" {
    if (comptime !zr.context.supported) return error.SkipZigTest;

    var rt = try zr.Runtime.init(std.testing.allocator, .{ .workers = 4 });
    defer rt.deinit();

    const S = struct {
        var ok_count: std.atomic.Value(usize) = .init(0);
        fn work() void {
            var x: u32 = 10;
            zr.yield();
            x += 5;
            zr.yield();
            if (x == 15) {
                _ = ok_count.fetchAdd(1, .monotonic);
            }
        }
    };
    S.ok_count.store(0, .monotonic);

    const N: usize = 50;
    var i: usize = 0;
    while (i < N) : (i += 1) {
        _ = try rt.spawn(.{}, S.work, .{});
    }
    try rt.run();
    try std.testing.expectEqual(N, S.ok_count.load(.monotonic));
}

test "empty run is fine" {
    if (comptime !zr.context.supported) return error.SkipZigTest;

    var rt = try zr.Runtime.init(std.testing.allocator, .{ .workers = 2 });
    defer rt.deinit();
    try rt.run();
}
