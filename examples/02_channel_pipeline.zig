// SPDX-FileCopyrightText: 2026 Apanazar
//
// SPDX-License-Identifier: LGPL-3.0-or-later

const std = @import("std");
const zr = @import("zigroutines");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var rt = try zr.Runtime.init(alloc, .{
        .workers = 1,
        .stack_pool = true,
    });
    defer rt.deinit();

    const Ch = zr.Channel(usize);
    const ch = try Ch.create(alloc, 16);
    defer ch.destroy();

    const N: usize = 20;

    const S = struct {
        fn producer(c: *Ch, n: usize) void {
            var i: usize = 0;
            while (i < n) : (i += 1) {
                c.send(i) catch return;
            }
            c.close();
        }

        fn consumer(c: *Ch) void {
            var sum: usize = 0;
            while (true) {
                const v = c.recv() catch break;
                sum += v;
            }
            std.debug.print("sum 0..{d} = {d}\n", .{ N, sum });
        }
    };

    _ = try rt.spawn(.{}, S.producer, .{ ch, N });
    _ = try rt.spawn(.{}, S.consumer, .{ch});
    try rt.run();
}
