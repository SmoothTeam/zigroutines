const std = @import("std");
const zr = @import("zigroutines");

const fiber_benches = @import("fiber_benches.zig");
const channel_benches = @import("channel_benches.zig");
const select_benches = @import("select_benches.zig");
const sync_benches = @import("sync_benches.zig");
const timer_benches = @import("timer_benches.zig");
const io_benches = @import("io_benches.zig");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{ .safety = false, .thread_safe = true }) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    std.debug.print("zigroutines bench  version={f}  (use -Doptimize=ReleaseFast)\n", .{zr.version});
    std.debug.print("--- fiber / spawn ---\n", .{});
    try fiber_benches.runAll(alloc);

    std.debug.print("--- channel / actor ---\n", .{});
    try channel_benches.runAll(alloc);

    std.debug.print("--- select ---\n", .{});
    try select_benches.runAll(alloc);

    std.debug.print("--- sync ---\n", .{});
    try sync_benches.runAll(alloc);

    std.debug.print("--- timers ---\n", .{});
    try timer_benches.runAll(alloc);

    std.debug.print("--- io (poll) ---\n", .{});
    try io_benches.runAll(alloc);

    std.debug.print("---\ndone\n", .{});
}
