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

    var mtx = zr.Mutex.init(alloc);
    defer mtx.deinit();
    var sem = zr.Semaphore.init(alloc, 1);
    defer sem.deinit();

    const Ch = zr.Channel(u32);
    const ch = try Ch.createWith(alloc, 2, .{ .full_policy = .drop_oldest });
    defer ch.destroy();

    const S = struct {
        var critical: u32 = 0;

        fn worker(m: *zr.Mutex, s: *zr.Semaphore, c: *Ch, id: u32) void {
            s.acquire();
            m.lock();
            critical += 1;
            std.debug.print("worker {d} in critical section (count={d})\n", .{ id, critical });
            m.unlock();
            s.release();

            c.send(id) catch {};
            c.send(id * 10) catch {};
            c.send(id * 100) catch {};
        }

        fn drain(c: *Ch) void {
            zr.yield();
            while (true) {
                const v = c.tryRecv() catch break;
                std.debug.print("drained {d}\n", .{v});
            }
            std.debug.print("dropped messages: {d}\n", .{c.droppedCount()});
        }
    };

    _ = try rt.spawn(.{}, S.worker, .{ &mtx, &sem, ch, @as(u32, 1) });
    _ = try rt.spawn(.{}, S.worker, .{ &mtx, &sem, ch, @as(u32, 2) });
    _ = try rt.spawn(.{}, S.drain, .{ch});
    try rt.run();
}
