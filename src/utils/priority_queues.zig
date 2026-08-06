const std = @import("std");
const ring = @import("ring_queue.zig");

pub fn PriorityQueues(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        levels: [256]ring.RingQueue(T),
        mask: [4]u64 = @splat(0),
        total: usize = 0,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            var self: Self = .{
                .allocator = allocator,
                .levels = undefined,
            };
            for (&self.levels) |*q| {
                q.* = ring.RingQueue(T).init(allocator);
            }
            return self;
        }

        pub fn deinit(self: *Self) void {
            for (&self.levels) |*q| q.deinit();
            self.* = undefined;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.total == 0;
        }

        pub fn count(self: *const Self) usize {
            return self.total;
        }

        pub fn push(self: *Self, priority: u8, item: T) !void {
            try self.levels[priority].push(item);
            self.setBit(priority);
            self.total += 1;
        }

        pub fn pop(self: *Self) ?T {
            const p = self.highestNonEmpty() orelse return null;
            const item = self.levels[p].pop() orelse return null;
            self.total -= 1;
            if (self.levels[p].isEmpty()) self.clearBit(p);
            return item;
        }

        fn setBit(self: *Self, p: u8) void {
            const word = p / 64;
            const bit: u64 = @as(u64, 1) << @intCast(p % 64);
            self.mask[word] |= bit;
        }

        fn clearBit(self: *Self, p: u8) void {
            const word = p / 64;
            const bit: u64 = @as(u64, 1) << @intCast(p % 64);
            self.mask[word] &= ~bit;
        }

        fn highestNonEmpty(self: *const Self) ?u8 {
            for (self.mask, 0..) |w, wi| {
                if (w == 0) continue;
                const bit_index: u8 = @intCast(@ctz(w));
                return @intCast(wi * 64 + bit_index);
            }
            return null;
        }
    };
}

test "priority queues order" {
    var pq = PriorityQueues(u32).init(std.testing.allocator);
    defer pq.deinit();
    try pq.push(10, 10);
    try pq.push(1, 1);
    try pq.push(5, 5);
    try pq.push(1, 2);
    try std.testing.expectEqual(@as(?u32, 1), pq.pop());
    try std.testing.expectEqual(@as(?u32, 2), pq.pop());
    try std.testing.expectEqual(@as(?u32, 5), pq.pop());
    try std.testing.expectEqual(@as(?u32, 10), pq.pop());
}
