const std = @import("std");
const zr = @import("zigroutines");

test "actor: destroy cleans mailbox and token" {
    if (!zr.context.supported) return error.SkipZigTest;

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var rt = try zr.Runtime.init(alloc, .{ .workers = 1, .stack_pool = false });
    defer rt.deinit();

    const S = struct {
        var sum: u32 = 0;
        fn handle(msg: u32) void {
            sum += msg;
        }
        fn driver(r: *zr.Runtime) void {
            const A = zr.Actor(u32);
            const actor = A.spawn(r, .{ .mailbox_capacity = 4 }, handle) catch return;
            actor.send(1) catch {};
            actor.send(2) catch {};
            actor.mailbox.close();
            actor.join();
            actor.destroy();
        }
    };

    _ = try rt.spawn(.{}, S.driver, .{&rt});
    try rt.run();
    try std.testing.expectEqual(@as(u32, 3), S.sum);
}

test "actor: cancel stops handler loop" {
    if (!zr.context.supported) return error.SkipZigTest;

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var rt = try zr.Runtime.init(alloc, .{ .workers = 1, .stack_pool = false });
    defer rt.deinit();

    const S = struct {
        var stopped: bool = false;
        fn handle(msg: u32) void {
            _ = msg;
        }
        fn onStop(a: *zr.Actor(u32)) void {
            _ = a;
            stopped = true;
        }
        fn driver(r: *zr.Runtime) void {
            const A = zr.Actor(u32);
            const actor = A.spawn(r, .{ .mailbox_capacity = 1, .on_stop = onStop }, handle) catch return;
            actor.cancel();
            actor.join();
            actor.destroy();
        }
    };

    _ = try rt.spawn(.{}, S.driver, .{&rt});
    try rt.run();
    try std.testing.expect(S.stopped);
}
