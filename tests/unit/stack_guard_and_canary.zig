// SPDX-FileCopyrightText: 2026 Apanazar
//
// SPDX-License-Identifier: LGPL-3.0-or-later

const std = @import("std");
const zr = @import("zigroutines");

test "stack: canary high-water reports touched bytes" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const st = try zr.stack.allocWith(alloc, 0, .{ .paint_canary = true });
    defer zr.stack.free(alloc, st);

    const bytes = st.bytes();
    try std.testing.expectEqual(zr.stack.fiber_stack_size, bytes.len);
    bytes[bytes.len - 1] = 0x11;
    if (bytes.len > 64) bytes[bytes.len - 64] = 0x22;
    try std.testing.expect(st.highWaterUsed() >= 1);
    try std.testing.expect(st.highWaterRatio() > 0);
}

test "stack: opt-in canary cookie survives until smash" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var st = try zr.stack.allocWith(alloc, 0, .{ .protect = .canary });
    defer zr.stack.free(alloc, st);
    try std.testing.expect(st.has_cookie);
    try std.testing.expect(st.cookieIntact());
    st.usable[0] = 0x00;
    try std.testing.expect(!st.cookieIntact());
}

test "stack: canary goes through the pool" {
    var pool = zr.stack.Pool.initWith(std.testing.allocator, .{ .protect = .canary });
    defer pool.deinit();

    const a = try pool.acquire(0);
    const ptr_a = a.usable.ptr;
    try std.testing.expect(a.has_cookie);
    try std.testing.expect(a.cookieIntact());
    pool.release(a);

    const b = try pool.acquire(0);
    defer pool.release(b);
    try std.testing.expect(b.usable.ptr == ptr_a);
    try std.testing.expect(b.has_cookie);
    try std.testing.expect(b.cookieIntact());
}

test "stack: guard page allocation" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const st = try zr.stack.allocWith(alloc, 0, .{
        .guard_page = true,
        .paint_canary = true,
    });
    defer zr.stack.free(alloc, st);
    try std.testing.expect(st.has_guard);
    try std.testing.expectEqual(zr.stack.fiber_stack_size, st.usable.len);
}

test "stack: guard arena reuses committed slots" {
    var pool = zr.stack.Pool.initWith(std.testing.allocator, .{ .protect = .guard });
    defer pool.deinit();

    const a = try pool.acquire(0);
    try std.testing.expect(a.has_guard);
    try std.testing.expect(a.arena != null);
    try std.testing.expectEqual(zr.stack.fiber_stack_size, a.usable.len);
    const ptr_a = a.usable.ptr;
    pool.release(a);

    const b = try pool.acquire(0);
    defer pool.release(b);
    try std.testing.expect(b.usable.ptr == ptr_a);
    try std.testing.expect(b.has_guard);
}

test "stack: canary runtime spawn yield keeps cookie" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var rt = try zr.Runtime.init(alloc, .{
        .workers = 1,
        .stack_protect = .canary,
    });
    defer rt.deinit();

    _ = try rt.spawn(.{}, struct {
        fn work() void {
            zr.yield();
        }
    }.work, .{});
    try rt.run();
}
