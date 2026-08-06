const builtin = @import("builtin");

pub const wake = @import("task_wake.zig");
pub const intrusive = @import("intrusive_list.zig");
pub const ring_queue = @import("ring_queue.zig");
pub const chase_lev = @import("chase_lev.zig");
pub const worker_wake = @import("worker_wake.zig");
pub const priority_queues = @import("priority_queues.zig");
pub const win = if (builtin.os.tag == .windows) @import("windows_api.zig") else struct {};

pub const wakeTask = wake.wakeTask;
pub const ListNode = intrusive.Node;
pub const IntrusiveList = intrusive.List;
pub const RingQueue = ring_queue.RingQueue;
pub const ChaseLevDeque = chase_lev.ChaseLevDeque;
pub const WorkerWake = worker_wake.WorkerWake;
pub const PriorityQueues = priority_queues.PriorityQueues;

test {
    _ = intrusive;
    _ = ring_queue;
    _ = chase_lev;
    _ = priority_queues;
}
