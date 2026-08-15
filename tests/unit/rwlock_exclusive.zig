// SPDX-FileCopyrightText: 2026 Apanazar
//
// SPDX-License-Identifier: LGPL-3.0-or-later

const std = @import("std");
const zr = @import("zigroutines");

test "rwlock exclusive writer preference" {
    if (!zr.context.supported) return error.SkipZigTest;

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var rt = try zr.Runtime.init(alloc, .{ .workers = 1, .stack_pool = false });
    defer rt.deinit();

    var rw = zr.RwLock.init(alloc);
    defer rw.deinit();

    const S = struct {
        var phase: u32 = 0;
        var saw_exclusive: bool = false;

        fn writer(l: *zr.RwLock) void {
            l.lockExclusive();
            phase = 1;
            zr.yield();
            saw_exclusive = true;
            phase = 2;
            l.unlockExclusive();
        }

        fn reader(l: *zr.RwLock) void {
            zr.yield();
            l.lockShared();
            if (phase < 2) phase = 99;
            l.unlockShared();
        }
    };

    _ = try rt.spawn(.{}, S.writer, .{&rw});
    _ = try rt.spawn(.{}, S.reader, .{&rw});
    try rt.run();
    try std.testing.expect(S.saw_exclusive);
    try std.testing.expectEqual(@as(u32, 2), S.phase);
}

test "rwlock many shared after exclusive" {
    if (!zr.context.supported) return error.SkipZigTest;

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var rt = try zr.Runtime.init(alloc, .{ .workers = 1, .stack_pool = false });
    defer rt.deinit();

    var rw = zr.RwLock.init(alloc);
    defer rw.deinit();

    const readers_n: usize = 8;
    const S = struct {
        var count: u32 = 0;

        fn holder(l: *zr.RwLock) void {
            l.lockExclusive();
            zr.yield();
            l.unlockExclusive();
        }

        fn reader(l: *zr.RwLock) void {
            l.lockShared();
            count += 1;
            l.unlockShared();
        }
    };

    _ = try rt.spawn(.{}, S.holder, .{&rw});
    var i: usize = 0;
    while (i < readers_n) : (i += 1) {
        _ = try rt.spawn(.{}, S.reader, .{&rw});
    }
    try rt.run();
    try std.testing.expectEqual(@as(u32, @intCast(readers_n)), S.count);
}

test "rwlock shared uncontended and concurrent readers" {
    if (!zr.context.supported) return error.SkipZigTest;

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var rt = try zr.Runtime.init(alloc, .{
        .workers = 4,
        .policy = .work_stealing,
        .stack_pool = true,
    });
    defer rt.deinit();

    var rw = zr.RwLock.init(alloc);
    defer rw.deinit();

    const per: u32 = 800;
    const tasks_n: u32 = 8;
    const S = struct {
        var counter: std.atomic.Value(u32) = .init(0);
        fn reader(l: *zr.RwLock, n: u32) void {
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                l.lockShared();
                _ = counter.fetchAdd(1, .monotonic);
                l.unlockShared();
            }
        }
    };
    S.counter.store(0, .monotonic);

    var i: u32 = 0;
    while (i < tasks_n) : (i += 1) {
        _ = try rt.spawn(.{}, S.reader, .{ &rw, per });
    }
    try rt.run();
    try std.testing.expectEqual(tasks_n * per, S.counter.load(.monotonic));
}
