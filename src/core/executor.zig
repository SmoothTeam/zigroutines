const task_mod = @import("task.zig");

pub const Executor = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        enqueue: *const fn (ptr: *anyopaque, t: *task_mod.Task) anyerror!void,
        yieldFromRunning: *const fn (ptr: *anyopaque) void,
        parkFromRunning: *const fn (ptr: *anyopaque, reason: task_mod.WaitReason) void,
        finishFromRunning: *const fn (ptr: *anyopaque) void,
    };

    pub fn enqueue(self: Executor, t: *task_mod.Task) !void {
        return self.vtable.enqueue(self.ptr, t);
    }

    pub fn yieldFromRunning(self: Executor) void {
        self.vtable.yieldFromRunning(self.ptr);
    }

    pub fn parkFromRunning(self: Executor, reason: task_mod.WaitReason) void {
        self.vtable.parkFromRunning(self.ptr, reason);
    }

    pub fn finishFromRunning(self: Executor) void {
        self.vtable.finishFromRunning(self.ptr);
    }
};
