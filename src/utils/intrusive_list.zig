// SPDX-FileCopyrightText: 2026 Apanazar
//
// SPDX-License-Identifier: LGPL-3.0-or-later

const std = @import("std");

pub const Node = struct {
    next: ?*Node = null,
    prev: ?*Node = null,
    linked: bool = false,
};

pub const List = struct {
    head: ?*Node = null,
    tail: ?*Node = null,
    len: usize = 0,

    pub fn isEmpty(self: *const List) bool {
        return self.head == null;
    }

    pub fn pushBack(self: *List, node: *Node) void {
        std.debug.assert(!node.linked);
        node.next = null;
        node.prev = self.tail;
        if (self.tail) |t| {
            t.next = node;
        } else {
            self.head = node;
        }
        self.tail = node;
        node.linked = true;
        self.len += 1;
    }

    pub fn pushFront(self: *List, node: *Node) void {
        std.debug.assert(!node.linked);
        node.prev = null;
        node.next = self.head;
        if (self.head) |h| {
            h.prev = node;
        } else {
            self.tail = node;
        }
        self.head = node;
        node.linked = true;
        self.len += 1;
    }

    pub fn popFront(self: *List) ?*Node {
        const n = self.head orelse return null;
        self.remove(n);
        return n;
    }

    pub fn popBack(self: *List) ?*Node {
        const n = self.tail orelse return null;
        self.remove(n);
        return n;
    }

    pub fn remove(self: *List, node: *Node) void {
        if (!node.linked) return;
        if (node.prev) |p| {
            p.next = node.next;
        } else {
            self.head = node.next;
        }
        if (node.next) |n| {
            n.prev = node.prev;
        } else {
            self.tail = node.prev;
        }
        node.next = null;
        node.prev = null;
        node.linked = false;
        self.len -= 1;
    }

    pub fn clear(self: *List) void {
        while (self.popFront()) |_| {}
    }
};

pub fn parent(comptime T: type, comptime field_name: []const u8, node: *Node) *T {
    return @fieldParentPtr(field_name, node);
}

test "intrusive list fifo" {
    var a: Node = .{};
    var b: Node = .{};
    var c: Node = .{};
    var list: List = .{};

    list.pushBack(&a);
    list.pushBack(&b);
    list.pushBack(&c);
    try std.testing.expectEqual(@as(usize, 3), list.len);

    try std.testing.expect(list.popFront() == &a);
    list.remove(&c);
    try std.testing.expect(list.popFront() == &b);
    try std.testing.expect(list.isEmpty());
}
