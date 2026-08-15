// SPDX-FileCopyrightText: 2026 Apanazar
//
// SPDX-License-Identifier: LGPL-3.0-or-later

pub const fifo = @import("fifo_scheduler.zig");
pub const work_stealing = @import("work_stealing_scheduler.zig");
pub const priority = @import("priority_scheduler.zig");
pub const thread_per_task = @import("thread_per_task_scheduler.zig");

pub const FifoScheduler = fifo.FifoScheduler;
pub const WorkStealingScheduler = work_stealing.WorkStealingScheduler;
pub const PriorityScheduler = priority.PriorityScheduler;
pub const ThreadPerTaskScheduler = thread_per_task.ThreadPerTaskScheduler;

pub const PolicyKind = enum {
    single_thread_fifo,
    work_stealing,
    priority,
    thread_per_task,
};

pub const default_policy: PolicyKind = .work_stealing;
