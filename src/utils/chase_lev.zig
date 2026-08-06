const std = @import("std");

pub fn ChaseLevDeque(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        buf: []T = &.{},
        bottom: usize = 0,
        top: usize = 0,
        lock: std.atomic.Value(u8) = .init(0),

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) !Self {
            var self = Self{ .allocator = allocator };
            self.buf = try allocator.alloc(T, 64);
            return self;
        }

        pub fn deinit(self: *Self) void {
            if (self.buf.len != 0) self.allocator.free(self.buf);
            self.* = undefined;
        }

        fn spinLock(self: *Self) void {
            while (self.lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
                std.atomic.spinLoopHint();
            }
        }

        fn spinUnlock(self: *Self) void {
            self.lock.store(0, .release);
        }

        pub fn isEmptyApprox(self: *Self) bool {
            self.spinLock();
            defer self.spinUnlock();
            return self.bottom == self.top;
        }

        pub fn push(self: *Self, item: T) !void {
            self.spinLock();
            defer self.spinUnlock();
            if (self.bottom - self.top == self.buf.len) {
                try self.growUnlocked();
            }
            self.buf[self.bottom % self.buf.len] = item;
            self.bottom += 1;
        }

        pub fn pop(self: *Self) ?T {
            self.spinLock();
            defer self.spinUnlock();
            if (self.bottom == self.top) return null;
            self.bottom -= 1;
            return self.buf[self.bottom % self.buf.len];
        }

        pub fn steal(self: *Self) ?T {
            self.spinLock();
            defer self.spinUnlock();
            if (self.bottom == self.top) return null;
            const item = self.buf[self.top % self.buf.len];
            self.top += 1;
            return item;
        }

        fn growUnlocked(self: *Self) !void {
            const size = self.bottom - self.top;
            const new_cap = if (self.buf.len == 0) 64 else self.buf.len * 2;
            const new_buf = try self.allocator.alloc(T, new_cap);
            var i: usize = 0;
            while (i < size) : (i += 1) {
                new_buf[i] = self.buf[(self.top + i) % self.buf.len];
            }
            self.allocator.free(self.buf);
            self.buf = new_buf;
            self.top = 0;
            self.bottom = size;
        }
    };
}

test "chase-lev owner and steal" {
    const D = ChaseLevDeque(u32);
    var d = try D.init(std.testing.allocator);
    defer d.deinit();

    try d.push(1);
    try d.push(2);
    try d.push(3);
    try std.testing.expectEqual(@as(?u32, 3), d.pop());
    try std.testing.expectEqual(@as(?u32, 1), d.steal());
    try std.testing.expectEqual(@as(?u32, 2), d.pop());
    try std.testing.expect(d.pop() == null);
}
