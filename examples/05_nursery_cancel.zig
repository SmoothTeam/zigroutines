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

    const Parent = struct {
        fn child(tok: *zr.CancelToken, id: u32) void {
            while (!tok.isCanceled()) {
                zr.yield();
            }
            std.debug.print("child {d} saw cancel\n", .{id});
        }

        fn run(rt_ptr: *zr.Runtime) void {
            var nursery = zr.Nursery.init(rt_ptr, .{
                .timeout_ns = 5 * std.time.ns_per_ms,
                .cancel_on_leave = true,
            });
            defer nursery.deinit();

            _ = nursery.spawn(.{}, child, .{ nursery.token(), @as(u32, 1) }) catch {};
            _ = nursery.spawn(.{}, child, .{ nursery.token(), @as(u32, 2) }) catch {};

            nursery.join() catch |err| {
                std.debug.print("nursery ended: {s}\n", .{@errorName(err)});
            };
        }
    };

    _ = try rt.spawn(.{}, Parent.run, .{&rt});
    try rt.run();
}
