// SPDX-FileCopyrightText: 2026 Apanazar
//
// SPDX-License-Identifier: LGPL-3.0-or-later

const std = @import("std");
const zr = @import("zigroutines");
const c = zr.c_api;

test "c abi: version matches package" {
    try std.testing.expectEqual(@as(c_uint, 1), c.zr_version_major());
    try std.testing.expectEqual(@as(c_uint, 0), c.zr_version_minor());
    try std.testing.expectEqual(@as(c_uint, 0), c.zr_version_patch());
}

test "c abi: create destroy empty run" {
    if (!zr.context.supported) return error.SkipZigTest;
    const rt = c.zr_runtime_create(1) orelse return error.TestUnexpectedResult;
    defer c.zr_runtime_destroy(rt);
    try std.testing.expectEqual(@as(c_int, 0), c.zr_runtime_run(rt));
}

test "c abi: spawn yield and run" {
    if (!zr.context.supported) return error.SkipZigTest;

    const S = struct {
        var hits: u32 = 0;
        fn task(_: ?*anyopaque) callconv(.c) void {
            hits += 1;
            c.zr_yield();
            hits += 1;
        }
    };
    S.hits = 0;

    const rt = c.zr_runtime_create(1) orelse return error.TestUnexpectedResult;
    defer c.zr_runtime_destroy(rt);
    try std.testing.expectEqual(@as(c_int, 0), c.zr_spawn(rt, S.task, null));
    try std.testing.expectEqual(@as(c_int, 0), c.zr_runtime_run(rt));
    try std.testing.expectEqual(@as(u32, 2), S.hits);
}

test "c abi: channel send recv between tasks" {
    if (!zr.context.supported) return error.SkipZigTest;

    const ch = c.zr_channel_create(4) orelse return error.TestUnexpectedResult;
    defer c.zr_channel_destroy(ch);

    const S = struct {
        var got: usize = 0;
        fn producer(ud: ?*anyopaque) callconv(.c) void {
            const chan: *c.zr_channel = @ptrCast(ud.?);
            _ = c.zr_channel_send(chan, 41);
            _ = c.zr_channel_send(chan, 1);
            c.zr_channel_close(chan);
        }
        fn consumer(ud: ?*anyopaque) callconv(.c) void {
            const chan: *c.zr_channel = @ptrCast(ud.?);
            var a: usize = 0;
            var b: usize = 0;
            if (c.zr_channel_recv(chan, &a) != 0) return;
            if (c.zr_channel_recv(chan, &b) != 0) return;
            got = a + b;
        }
    };
    S.got = 0;

    const rt = c.zr_runtime_create(1) orelse return error.TestUnexpectedResult;
    defer c.zr_runtime_destroy(rt);
    try std.testing.expectEqual(@as(c_int, 0), c.zr_spawn(rt, S.producer, ch));
    try std.testing.expectEqual(@as(c_int, 0), c.zr_spawn(rt, S.consumer, ch));
    try std.testing.expectEqual(@as(c_int, 0), c.zr_runtime_run(rt));
    try std.testing.expectEqual(@as(usize, 42), S.got);
}

test "c abi: try send recv and sleep" {
    if (!zr.context.supported) return error.SkipZigTest;

    const ch = c.zr_channel_create(1) orelse return error.TestUnexpectedResult;
    defer c.zr_channel_destroy(ch);

    const S = struct {
        var ok: bool = false;
        fn work(ud: ?*anyopaque) callconv(.c) void {
            const chan: *c.zr_channel = @ptrCast(ud.?);
            if (c.zr_channel_try_send(chan, 7) != 0) return;
            var v: usize = 0;
            if (c.zr_channel_try_recv(chan, &v) != 0) return;
            c.zr_sleep_ns(1000);
            ok = v == 7;
        }
    };
    S.ok = false;

    const rt = c.zr_runtime_create(1) orelse return error.TestUnexpectedResult;
    defer c.zr_runtime_destroy(rt);
    try std.testing.expectEqual(@as(c_int, 0), c.zr_spawn(rt, S.work, ch));
    try std.testing.expectEqual(@as(c_int, 0), c.zr_runtime_run(rt));
    try std.testing.expect(S.ok);
}

test "c abi: null handles are safe" {
    c.zr_runtime_destroy(null);
    c.zr_channel_destroy(null);
    c.zr_channel_close(null);
    try std.testing.expectEqual(@as(c_int, -1), c.zr_runtime_run(null));
    try std.testing.expectEqual(@as(c_int, -1), c.zr_spawn(null, null, null));
    try std.testing.expectEqual(@as(c_int, -1), c.zr_channel_send(null, 0));
    try std.testing.expectEqual(@as(c_int, -1), c.zr_channel_recv(null, null));
    try std.testing.expectEqual(@as(c_int, -1), c.zr_channel_try_recv(null, null));
}

test "c abi: try send wouldblock on full channel" {
    if (!zr.context.supported) return error.SkipZigTest;
    const ch = c.zr_channel_create(1) orelse return error.TestUnexpectedResult;
    defer c.zr_channel_destroy(ch);
    try std.testing.expectEqual(@as(c_int, 0), c.zr_channel_try_send(ch, 1));
    try std.testing.expectEqual(@as(c_int, 1), c.zr_channel_try_send(ch, 2));
    var v: usize = 0;
    try std.testing.expectEqual(@as(c_int, 0), c.zr_channel_try_recv(ch, &v));
    try std.testing.expectEqual(@as(usize, 1), v);
    try std.testing.expectEqual(@as(c_int, 1), c.zr_channel_try_recv(ch, &v));
}

test "c abi: recv after close returns error" {
    if (!zr.context.supported) return error.SkipZigTest;

    const ch = c.zr_channel_create(1) orelse return error.TestUnexpectedResult;
    defer c.zr_channel_destroy(ch);
    c.zr_channel_close(ch);

    const S = struct {
        var send_rc: c_int = 0;
        var recv_rc: c_int = 0;
        fn work(ud: ?*anyopaque) callconv(.c) void {
            const chan: *c.zr_channel = @ptrCast(ud.?);
            var v: usize = 99;
            send_rc = c.zr_channel_send(chan, 1);
            recv_rc = c.zr_channel_recv(chan, &v);
        }
    };
    S.send_rc = 0;
    S.recv_rc = 0;

    const rt = c.zr_runtime_create(1) orelse return error.TestUnexpectedResult;
    defer c.zr_runtime_destroy(rt);
    try std.testing.expectEqual(@as(c_int, 0), c.zr_spawn(rt, S.work, ch));
    try std.testing.expectEqual(@as(c_int, 0), c.zr_runtime_run(rt));
    try std.testing.expectEqual(@as(c_int, -1), S.send_rc);
    try std.testing.expectEqual(@as(c_int, -1), S.recv_rc);
}
