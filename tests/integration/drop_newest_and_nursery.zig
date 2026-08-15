// SPDX-FileCopyrightText: 2026 Apanazar
//
// SPDX-License-Identifier: LGPL-3.0-or-later

const std = @import("std");
const zr = @import("zigroutines");

test "channel drop_newest keeps older messages" {
    if (!zr.context.supported) return error.SkipZigTest;

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var rt = try zr.Runtime.init(alloc, .{ .workers = 1, .stack_pool = false });
    defer rt.deinit();

    const Ch = zr.Channel(u32);
    const S = struct {
        var first: u32 = 0;
        var drops: u64 = 0;
        fn work(ch: *Ch) void {
            ch.send(10) catch unreachable;
            ch.send(20) catch unreachable;
            drops = ch.droppedCount();
            first = ch.recv() catch 0;
        }
    };

    const ch = try Ch.createWith(alloc, 1, .{ .full_policy = .drop_newest });
    defer ch.destroy();
    _ = try rt.spawn(.{}, S.work, .{ch});
    try rt.run();
    try std.testing.expect(S.drops >= 1);
    try std.testing.expectEqual(@as(u32, 10), S.first);
}

test "nursery cancel_on_first_done" {
    if (!zr.context.supported) return error.SkipZigTest;

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var rt = try zr.Runtime.init(alloc, .{ .workers = 1, .stack_pool = false });
    defer rt.deinit();

    const S = struct {
        var long_saw_cancel: bool = false;

        fn quick() void {}

        fn long_running(tok: *zr.CancelToken) void {
            while (!tok.isCanceled()) {
                zr.yield();
            }
            long_saw_cancel = true;
        }

        fn parent(r: *zr.Runtime) void {
            var n = zr.Nursery.init(r, .{
                .cancel_on_first_done = true,
                .cancel_on_leave = true,
            });
            defer n.deinit();
            _ = n.spawn(.{}, long_running, .{n.token()}) catch {};
            _ = n.spawn(.{}, quick, .{}) catch {};
            _ = n.join() catch {};
        }
    };

    _ = try rt.spawn(.{}, S.parent, .{&rt});
    try rt.run();
    try std.testing.expect(S.long_saw_cancel);
}

test "spawnResult error union" {
    if (!zr.context.supported) return error.SkipZigTest;

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var rt = try zr.Runtime.init(alloc, .{ .workers = 1, .stack_pool = false });
    defer rt.deinit();

    const S = struct {
        var ok: bool = false;
        fn failing() anyerror!u32 {
            return error.TestFail;
        }
        fn runner(r: *zr.Runtime) void {
            const h = r.spawnResult(.{}, failing, .{}) catch return;
            const res = h.joinError();
            ok = (res == error.TestFail);
        }
    };

    _ = try rt.spawn(.{}, S.runner, .{&rt});
    try rt.run();
    try std.testing.expect(S.ok);
}

test "select multi fairness default non-blocking" {
    if (!zr.context.supported) return error.SkipZigTest;

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var rt = try zr.Runtime.init(alloc, .{ .workers = 1, .stack_pool = false });
    defer rt.deinit();

    const Ch = zr.Channel(u32);
    const S = struct {
        var hit: bool = false;
        fn work(a: *Ch, b: *Ch) void {
            const r = zr.select.multi(u32, .{
                .recv = &.{ a, b },
                .default = true,
            }, .{});
            hit = (r == .default);
        }
    };

    const a = try Ch.create(alloc, 1);
    defer a.destroy();
    const b = try Ch.create(alloc, 1);
    defer b.destroy();
    _ = try rt.spawn(.{}, S.work, .{ a, b });
    try rt.run();
    try std.testing.expect(S.hit);
}
