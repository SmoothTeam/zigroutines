// SPDX-FileCopyrightText: 2026 Apanazar
//
// SPDX-License-Identifier: LGPL-3.0-or-later

const std = @import("std");
const zr = @import("zigroutines");

test "version is 1.0.x" {
    try std.testing.expectEqual(@as(u32, 1), zr.version.major);
    try std.testing.expectEqual(@as(u32, 0), zr.version.minor);
}

test {
    // Utils/foundation
    _ = @import("zigroutines").utils;
    _ = @import("zigroutines").timer_queue;

    // Unit
    _ = @import("unit/stack_pool.zig");
    _ = @import("unit/channel_lifecycle.zig");
    _ = @import("unit/cancellation_token.zig");
    _ = @import("unit/metrics.zig");
    _ = @import("unit/preemption.zig");
    _ = @import("unit/stack_guard_and_canary.zig");
    _ = @import("unit/synchronization.zig");
    _ = @import("unit/rwlock_exclusive.zig");
    _ = @import("unit/timer_queue.zig");
    _ = @import("unit/actor_lifecycle.zig");
    _ = @import("abi/c_abi.zig");

    // Integration
    _ = @import("integration/context_switch.zig");
    _ = @import("integration/fifo_scheduler.zig");
    _ = @import("integration/work_stealing_scheduler.zig");
    _ = @import("integration/channel_messaging.zig");
    _ = @import("integration/select_cancellation_scope.zig");
    _ = @import("integration/advanced_features.zig");
    _ = @import("integration/drop_newest_and_nursery.zig");

    // I/O
    _ = @import("io/mock_and_poll_backend.zig");
    _ = @import("io/std_io_adapter.zig");
    _ = @import("io/tcp_echo.zig");

    // Stress
    _ = @import("stress/multi_worker_channels.zig");
}
