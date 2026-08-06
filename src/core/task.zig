const std = @import("std");
const stack_mod = @import("../stack/stack.zig");
const context_mod = @import("../context/context.zig");
const executor_mod = @import("executor.zig");
const list = @import("../utils/intrusive_list.zig");

pub const TaskId = enum(u64) {
    invalid = 0,
    _,

    pub fn next() TaskId {
        const n = id_counter.fetchAdd(1, .monotonic);
        return @enumFromInt(n + 1);
    }
};

var id_counter: std.atomic.Value(u64) = .init(0);

pub const State = enum {
    ready,
    running,
    blocked,
    canceled,
    dead,
};

pub const WaitReason = enum {
    none,
    chan_send,
    chan_recv,
    timer,
    io,
    join,
    manual_park,
};

threadlocal var current_task: ?*Task = null;

pub fn current() ?*Task {
    return current_task;
}

pub fn setCurrent(t: ?*Task) void {
    current_task = t;
}

pub const SpawnOptions = struct {
    stack_size: usize = stack_mod.default_stack_size,
    name: ?[:0]const u8 = null,
    priority: u8 = 128,
    guard_page: bool = false,
    paint_canary: bool = false,
};

pub const JoinWaiter = struct {
    node: list.Node = .{},
    task: *Task,
    parked: bool = false,
    done: bool = false,
};

pub const JoinHandle = struct {
    task: *Task,

    pub fn isDone(self: JoinHandle) bool {
        return self.task.finished.load(.acquire);
    }

    pub fn join(self: JoinHandle) void {
        if (self.isDone()) return;

        const me = current();
        if (me == null or me.?.executor == null) {
            while (!self.isDone()) {
                std.Thread.yield() catch {};
            }
            return;
        }

        var waiter = JoinWaiter{ .task = me.? };
        while (!self.isDone()) {
            self.task.join_lock.lock();
            if (self.task.finished.load(.acquire) or waiter.done) {
                if (waiter.node.linked) self.task.join_waiters.remove(&waiter.node);
                self.task.join_lock.unlock();
                return;
            }
            waiter.done = false;
            waiter.node = .{};
            self.task.join_waiters.pushBack(&waiter.node);
            if (self.task.finished.load(.acquire)) {
                self.task.join_waiters.remove(&waiter.node);
                self.task.join_lock.unlock();
                return;
            }
            waiter.parked = true;
            self.task.join_lock.unlock();

            me.?.executor.?.parkFromRunning(.join);

            if (waiter.node.linked) {
                self.task.join_lock.lock();
                self.task.join_waiters.remove(&waiter.node);
                self.task.join_lock.unlock();
            }
            waiter.parked = false;
        }
    }
};

pub fn TypedJoinHandle(comptime R: type) type {
    return struct {
        raw: JoinHandle,
        slot: *ResultSlot(R),

        const Self = @This();

        pub fn isDone(self: Self) bool {
            return self.raw.isDone();
        }

        pub fn join(self: Self) R {
            self.raw.join();
            const v = self.slot.value;
            return v;
        }

        pub fn joinError(self: Self) anyerror!R {
            self.raw.join();
            if (self.slot.err) |e| return e;
            return self.slot.value;
        }
    };
}

pub fn ResultSlot(comptime R: type) type {
    return struct {
        value: R = undefined,
        err: ?anyerror = null,
        has_value: bool = false,
    };
}

pub const Task = struct {
    id: TaskId = .invalid,
    state: State = .dead,
    stack: stack_mod.Stack = .{},
    ctx: context_mod.Context = .{},
    blocked_on: WaitReason = .none,
    name: ?[:0]const u8 = null,
    priority: u8 = 128,

    allocator: std.mem.Allocator = undefined,
    executor: ?executor_mod.Executor = null,
    stack_pool: ?*stack_mod.Pool = null,

    entry_fn: ?*const fn (*Task) void = null,
    user_data: ?*anyopaque = null,

    on_cpu: std.atomic.Value(bool) = .init(false),
    finished: std.atomic.Value(bool) = .init(false),
    scheduled: std.atomic.Value(bool) = .init(false),

    join_waiters: list.List = .{},
    join_lock: JoinSpin = .{},

    result_slot: ?*anyopaque = null,
    result_deinit: ?*const fn (*anyopaque, std.mem.Allocator) void = null,

    pub fn isAlive(self: *const Task) bool {
        return !self.finished.load(.acquire);
    }

    pub fn finishJoiners(self: *Task) void {
        self.join_lock.lock();
        var to_wake: [32]*Task = undefined;
        var n: usize = 0;
        while (self.join_waiters.popFront()) |node| {
            const w: *JoinWaiter = @fieldParentPtr("node", node);
            w.done = true;
            if (w.parked) {
                if (n < to_wake.len) {
                    to_wake[n] = w.task;
                    n += 1;
                } else {
                    self.join_lock.unlock();
                    wakeJoin(w.task);
                    self.join_lock.lock();
                }
            }
        }
        self.join_lock.unlock();
        for (to_wake[0..n]) |t| wakeJoin(t);
    }

    pub fn destroy(self: *Task) void {
        if (self.result_slot) |slot| {
            if (self.result_deinit) |f| f(slot, self.allocator);
            self.result_slot = null;
        }
        if (self.stack.memory.len != 0) {
            if (self.stack_pool) |pool| {
                pool.release(self.stack);
            } else {
                stack_mod.free(self.allocator, self.stack);
            }
            self.stack = .{};
            self.stack_pool = null;
        }
        const allocator = self.allocator;
        allocator.destroy(self);
    }
};

const JoinSpin = struct {
    state: std.atomic.Value(u8) = .init(0),
    fn lock(self: *JoinSpin) void {
        while (self.state.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }
    fn unlock(self: *JoinSpin) void {
        self.state.store(0, .release);
    }
};

fn wakeJoin(t: *Task) void {
    var spins: u32 = 0;
    while (t.on_cpu.load(.acquire)) {
        std.atomic.spinLoopHint();
        spins +%= 1;
        if (spins > 200) {
            std.Thread.yield() catch {};
            spins = 0;
        }
    }
    if (t.state == .blocked) {
        if (t.executor) |ex| {
            ex.enqueue(t) catch {};
        }
    }
}

fn taskTrampoline(arg: *anyopaque) callconv(.c) void {
    const t: *Task = @ptrCast(@alignCast(arg));
    if (t.entry_fn) |f| {
        f(t);
    }
    t.finished.store(true, .release);
    t.finishJoiners();
    if (t.executor) |ex| {
        ex.finishFromRunning();
    }
    @panic("zigroutines: task finished with no executor");
}

pub fn spawnOn(
    executor: executor_mod.Executor,
    allocator: std.mem.Allocator,
    pool: ?*stack_mod.Pool,
    opts: SpawnOptions,
    comptime func: anytype,
    args: std.meta.ArgsTuple(@TypeOf(func)),
) !JoinHandle {
    if (comptime !context_mod.supported) {
        return error.UnsupportedTarget;
    }

    const Args = @TypeOf(args);
    const Wrapper = struct {
        args: Args,

        fn entry(t: *Task) void {
            const w: *@This() = @ptrCast(@alignCast(t.user_data.?));
            const ret = @call(.auto, func, w.args);
            _ = ret;
            t.allocator.destroy(w);
            t.user_data = null;
        }
    };

    const t = try allocator.create(Task);
    errdefer allocator.destroy(t);

    const use_direct = opts.guard_page or opts.paint_canary or pool == null;
    const stack = if (!use_direct)
        try pool.?.acquire(opts.stack_size)
    else
        try stack_mod.allocWith(allocator, opts.stack_size, .{
            .guard_page = opts.guard_page,
            .paint_canary = opts.paint_canary,
        });
    errdefer {
        if (!use_direct) pool.?.release(stack) else stack_mod.free(allocator, stack);
    }

    const wrapper = try allocator.create(Wrapper);
    errdefer allocator.destroy(wrapper);
    wrapper.* = .{ .args = args };

    t.* = .{
        .id = TaskId.next(),
        .state = .blocked,
        .stack = stack,
        .name = opts.name,
        .priority = opts.priority,
        .allocator = allocator,
        .executor = executor,
        .stack_pool = if (!use_direct) pool else null,
        .entry_fn = Wrapper.entry,
        .user_data = wrapper,
    };

    context_mod.make(&t.ctx, t.stack.bytes(), taskTrampoline, t);
    try executor.enqueue(t);

    return .{ .task = t };
}

pub fn spawnOnResult(
    executor: executor_mod.Executor,
    allocator: std.mem.Allocator,
    pool: ?*stack_mod.Pool,
    opts: SpawnOptions,
    comptime func: anytype,
    args: std.meta.ArgsTuple(@TypeOf(func)),
) !TypedJoinHandle(ResultTypeOf(func)) {
    if (comptime !context_mod.supported) {
        return error.UnsupportedTarget;
    }

    const R = ResultTypeOf(func);
    const Args = @TypeOf(args);
    const Slot = ResultSlot(R);

    const Wrapper = struct {
        args: Args,
        slot: *Slot,

        fn entry(t: *Task) void {
            const w: *@This() = @ptrCast(@alignCast(t.user_data.?));
            const Ret = @TypeOf(@call(.auto, func, w.args));
            if (comptime isErrorUnion(Ret)) {
                if (@call(.auto, func, w.args)) |v| {
                    w.slot.value = v;
                    w.slot.has_value = true;
                } else |e| {
                    w.slot.err = e;
                }
            } else {
                w.slot.value = @call(.auto, func, w.args);
                w.slot.has_value = true;
            }
            t.allocator.destroy(w);
            t.user_data = null;
        }
    };

    const t = try allocator.create(Task);
    errdefer allocator.destroy(t);

    const use_direct = opts.guard_page or opts.paint_canary or pool == null;
    const stack = if (!use_direct)
        try pool.?.acquire(opts.stack_size)
    else
        try stack_mod.allocWith(allocator, opts.stack_size, .{
            .guard_page = opts.guard_page,
            .paint_canary = opts.paint_canary,
        });
    errdefer {
        if (!use_direct) pool.?.release(stack) else stack_mod.free(allocator, stack);
    }

    const slot = try allocator.create(Slot);
    errdefer allocator.destroy(slot);
    slot.* = .{};

    const wrapper = try allocator.create(Wrapper);
    errdefer allocator.destroy(wrapper);
    wrapper.* = .{ .args = args, .slot = slot };

    t.* = .{
        .id = TaskId.next(),
        .state = .blocked,
        .stack = stack,
        .name = opts.name,
        .priority = opts.priority,
        .allocator = allocator,
        .executor = executor,
        .stack_pool = if (!use_direct) pool else null,
        .entry_fn = Wrapper.entry,
        .user_data = wrapper,
        .result_slot = slot,
        .result_deinit = struct {
            fn d(p: *anyopaque, a: std.mem.Allocator) void {
                const s: *Slot = @ptrCast(@alignCast(p));
                a.destroy(s);
            }
        }.d,
    };

    context_mod.make(&t.ctx, t.stack.bytes(), taskTrampoline, t);
    try executor.enqueue(t);

    return .{
        .raw = .{ .task = t },
        .slot = slot,
    };
}

fn ResultTypeOf(comptime func: anytype) type {
    return ResultTypeOfPublic(func);
}

pub fn ResultTypeOfPublic(comptime func: anytype) type {
    const Ret = @typeInfo(@TypeOf(func)).@"fn".return_type.?;
    if (comptime isErrorUnion(Ret)) {
        return @typeInfo(Ret).error_union.payload;
    }
    return Ret;
}

fn isErrorUnion(comptime T: type) bool {
    return @typeInfo(T) == .error_union;
}

pub fn yield() void {
    const t = current() orelse @panic("zigroutines: yield() outside a task");
    const ex = t.executor orelse @panic("zigroutines: yield() without executor");
    ex.yieldFromRunning();
}
