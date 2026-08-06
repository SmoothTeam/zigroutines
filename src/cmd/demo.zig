const std = @import("std");
const zr = @import("zigroutines");

pub fn main() !void {
    std.debug.print("zigroutines {f}\n", .{zr.version});
    std.debug.print("context supported: {}\n", .{zr.context.supported});

    if (!zr.context.supported) return;

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    {
        std.debug.print("-- single-thread --\n", .{});
        var rt = try zr.Runtime.init(alloc, .{ .workers = 1 });
        defer rt.deinit();

        const work = struct {
            fn f(name: []const u8) void {
                std.debug.print("  hello from {s}\n", .{name});
                zr.yield();
            }
        }.f;

        _ = try rt.spawn(.{}, work, .{"A"});
        _ = try rt.spawn(.{}, work, .{"B"});
        try rt.run();
    }

    {
        std.debug.print("-- channel pipeline --\n", .{});
        var rt = try zr.Runtime.init(alloc, .{ .workers = 1 });
        defer rt.deinit();

        const Ch = zr.Channel(usize);
        const ch = try Ch.create(alloc, 4);
        defer ch.destroy();

        const Pipe = struct {
            fn producer(c: *Ch) void {
                var i: usize = 1;
                while (i <= 5) : (i += 1) {
                    c.send(i) catch unreachable;
                }
                c.close();
            }
            fn consumer(c: *Ch) void {
                var sum: usize = 0;
                while (true) {
                    const v = c.recv() catch |err| switch (err) {
                        error.Closed => break,
                        else => unreachable,
                    };
                    sum += v;
                }
                std.debug.print("  sum 1..5 = {d}\n", .{sum});
            }
        };

        _ = try rt.spawn(.{}, Pipe.producer, .{ch});
        _ = try rt.spawn(.{}, Pipe.consumer, .{ch});
        try rt.run();
    }
}
