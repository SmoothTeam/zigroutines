// SPDX-FileCopyrightText: 2026 Apanazar
//
// SPDX-License-Identifier: LGPL-3.0-or-later


const std = @import("std");
const zr = @import("zigroutines");

test "stack: fixed fiber size is 2 KiB" {
    try std.testing.expectEqual(@as(usize, 2 * 1024), zr.stack.fiber_stack_size);
    try std.testing.expectEqual(zr.stack.fiber_stack_size, zr.stack.default_stack_size);
}

test "stack: alloc free" {
    const s = try zr.stack.alloc(std.testing.allocator, 0);
    defer zr.stack.free(std.testing.allocator, s);
    try std.testing.expectEqual(zr.stack.fiber_stack_size, s.size());
}

test "stack: pool reuses buffers" {
    var pool = zr.stack.Pool.init(std.testing.allocator);
    defer pool.deinit();

    const a = try pool.acquire(0);
    const ptr_a = a.memory.ptr;
    pool.release(a);

    const b = try pool.acquire(0);
    defer pool.release(b);
    try std.testing.expect(b.memory.ptr == ptr_a);
    try std.testing.expect(b.from_pool);
    try std.testing.expectEqual(zr.stack.fiber_slot_size, b.memory.len);
    try std.testing.expectEqual(zr.stack.fiber_stack_size, b.size());
    try std.testing.expectEqual(@intFromPtr(b.memory.ptr), @intFromPtr(b.usable.ptr));
    try std.testing.expectEqual(zr.stack.tcb_prefix, b.memory.len - b.usable.len);
}

test "stack: paint canary still uses the pool" {
    var pool = zr.stack.Pool.initWith(std.testing.allocator, .{ .paint_canary = true });
    defer pool.deinit();

    const a = try pool.acquire(0);
    const ptr_a = a.memory.ptr;
    pool.release(a);

    const b = try pool.acquire(0);
    defer pool.release(b);
    try std.testing.expect(b.memory.ptr == ptr_a);
    try std.testing.expectEqual(zr.stack.fiber_stack_size, b.size());
}
