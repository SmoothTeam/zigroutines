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

    _ = try rt.spawn(.{}, struct {
        fn hello(name: []const u8) void {
            std.debug.print("hello from {s}\n", .{name});
            zr.yield();
        }
    }.hello, .{"A"});

    _ = try rt.spawn(.{}, struct {
        fn hello(name: []const u8) void {
            std.debug.print("hello from {s}\n", .{name});
        }
    }.hello, .{"B"});

    try rt.run();
}
