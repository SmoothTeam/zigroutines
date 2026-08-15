// SPDX-FileCopyrightText: 2026 Apanazar
//
// SPDX-License-Identifier: LGPL-3.0-or-later


const std = @import("std");
const zr = @import("zigroutines");

test "preemption: checkpoint runs without panic when enabled" {
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
            while (i < 8) : (i += 1) {
                ticks += 1;
                zr.checkpoint();
            }
        }
    };
    S.ticks = 0;
    _ = try rt.spawn(.{}, S.work, .{});
    try rt.run();
    try std.testing.expectEqual(@as(u32, 8), S.ticks);
}

test "preemption: checkpoint is no-op when disabled" {
    if (!zr.context.supported) return error.SkipZigTest;

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var rt = try zr.Runtime.init(alloc, .{
        .workers = 1,
        .stack_pool = false,
        .preempt = .{ .enabled = false },
    });
    defer rt.deinit();

    const S = struct {
        var done: bool = false;
        fn work() void {
            zr.checkpoint();
            done = true;
        }
    };
    S.done = false;
    _ = try rt.spawn(.{}, S.work, .{});
    try rt.run();
    try std.testing.expect(S.done);
}
