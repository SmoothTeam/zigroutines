const std = @import("std");
const zr = @import("zigroutines");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var rt = try zr.Runtime.init(alloc, .{
        .workers = 1,
        .policy = .priority,
    });
    defer rt.deinit();

    const S = struct {
        fn job(name: []const u8) void {
            std.debug.print("run {s}\n", .{name});
        }
    };

    _ = try rt.spawn(.{ .priority = 200, .name = "low" }, S.job, .{"low"});
    _ = try rt.spawn(.{ .priority = 0, .name = "high" }, S.job, .{"high"});
    _ = try rt.spawn(.{ .priority = 100, .name = "mid" }, S.job, .{"mid"});
    try rt.run();
}
