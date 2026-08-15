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
        .workers = 4,
        .policy = .work_stealing,
        .stack_pool = true,
        .metrics = true,
    });
    defer rt.deinit();

    const Job = struct {
        fn fib(n: u32) u32 {
            if (n < 2) return n;
            zr.yield();
            return fib(n - 1) +% fib(n - 2);
        }

        fn runner(rt_ptr: *zr.Runtime) void {
            const h = rt_ptr.spawnResult(.{}, fib, .{@as(u32, 12)}) catch return;
            const v = h.join();
            std.debug.print("fib(12) = {d}\n", .{v});
        }
    };

    var i: usize = 0;
    while (i < 4) : (i += 1) {
        _ = try rt.spawn(.{}, Job.runner, .{&rt});
    }
    try rt.run();

    const m = rt.metricsSnapshot();
    std.debug.print("metrics: spawns={d} finishes={d} yields={d} steals={d}\n", .{
        m.spawns,
        m.finishes,
        m.yields,
        m.steals,
    });
}
