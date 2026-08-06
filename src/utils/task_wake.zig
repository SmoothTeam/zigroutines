const std = @import("std");
const task_mod = @import("../core/task.zig");

pub fn wakeTask(t: *task_mod.Task) void {
    var spins: u32 = 0;
    while (t.on_cpu.load(.acquire)) {
        std.atomic.spinLoopHint();
        spins +%= 1;
        if (spins > 200) {
            std.Thread.yield() catch {};
            spins = 0;
        }
    }

    if (t.state != .blocked) return;

    if (t.executor) |ex| {
        ex.enqueue(t) catch {
            t.scheduled.store(false, .release);
        };
    }
}
