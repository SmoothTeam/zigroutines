// SPDX-FileCopyrightText: 2026 Apanazar
//
// SPDX-License-Identifier: LGPL-3.0-or-later

const std = @import("std");
const zr = @import("zigroutines");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var rt = try zr.Runtime.init(alloc, .{ .workers = 1 });
    defer rt.deinit();

    const Ch = zr.Channel(u32);
    const ch = try Ch.create(alloc, 0);
    defer ch.destroy();

    const S = struct {
        fn slow(c: *Ch) void {
            zr.sleep(5 * std.time.ns_per_ms);
            c.send(7) catch {};
        }

        fn waiter(c: *Ch, timers: *zr.TimerQueue) void {
            const r = zr.select.recv(u32, c, .{
                .timeout_ns = 1 * std.time.ns_per_ms,
                .timers = timers,
            });
            switch (r) {
                .value => |v| std.debug.print("got value {d}\n", .{v}),
                .timeout => std.debug.print("timed out (expected)\n", .{}),
                .closed => std.debug.print("channel closed\n", .{}),
                .canceled => std.debug.print("canceled\n", .{}),
            }
        }
    };

    _ = try rt.spawn(.{}, S.slow, .{ch});
    _ = try rt.spawn(.{}, S.waiter, .{ ch, &rt.timers });
    try rt.run();
}
