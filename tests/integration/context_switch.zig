// SPDX-FileCopyrightText: 2026 Apanazar
//
// SPDX-License-Identifier: LGPL-3.0-or-later

const std = @import("std");
const zr = @import("zigroutines");
const context = zr.context;

const TestPair = struct {
    main: context.Context = .{},
    fiber: context.Context = .{},
    hits: usize = 0,
    depth_ok: bool = false,
};

fn pingPongEntry(arg: *anyopaque) callconv(.c) void {
    const p: *TestPair = @ptrCast(@alignCast(arg));
    p.hits += 1;
    context.swap(&p.fiber, &p.main);
    p.hits += 1;
    context.swap(&p.fiber, &p.main);
    p.hits += 1;
    context.swap(&p.fiber, &p.main);
}

fn deep(n: u32, p: *TestPair) void {
    var pad: [64]u8 = undefined;
    @memset(&pad, @truncate(n));
    if (n == 0) {
        p.depth_ok = (pad[0] == 0);
        context.swap(&p.fiber, &p.main);
        return;
    }
    deep(n - 1, p);
    std.mem.doNotOptimizeAway(&pad);
}

fn deepEntry(arg: *anyopaque) callconv(.c) void {
    const p: *TestPair = @ptrCast(@alignCast(arg));
    deep(200, p);
    context.swap(&p.fiber, &p.main);
}

test "context swap ping-pong" {
    if (comptime !context.supported) return error.SkipZigTest;

    var pair: TestPair = .{};
    const stack_mem = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(16), 64 * 1024);
    defer std.testing.allocator.free(stack_mem);

    context.make(&pair.fiber, stack_mem, pingPongEntry, &pair);
    try std.testing.expect(context.isInitialized(&pair.fiber));
    try std.testing.expectEqual(@as(usize, 0), pair.hits);

    context.swap(&pair.main, &pair.fiber);
    try std.testing.expectEqual(@as(usize, 1), pair.hits);
    context.swap(&pair.main, &pair.fiber);
    try std.testing.expectEqual(@as(usize, 2), pair.hits);
    context.swap(&pair.main, &pair.fiber);
    try std.testing.expectEqual(@as(usize, 3), pair.hits);
}

test "context preserves deep call stack" {
    if (comptime !context.supported) return error.SkipZigTest;

    var pair: TestPair = .{};
    const stack_mem = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(16), 64 * 1024);
    defer std.testing.allocator.free(stack_mem);

    context.make(&pair.fiber, stack_mem, deepEntry, &pair);
    context.swap(&pair.main, &pair.fiber);
    try std.testing.expect(pair.depth_ok);
}

test "many swaps stress" {
    if (comptime !context.supported) return error.SkipZigTest;

    const State = struct {
        main: context.Context = .{},
        fiber: context.Context = .{},
        count: usize = 0,
        target: usize = 10_000,
    };

    const entry = struct {
        fn f(arg: *anyopaque) callconv(.c) void {
            const s: *State = @ptrCast(@alignCast(arg));
            while (s.count < s.target) {
                s.count += 1;
                context.swap(&s.fiber, &s.main);
            }
            context.swap(&s.fiber, &s.main);
        }
    }.f;

    var state: State = .{};
    const stack_mem = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(16), 32 * 1024);
    defer std.testing.allocator.free(stack_mem);

    context.make(&state.fiber, stack_mem, entry, &state);
    while (state.count < state.target) {
        context.swap(&state.main, &state.fiber);
    }
    context.swap(&state.main, &state.fiber);
    try std.testing.expectEqual(@as(usize, 10_000), state.count);
}

test "arch support matches target" {
    if (comptime zr.context.ArchSupport.x86_64_windows or zr.context.ArchSupport.x86_64_linux) {
        try std.testing.expect(context.supported);
    }
}
