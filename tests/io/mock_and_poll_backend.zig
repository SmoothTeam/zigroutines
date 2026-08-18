// SPDX-FileCopyrightText: 2026 Apanazar
//
// SPDX-License-Identifier: LGPL-3.0-or-later

const std = @import("std");
const zr = @import("zigroutines");
const builtin = @import("builtin");

test "runtime poll reactor creates backend" {
    if (comptime !zr.context.supported) return error.SkipZigTest;

    var rt = try zr.Runtime.init(std.testing.allocator, .{ .workers = 1, .io = .poll });
    defer rt.deinit();
    try std.testing.expect(rt.ioBackend() != null);
}

test "mock wait when already ready" {
    if (comptime !zr.context.supported) return error.SkipZigTest;

    var rt = try zr.Runtime.init(std.testing.allocator, .{ .workers = 1 });
    defer rt.deinit();

    var mock = try zr.MockBackend.create(std.testing.allocator);
    defer mock.destroy();
    rt.setIoBackend(mock.asBackend());

    const handle: zr.io.Handle = 7;
    const S = struct {
        var ok: bool = false;
        fn work(m: *zr.MockBackend, h: zr.io.Handle) void {
            m.setReady(h, .read) catch unreachable;
            m.asBackend().wait(h, .read) catch unreachable;
            ok = true;
        }
    };
    S.ok = false;

    _ = try rt.spawn(.{}, S.work, .{ mock, handle });
    try rt.run();
    try std.testing.expect(S.ok);
}

test "mock park then wake via scheduler poll" {
    if (comptime !zr.context.supported) return error.SkipZigTest;

    var rt = try zr.Runtime.init(std.testing.allocator, .{ .workers = 1 });
    defer rt.deinit();

    var mock = try zr.MockBackend.create(std.testing.allocator);
    defer mock.destroy();
    rt.setIoBackend(mock.asBackend());

    const handle: zr.io.Handle = 99;
    const S = struct {
        var ok: bool = false;
        fn blocked(m: *zr.MockBackend, h: zr.io.Handle) void {
            m.asBackend().wait(h, .read) catch unreachable;
            ok = true;
        }
        fn waker(m: *zr.MockBackend, h: zr.io.Handle) void {
            zr.yield();
            m.setReady(h, .read) catch unreachable;
        }
    };
    S.ok = false;

    _ = try rt.spawn(.{}, S.blocked, .{ mock, handle });
    _ = try rt.spawn(.{}, S.waker, .{ mock, handle });
    try rt.run();
    try std.testing.expect(S.ok);
}

test "tcp helpers typecheck and reactor binds" {
    if (comptime !zr.context.supported) return error.SkipZigTest;
    if (builtin.os.tag != .windows and builtin.os.tag != .linux) return error.SkipZigTest;

    var rt = try zr.Runtime.init(std.testing.allocator, .{ .workers = 1, .io = .poll });
    defer rt.deinit();
    try std.testing.expect(rt.ioBackend() != null);
    try std.testing.expect(@TypeOf(zr.TcpListener.bind) != void);
    try std.testing.expect(@TypeOf(zr.TcpStream.connect) != void);
}
