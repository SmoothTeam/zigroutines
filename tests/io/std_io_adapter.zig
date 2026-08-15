// SPDX-FileCopyrightText: 2026 Apanazar
//
// SPDX-License-Identifier: LGPL-3.0-or-later

const std = @import("std");
const zr = @import("zigroutines");

test "IoAdapter constructs Io value" {
    if (comptime !zr.context.supported) return error.SkipZigTest;

    var rt = try zr.Runtime.init(std.testing.allocator, .{ .workers = 1 });
    defer rt.deinit();

    var adapter = try zr.IoAdapter.init(std.testing.allocator, &rt, .{});
    defer adapter.deinit();

    const io = adapter.io();
    try std.testing.expect(@intFromPtr(io.vtable) != 0);
    try std.testing.expect(io.userdata != null);
}

test "io.async + await on zigroutines tasks" {
    if (comptime !zr.context.supported) return error.SkipZigTest;

    var rt = try zr.Runtime.init(std.testing.allocator, .{ .workers = 1 });
    defer rt.deinit();

    var adapter = try zr.IoAdapter.init(std.testing.allocator, &rt, .{});
    defer adapter.deinit();
    const io = adapter.io();

    const S = struct {
        var sum: i32 = 0;
        fn add(a: i32, b: i32) i32 {
            return a + b;
        }
        fn driver(io_val: std.Io) void {
            var fut = std.Io.async(io_val, add, .{ @as(i32, 20), @as(i32, 22) });
            const result = fut.await(io_val);
            sum = result;
        }
    };
    S.sum = 0;

    _ = try rt.spawn(.{}, S.driver, .{io});
    try rt.run();
    try std.testing.expectEqual(@as(i32, 42), S.sum);
}

test "io.async nested with yield" {
    if (comptime !zr.context.supported) return error.SkipZigTest;

    var rt = try zr.Runtime.init(std.testing.allocator, .{ .workers = 1 });
    defer rt.deinit();

    var adapter = try zr.IoAdapter.init(std.testing.allocator, &rt, .{});
    defer adapter.deinit();
    const io = adapter.io();

    const S = struct {
        var ok: bool = false;
        fn slow() i32 {
            zr.yield();
            return 7;
        }
        fn driver(io_val: std.Io) void {
            var fut = std.Io.async(io_val, slow, .{});
            const v = fut.await(io_val);
            ok = (v == 7);
        }
    };
    S.ok = false;

    _ = try rt.spawn(.{}, S.driver, .{io});
    try rt.run();
    try std.testing.expect(S.ok);
}

test "io.sleep via adapter inside task" {
    if (comptime !zr.context.supported) return error.SkipZigTest;

    var rt = try zr.Runtime.init(std.testing.allocator, .{ .workers = 1 });
    defer rt.deinit();

    var adapter = try zr.IoAdapter.init(std.testing.allocator, &rt, .{});
    defer adapter.deinit();
    const io = adapter.io();

    const S = struct {
        var ok: bool = false;
        fn work(io_val: std.Io) void {
            const dur: std.Io.Timeout = .{
                .duration = .{
                    .raw = .fromNanoseconds(2 * std.time.ns_per_ms),
                    .clock = .boot,
                },
            };
            dur.sleep(io_val) catch {};
            ok = true;
        }
    };
    S.ok = false;

    _ = try rt.spawn(.{}, S.work, .{io});
    try rt.run();
    try std.testing.expect(S.ok);
}

test "io.now works through adapter" {
    if (comptime !zr.context.supported) return error.SkipZigTest;

    var rt = try zr.Runtime.init(std.testing.allocator, .{ .workers = 1 });
    defer rt.deinit();

    var adapter = try zr.IoAdapter.init(std.testing.allocator, &rt, .{});
    defer adapter.deinit();
    const io = adapter.io();

    const t0 = std.Io.Clock.boot.now(io);
    const t1 = std.Io.Clock.boot.now(io);
    try std.testing.expect(t1.nanoseconds >= t0.nanoseconds);
}
