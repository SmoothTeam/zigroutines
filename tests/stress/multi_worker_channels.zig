// SPDX-FileCopyrightText: 2026 Apanazar
//
// SPDX-License-Identifier: LGPL-3.0-or-later

const std = @import("std");
const zr = @import("zigroutines");

test "stress work-stealing channel pipeline" {
    if (comptime !zr.context.supported) return error.SkipZigTest;

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var rt = try zr.Runtime.init(alloc, .{
        .workers = 4,
        .policy = .work_stealing,
        .stack_pool = true,
        .metrics = true,
    });
    defer rt.deinit();

    const Ch = zr.Channel(u32);
    const ch = try Ch.create(alloc, 128);
    defer ch.destroy();

    const producers: u32 = 8;
    const per_prod: u32 = 500;
    const total: u32 = producers * per_prod;

    const S = struct {
        fn prod(c: *Ch, id: u32, n: u32) void {
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                c.send(id * 10000 + i) catch return;
            }
        }
        fn cons(c: *Ch, expect: u32, got: *std.atomic.Value(u32)) void {
            var local: u32 = 0;
            while (local < expect) {
                _ = c.recv() catch break;
                local += 1;
                _ = got.fetchAdd(1, .monotonic);
            }
        }
    };

    var got: std.atomic.Value(u32) = .init(0);
    var p: u32 = 0;
    while (p < producers) : (p += 1) {
        _ = try rt.spawn(.{}, S.prod, .{ ch, p, per_prod });
    }
    _ = try rt.spawn(.{}, S.cons, .{ ch, total, &got });

    const Closer = struct {
        fn run(c: *Ch, g: *std.atomic.Value(u32), exp: u32) void {
            while (g.load(.acquire) < exp) zr.yield();
            c.close();
        }
    };
    _ = try rt.spawn(.{}, Closer.run, .{ ch, &got, total });

    try rt.run();
    try std.testing.expectEqual(total, got.load(.acquire));
    const snap = rt.metricsSnapshot();
    try std.testing.expect(snap.spawns >= producers + 2);
}

test "stress spawnResult and join" {
    if (comptime !zr.context.supported) return error.SkipZigTest;

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var rt = try zr.Runtime.init(alloc, .{ .workers = 1, .stack_pool = true });
    defer rt.deinit();

    const S = struct {
        fn add(a: u32, b: u32) u32 {
            zr.yield();
            return a + b;
        }
        fn runner(rt_ptr: *zr.Runtime, out: *u32) void {
            const h = rt_ptr.spawnResult(.{}, add, .{ 20, 22 }) catch return;
            out.* = h.join();
        }
    };

    var out: u32 = 0;
    _ = try rt.spawn(.{}, S.runner, .{ &rt, &out });
    try rt.run();
    try std.testing.expectEqual(@as(u32, 42), out);
}

test "stress priority order" {
    if (comptime !zr.context.supported) return error.SkipZigTest;

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var rt = try zr.Runtime.init(alloc, .{
        .workers = 1,
        .policy = .priority,
        .stack_pool = true,
    });
    defer rt.deinit();

    var order: std.ArrayListUnmanaged(u8) = .empty;
    defer order.deinit(alloc);

    const S = struct {
        fn push(o: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, id: u8) void {
            o.append(a, id) catch {};
        }
    };

    _ = try rt.spawn(.{ .priority = 50 }, S.push, .{ &order, alloc, 50 });
    _ = try rt.spawn(.{ .priority = 1 }, S.push, .{ &order, alloc, 1 });
    _ = try rt.spawn(.{ .priority = 10 }, S.push, .{ &order, alloc, 10 });

    try rt.run();
    try std.testing.expectEqual(@as(usize, 3), order.items.len);
    try std.testing.expectEqual(@as(u8, 1), order.items[0]);
    try std.testing.expectEqual(@as(u8, 10), order.items[1]);
    try std.testing.expectEqual(@as(u8, 50), order.items[2]);
}
