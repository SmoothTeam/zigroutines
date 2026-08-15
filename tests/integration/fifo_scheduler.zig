// SPDX-FileCopyrightText: 2026 Apanazar
//
// SPDX-License-Identifier: LGPL-3.0-or-later

const std = @import("std");
const zr = @import("zigroutines");

test "runtime init single-thread" {
    if (comptime !zr.context.supported) return error.SkipZigTest;

    var rt = try zr.Runtime.init(std.testing.allocator, .{ .workers = 1 });
    defer rt.deinit();
    try std.testing.expectEqual(@as(u32, 1), rt.worker_count);
}

test "spawn yield two tasks" {
    if (comptime !zr.context.supported) return error.SkipZigTest;

    var rt = try zr.Runtime.init(std.testing.allocator, .{ .workers = 1 });
    defer rt.deinit();

    const State = struct {
        var hits: usize = 0;
    };
    State.hits = 0;

    const worker = struct {
        fn f(id: usize) void {
            _ = id;
            State.hits += 1;
            zr.yield();
            State.hits += 1;
        }
    }.f;

    _ = try rt.spawn(.{ .name = "a" }, worker, .{@as(usize, 1)});
    _ = try rt.spawn(.{ .name = "b" }, worker, .{@as(usize, 2)});
    try rt.run();
    try std.testing.expectEqual(@as(usize, 4), State.hits);
}

test "nested yield preserves local state" {
    if (comptime !zr.context.supported) return error.SkipZigTest;

    var rt = try zr.Runtime.init(std.testing.allocator, .{ .workers = 1 });
    defer rt.deinit();

    const S = struct {
        var ok: bool = false;
        fn work() void {
            var x: u32 = 1;
            zr.yield();
            x += 1;
            zr.yield();
            x += 1;
            ok = (x == 3);
        }
        fn companion() void {
            zr.yield();
            zr.yield();
        }
    };
    S.ok = false;

    _ = try rt.spawn(.{}, S.work, .{});
    _ = try rt.spawn(.{}, S.companion, .{});
    try rt.run();
    try std.testing.expect(S.ok);
}

test "many tasks with stack pool (batched)" {
    if (comptime !zr.context.supported) return error.SkipZigTest;

    var rt = try zr.Runtime.init(std.testing.allocator, .{ .workers = 1, .stack_pool = true });
    defer rt.deinit();

    const Counter = struct {
        var n: usize = 0;
        fn tick() void {
            n += 1;
        }
    };
    Counter.n = 0;

    var batch: usize = 0;
    while (batch < 10) : (batch += 1) {
        var i: usize = 0;
        while (i < 100) : (i += 1) {
            _ = try rt.spawn(.{ }, Counter.tick, .{});
        }
        try rt.run();
    }
    try std.testing.expectEqual(@as(usize, 1000), Counter.n);
}
