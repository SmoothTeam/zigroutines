// SPDX-FileCopyrightText: 2026 Apanazar
//
// SPDX-License-Identifier: LGPL-3.0-or-later

const std = @import("std");
const task_mod = @import("../core/task.zig");
const cancel_mod = @import("../core/cancellation.zig");

pub const FutureState = struct {
    allocator: std.mem.Allocator,
    context: []u8,
    context_align: std.mem.Alignment,
    result: []u8,
    result_align: std.mem.Alignment,
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,
    join: task_mod.JoinHandle,
    token: cancel_mod.CancelToken,
    finished: std.atomic.Value(bool) = .init(false),

    pub fn create(
        allocator: std.mem.Allocator,
        result_len: usize,
        result_alignment: std.mem.Alignment,
        context: []const u8,
        context_alignment: std.mem.Alignment,
        start: *const fn (context: *const anyopaque, result: *anyopaque) void,
    ) !*FutureState {
        const self = try allocator.create(FutureState);
        errdefer allocator.destroy(self);

        const ctx_buf = try allocAligned(allocator, context_alignment, context.len);
        errdefer freeAligned(allocator, context_alignment, ctx_buf);
        if (context.len > 0) @memcpy(ctx_buf, context);

        const res_buf = try allocAligned(allocator, result_alignment, result_len);
        errdefer freeAligned(allocator, result_alignment, res_buf);
        if (result_len > 0) @memset(res_buf, 0);

        self.* = .{
            .allocator = allocator,
            .context = ctx_buf,
            .context_align = context_alignment,
            .result = res_buf,
            .result_align = result_alignment,
            .start = start,
            .join = .{ .task = undefined },
            .token = cancel_mod.CancelToken.initWithAllocator(allocator),
        };
        return self;
    }

    pub fn destroy(self: *FutureState) void {
        self.token.deinit();
        freeAligned(self.allocator, self.context_align, self.context);
        freeAligned(self.allocator, self.result_align, self.result);
        self.allocator.destroy(self);
    }

    pub fn runBody(self: *FutureState) void {
        self.start(self.context.ptr, self.result.ptr);
        self.finished.store(true, .release);
    }
};

fn allocAligned(allocator: std.mem.Allocator, alignment: std.mem.Alignment, len: usize) ![]u8 {
    if (len == 0) return &.{};
    const ptr = allocator.rawAlloc(len, alignment, @returnAddress()) orelse return error.OutOfMemory;
    return ptr[0..len];
}

fn freeAligned(allocator: std.mem.Allocator, alignment: std.mem.Alignment, buf: []u8) void {
    if (buf.len == 0) return;
    allocator.rawFree(buf, alignment, @returnAddress());
}
