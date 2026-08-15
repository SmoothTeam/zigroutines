// SPDX-FileCopyrightText: 2026 Apanazar
//
// SPDX-License-Identifier: LGPL-3.0-or-later

const std = @import("std");
const zr = @import("zigroutines");

test "timer wheel nextDeadlineNs follows occupied bitmap" {
    var tq = zr.TimerQueue.init(std.testing.allocator);
    defer tq.deinit();

    var dummy: zr.Task = .{};
    const now = zr.timer_queue.nowNs();
    const tick = zr.TimerQueue.tick_ns;
    var near = zr.timer_queue.TimerEntry{ .deadline_ns = now + 5 * tick, .task = &dummy };
    var far = zr.timer_queue.TimerEntry{ .deadline_ns = now + 80 * tick, .task = &dummy };
    tq.add(&near);
    tq.add(&far);

    const first = tq.nextDeadlineNs() orelse return error.NoDeadline;
    try std.testing.expect(first <= near.deadline_ns + tick);

    tq.remove(&near);
    const second = tq.nextDeadlineNs() orelse return error.NoDeadline;
    try std.testing.expect(second >= first);
    try std.testing.expect(second <= far.deadline_ns + tick);

    tq.remove(&far);
    try std.testing.expect(tq.nextDeadlineNs() == null);
}
