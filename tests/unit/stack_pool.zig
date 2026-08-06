
const std = @import("std");
const zr = @import("zigroutines");

test "stack: default size" {
    try std.testing.expectEqual(@as(usize, 64 * 1024), zr.stack.default_stack_size);
}

test "stack: alloc free" {
    const s = try zr.stack.alloc(std.testing.allocator, 4096);
    defer zr.stack.free(std.testing.allocator, s);
    try std.testing.expect(s.size() >= 4096);
}

test "stack: pool reuses buffers" {
    var pool = zr.stack.Pool.init(std.testing.allocator);
    defer pool.deinit();

    const a = try pool.acquire(64 * 1024);
    const ptr_a = a.memory.ptr;
    pool.release(a);

    const b = try pool.acquire(64 * 1024);
    defer pool.release(b);
    try std.testing.expect(b.memory.ptr == ptr_a);
    try std.testing.expect(b.from_pool);
}
