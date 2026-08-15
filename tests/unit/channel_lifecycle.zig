// SPDX-FileCopyrightText: 2026 Apanazar
//
// SPDX-License-Identifier: LGPL-3.0-or-later

const std = @import("std");
const zr = @import("zigroutines");

test "chan: create destroy buffered" {
    const Ch = zr.Channel(u32);
    const ch = try Ch.create(std.testing.allocator, 8);
    defer ch.destroy();
    try std.testing.expect(!ch.isRendezvous());
    try std.testing.expectEqual(@as(usize, 8), ch.capacity);
}

test "chan: capacity zero is rendezvous" {
    const Ch = zr.Channel(void);
    const ch = try Ch.create(std.testing.allocator, 0);
    defer ch.destroy();
    try std.testing.expect(ch.isRendezvous());
}

test "chan: createWith full policies construct" {
    const Ch = zr.Channel(u8);
    inline for (.{ .block, .drop_newest, .drop_oldest, .error_full }) |policy| {
        const ch = try Ch.createWith(std.testing.allocator, 4, .{ .full_policy = policy });
        defer ch.destroy();
        try std.testing.expectEqual(@as(usize, 4), ch.capacity);
        try std.testing.expect(!ch.isClosed());
        try std.testing.expectEqual(@as(usize, 0), ch.lenBuffered());
    }
}

test "chan: createPooled recycles same slot" {
    const Ch = zr.Channel(u32);
    const first = try Ch.createPooled(std.heap.page_allocator, 8);
    const first_ptr: *Ch = first;
    first.destroy();
    const second = try Ch.createPooled(std.heap.page_allocator, 8);
    defer second.destroy();
    try std.testing.expectEqual(first_ptr, second);
}

test "chan: double close is idempotent" {
    const Ch = zr.Channel(u32);
    const ch = try Ch.create(std.testing.allocator, 1);
    defer ch.destroy();
    ch.close();
    ch.close();
    try std.testing.expect(ch.isClosed());
}
