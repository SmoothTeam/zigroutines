const std = @import("std");

pub fn RingQueue(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        buf: []T = &.{},
        head: usize = 0,
        len: usize = 0,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            if (self.buf.len != 0) self.allocator.free(self.buf);
            self.* = undefined;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.len == 0;
        }

        pub fn count(self: *const Self) usize {
            return self.len;
        }

        pub fn push(self: *Self, item: T) !void {
            if (self.len == self.buf.len) {
                try self.grow();
            }
            const idx = (self.head + self.len) % self.buf.len;
            self.buf[idx] = item;
            self.len += 1;
        }

        pub fn pop(self: *Self) ?T {
            if (self.len == 0) return null;
            const item = self.buf[self.head];
            self.head = (self.head + 1) % self.buf.len;
            self.len -= 1;
            return item;
        }

        pub fn peek(self: *const Self) ?T {
            if (self.len == 0) return null;
            return self.buf[self.head];
        }

        fn grow(self: *Self) !void {
            const old_cap = self.buf.len;
            const new_cap = if (old_cap == 0) 16 else old_cap * 2;
            const new_buf = try self.allocator.alloc(T, new_cap);
            var i: usize = 0;
            while (i < self.len) : (i += 1) {
                new_buf[i] = self.buf[(self.head + i) % old_cap];
            }
            if (old_cap != 0) self.allocator.free(self.buf);
            self.buf = new_buf;
            self.head = 0;
        }
    };
}

test "ring queue basic" {
    var q = RingQueue(u32).init(std.testing.allocator);
    defer q.deinit();
    try q.push(1);
    try q.push(2);
    try q.push(3);
    try std.testing.expectEqual(@as(?u32, 1), q.pop());
    try std.testing.expectEqual(@as(?u32, 2), q.pop());
    try q.push(4);
    try std.testing.expectEqual(@as(?u32, 3), q.pop());
    try std.testing.expectEqual(@as(?u32, 4), q.pop());
    try std.testing.expect(q.isEmpty());
}
