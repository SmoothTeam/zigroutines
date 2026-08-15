// SPDX-FileCopyrightText: 2026 Apanazar
//
// SPDX-License-Identifier: LGPL-3.0-or-later

const std = @import("std");
const zr = @import("zigroutines");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var rt = try zr.Runtime.init(alloc, .{ .workers = 1, .stack_pool = true });
    defer rt.deinit();

    const S = struct {
        var total: u32 = 0;

        fn handle(msg: u32) void {
            total += msg;
            std.debug.print("actor got {d} (total={d})\n", .{ msg, total });
        }

        fn driver(r: *zr.Runtime) void {
            const A = zr.Actor(u32);
            const actor = A.spawn(r, .{ .mailbox_capacity = 8 }, handle) catch return;

            actor.send(10) catch {};
            actor.send(20) catch {};
            actor.send(12) catch {};

            actor.mailbox.close();
            actor.join();
            actor.destroy();
        }
    };

    _ = try rt.spawn(.{}, S.driver, .{&rt});
    try rt.run();
    std.debug.print("final total = {d}\n", .{S.total});
}
