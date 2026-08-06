
const std = @import("std");
const zr = @import("zigroutines");

test "stack: canary high-water reports touched bytes" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const st = try zr.stack.allocWith(alloc, 16 * 1024, .{ .paint_canary = true });
    defer zr.stack.free(alloc, st);

    const bytes = st.bytes();
    bytes[bytes.len - 1] = 0x11;
    bytes[bytes.len - 128] = 0x22;
    try std.testing.expect(st.highWaterUsed() >= 1);
    try std.testing.expect(st.highWaterRatio() > 0);
}

test "stack: guard page allocation" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const st = try zr.stack.allocWith(alloc, 16 * 1024, .{
        .guard_page = true,
        .paint_canary = true,
    });
    defer zr.stack.free(alloc, st);
    try std.testing.expect(st.has_guard);
    try std.testing.expect(st.usable.len >= 16 * 1024);
}
