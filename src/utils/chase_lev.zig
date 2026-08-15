// SPDX-FileCopyrightText: 2026 Apanazar
//
// SPDX-License-Identifier: LGPL-3.0-or-later

const std = @import("std");

pub fn ChaseLevDeque(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        buf: []T = &.{},
        bottom: std.atomic.Value(usize) = .init(0),
        top: std.atomic.Value(usize) = .init(0),
        retired: std.ArrayListUnmanaged([]T) = .empty,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) !Self {
            return .{
                .allocator = allocator,
                .buf = try allocator.alloc(T, 64),
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.buf.len != 0) self.allocator.free(self.buf);
            for (self.retired.items) |old| self.allocator.free(old);
            self.retired.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn isEmptyApprox(self: *Self) bool {
            const b = self.bottom.load(.monotonic);
            const t = self.top.load(.monotonic);
            return t >= b;
        }

        pub fn lenApprox(self: *Self) usize {
            const b = self.bottom.load(.monotonic);
            const t = self.top.load(.monotonic);
            return if (b > t) b - t else 0;
        }

        pub fn push(self: *Self, item: T) !void {
            const b = self.bottom.load(.monotonic);
            const t = self.top.load(.acquire);
            if (b >= t and b - t >= self.buf.len) {
                try self.grow(b, t);
            }
            self.buf[b % self.buf.len] = item;
            self.bottom.store(b + 1, .release);
        }

        pub fn pop(self: *Self) ?T {
            var b = self.bottom.load(.monotonic);
            if (b == 0) return null;
            b -= 1;
            self.bottom.store(b, .seq_cst);
            const t = self.top.load(.seq_cst);
            if (t > b) {
                self.bottom.store(t, .monotonic);
                return null;
            }
            const item = self.buf[b % self.buf.len];
            if (t == b) {
                if (self.top.cmpxchgStrong(t, t + 1, .seq_cst, .monotonic) != null) {
                    self.bottom.store(t + 1, .monotonic);
                    return null;
                }
                self.bottom.store(t + 1, .monotonic);
            }
            return item;
        }

        pub fn steal(self: *Self) ?T {
            const t = self.top.load(.acquire);
            const b = self.bottom.load(.acquire);
            if (t >= b) return null;
            const item = self.buf[t % self.buf.len];
            if (self.top.cmpxchgStrong(t, t + 1, .seq_cst, .monotonic) != null) {
                return null;
            }
            return item;
        }

        fn grow(self: *Self, b: usize, t: usize) !void {
            const size = b -% t;
            const new_cap = self.buf.len * 2;
            const new_buf = try self.allocator.alloc(T, new_cap);
            var i: usize = 0;
            while (i < size) : (i += 1) {
                new_buf[(t + i) % new_cap] = self.buf[(t + i) % self.buf.len];
            }
            try self.retired.append(self.allocator, self.buf);
            self.buf = new_buf;
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

test "chase-lev steal empty" {
    const D = ChaseLevDeque(u32);
    var d = try D.init(std.testing.allocator);
    defer d.deinit();
    try std.testing.expect(d.steal() == null);
    try d.push(7);
    try std.testing.expectEqual(@as(?u32, 7), d.steal());
    try std.testing.expect(d.steal() == null);
}
