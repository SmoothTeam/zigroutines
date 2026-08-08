
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
