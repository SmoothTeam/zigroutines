
const std = @import("std");
const zr = @import("zigroutines");

test "metrics disabled is zero" {
    if (comptime !zr.context.supported) return error.SkipZigTest;

    var rt = try zr.Runtime.init(std.testing.allocator, .{ .workers = 1, .metrics = false });
    defer rt.deinit();

    const tick = struct {
        fn f() void {
            zr.yield();
        }
    }.f;
    _ = try rt.spawn(.{}, tick, .{});
    try rt.run();

    const s = rt.metricsSnapshot();
    try std.testing.expectEqual(@as(u64, 0), s.spawns);
    try std.testing.expectEqual(@as(u64, 0), s.yields);
}

test "metrics counts spawns yields finishes" {
    if (comptime !zr.context.supported) return error.SkipZigTest;

    var rt = try zr.Runtime.init(std.testing.allocator, .{ .workers = 1, .metrics = true });
    defer rt.deinit();

    const tick = struct {
        fn f() void {
            zr.yield();
            zr.yield();
        }
    }.f;
    _ = try rt.spawn(.{}, tick, .{});
    _ = try rt.spawn(.{}, tick, .{});
    try rt.run();

    const s = rt.metricsSnapshot();
    try std.testing.expectEqual(@as(u64, 2), s.spawns);
    try std.testing.expectEqual(@as(u64, 2), s.finishes);
    try std.testing.expect(s.yields >= 4);
}

test "version is 1.0.0" {
    try std.testing.expectEqual(@as(u32, 1), zr.version.major);
    try std.testing.expectEqual(@as(u32, 0), zr.version.minor);
    try std.testing.expectEqual(@as(u32, 0), zr.version.patch);
}
