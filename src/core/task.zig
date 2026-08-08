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
    worker_bounce,
};

threadlocal var current_task: ?*Task = null;

pub fn current() ?*Task {
    return current_task;
}

pub fn setCurrent(t: ?*Task) void {
    current_task = t;
}

pub const TaskMode = enum {
    stackful,
    leaf,
};

pub const SpawnOptions = struct {
    mode: TaskMode = .stackful,
    name: ?[:0]const u8 = null,
    priority: u8 = 128,
    guard_page: bool = false,
    paint_canary: bool = false,
};

pub const TaskCache = struct {
    allocator: std.mem.Allocator,
    lock: std.atomic.Value(u8) = .init(0),
    free: std.ArrayListUnmanaged(*Task) = .empty,
    max: usize = 4096,
    enabled: bool = true,

    fn lockMutex(self: *TaskCache) void {
        while (self.lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }
    fn unlockMutex(self: *TaskCache) void {
        self.lock.store(0, .release);
    }

    pub fn init(allocator: std.mem.Allocator, enabled: bool) TaskCache {
        return .{ .allocator = allocator, .enabled = enabled };
    }

    pub fn deinit(self: *TaskCache) void {
        self.lockMutex();
        for (self.free.items) |t| {
            self.allocator.destroy(t);
        }
        self.free.deinit(self.allocator);
        self.unlockMutex();
        self.* = undefined;
    }

    pub fn acquire(self: *TaskCache) !*Task {
        if (self.enabled) {
            self.lockMutex();
            if (self.free.pop()) |t| {
                self.unlockMutex();
                return t;
            }
            self.unlockMutex();
        }
        return self.allocator.create(Task);
    }

    pub fn release(self: *TaskCache, t: *Task) void {
        t.task_cache = null;
        if (!self.enabled) {
            self.allocator.destroy(t);
            return;
        }
        self.lockMutex();
        if (self.free.items.len < self.max) {
            t.* = .{
                .generation = t.generation,
                .allocator = self.allocator,
            };
            self.free.append(self.allocator, t) catch {
                self.unlockMutex();
                self.allocator.destroy(t);
                return;
            };
            self.unlockMutex();
            return;
        }
        self.unlockMutex();
        self.allocator.destroy(t);
    }
};

pub const JoinWaiter = struct {
    node: list.Node = .{},
    task: *Task,
    parked: bool = false,
    done: bool = false,
};

pub const JoinHandle = struct {
    task: *Task,
    generation: u64 = 0,

    pub fn isDone(self: JoinHandle) bool {
        if (self.task.generation != self.generation) return true;
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
            if (self.task.generation != self.generation or self.task.finished.load(.acquire) or waiter.done) {
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
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn isDone(self: Self) bool {
            return self.raw.isDone();
        }

        pub fn join(self: Self) R {
            self.raw.join();
            const v = self.slot.value;
            self.allocator.destroy(self.slot);
            return v;
        }

        pub fn joinError(self: Self) anyerror!R {
            self.raw.join();
            if (self.slot.err) |e| {
                self.allocator.destroy(self.slot);
                return e;
            }
            const v = self.slot.value;
            self.allocator.destroy(self.slot);
            return v;
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
    generation: u64 = 0,
    state: State = .dead,
    stack: stack_mod.Stack = .{},
    ctx: context_mod.Context = .{},
    blocked_on: WaitReason = .none,
    name: ?[:0]const u8 = null,
    priority: u8 = 128,
    mode: TaskMode = .stackful,

    allocator: std.mem.Allocator = undefined,
    executor: ?executor_mod.Executor = null,
    stack_pool: ?*stack_mod.Pool = null,
    task_cache: ?*TaskCache = null,

    entry_fn: ?*const fn (*Task) void = null,
    user_data: ?*anyopaque = null,

    on_cpu: std.atomic.Value(bool) = .init(false),
    finished: std.atomic.Value(bool) = .init(false),
    scheduled: std.atomic.Value(bool) = .init(false),

    join_waiters: list.List = .{},
    join_lock: JoinSpin = .{},

    result_slot: ?*anyopaque = null,
    result_deinit: ?*const fn (*anyopaque, std.mem.Allocator) void = null,

    bounce_fn: ?*const fn (*anyopaque) void = null,
    bounce_arg: ?*anyopaque = null,

    recycled: bool = false,

    pub fn isLeaf(self: *const Task) bool {
        return self.mode == .leaf;
    }

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
        if (self.recycled) return;
        self.recycled = true;
        self.result_slot = null;
        self.result_deinit = null;
        if (self.stack.memory.len != 0 or self.stack.os_base != null) {
            if (self.stack_pool) |pool| {
                pool.release(self.stack);
            } else {
                stack_mod.free(self.allocator, self.stack);
            }
            self.stack = .{};
            self.stack_pool = null;
        }
        const cache = self.task_cache;
        const allocator = self.allocator;
        if (cache) |c| {
            self.generation +%= 1;
            const gen = self.generation;
            self.* = .{
                .generation = gen,
                .allocator = allocator,
                .task_cache = cache,
                .recycled = false,
            };
            c.release(self);
        } else {
            allocator.destroy(self);
        }
    }
};

pub fn waitUntilOffCpu(t: *Task) void {
    var spins: u32 = 0;
    while (t.on_cpu.load(.acquire)) {
        std.atomic.spinLoopHint();
        spins +%= 1;
        if (spins > 256) {
            std.Thread.yield() catch {};
            spins = 0;
        }
    }
}

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
    waitUntilOffCpu(t);
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

pub fn runLeafOnWorker(t: *Task) void {
    std.debug.assert(t.isLeaf());
    if (t.entry_fn) |f| {
        f(t);
    }
    if (!t.finished.load(.acquire)) {
        t.finished.store(true, .release);
        t.finishJoiners();
    }
}

pub const SpawnEnv = struct {
    executor: executor_mod.Executor,
    allocator: std.mem.Allocator,
    pool: ?*stack_mod.Pool = null,
    cache: ?*TaskCache = null,
};

pub fn spawnOn(
    executor: executor_mod.Executor,
    allocator: std.mem.Allocator,
    pool: ?*stack_mod.Pool,
    opts: SpawnOptions,
    comptime func: anytype,
    args: std.meta.ArgsTuple(@TypeOf(func)),
) !JoinHandle {
    return spawnOnEnv(.{
        .executor = executor,
        .allocator = allocator,
        .pool = pool,
        .cache = null,
    }, opts, func, args);
}

pub fn spawnOnEnv(
    env: SpawnEnv,
    opts: SpawnOptions,
    comptime func: anytype,
    args: std.meta.ArgsTuple(@TypeOf(func)),
) !JoinHandle {
    if (comptime !context_mod.supported) {
        return error.UnsupportedTarget;
    }

    const Args = @TypeOf(args);
    const zero_args = @sizeOf(Args) == 0;

    const t = if (env.cache) |c| try c.acquire() else try env.allocator.create(Task);
    errdefer {
        if (env.cache) |c| c.release(t) else env.allocator.destroy(t);
    }

    const is_leaf = opts.mode == .leaf;
    var stack: stack_mod.Stack = .{};
    var use_pool = false;

    if (!is_leaf) {
        const use_direct = opts.guard_page or opts.paint_canary or env.pool == null;
        stack = if (!use_direct)
            try env.pool.?.acquire(stack_mod.fiber_stack_size)
        else
            try stack_mod.allocWith(env.allocator, stack_mod.fiber_stack_size, .{
                .guard_page = opts.guard_page,
                .paint_canary = opts.paint_canary,
            });
        use_pool = !use_direct;
        errdefer {
            if (use_pool) env.pool.?.release(stack) else stack_mod.free(env.allocator, stack);
        }
    }

    var user_data: ?*anyopaque = null;
    const entry_fn: *const fn (*Task) void = if (comptime zero_args)
        struct {
            fn entry(task: *Task) void {
                _ = task;
                _ = @call(.auto, func, .{});
            }
        }.entry
    else blk: {
        const Wrapper = struct {
            args: Args,
            fn entry(task: *Task) void {
                const w: *@This() = @ptrCast(@alignCast(task.user_data.?));
                _ = @call(.auto, func, w.args);
                task.allocator.destroy(w);
                task.user_data = null;
            }
        };
        const wrapper = try env.allocator.create(Wrapper);
        errdefer env.allocator.destroy(wrapper);
        wrapper.* = .{ .args = args };
        user_data = wrapper;
        break :blk Wrapper.entry;
    };

    const gen = t.generation;
    t.* = .{
        .id = TaskId.next(),
        .generation = gen,
        .state = .blocked,
        .stack = stack,
        .name = opts.name,
        .priority = opts.priority,
        .mode = if (is_leaf) .leaf else .stackful,
        .allocator = env.allocator,
        .executor = env.executor,
        .stack_pool = if (use_pool) env.pool else null,
        .task_cache = env.cache,
        .entry_fn = entry_fn,
        .user_data = user_data,
        .on_cpu = .init(false),
        .finished = .init(false),
        .scheduled = .init(false),
        .join_waiters = .{},
        .join_lock = .{},
    };

    if (!is_leaf) {
        context_mod.make(&t.ctx, t.stack.bytes(), taskTrampoline, t);
    } else {
        t.ctx = .{};
    }
    try env.executor.enqueue(t);

    return .{ .task = t, .generation = gen };
}

pub fn spawnOnResult(
    executor: executor_mod.Executor,
    allocator: std.mem.Allocator,
    pool: ?*stack_mod.Pool,
    opts: SpawnOptions,
    comptime func: anytype,
    args: std.meta.ArgsTuple(@TypeOf(func)),
) !TypedJoinHandle(ResultTypeOf(func)) {
    return spawnOnResultEnv(.{
        .executor = executor,
        .allocator = allocator,
        .pool = pool,
        .cache = null,
    }, opts, func, args);
}

pub fn spawnOnResultEnv(
    env: SpawnEnv,
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

    const t = if (env.cache) |c| try c.acquire() else try env.allocator.create(Task);
    errdefer {
        if (env.cache) |c| c.release(t) else env.allocator.destroy(t);
    }

    const is_leaf = opts.mode == .leaf;
    var stack: stack_mod.Stack = .{};
    var use_pool = false;

    if (!is_leaf) {
        const use_direct = opts.guard_page or opts.paint_canary or env.pool == null;
        stack = if (!use_direct)
            try env.pool.?.acquire(stack_mod.fiber_stack_size)
        else
            try stack_mod.allocWith(env.allocator, stack_mod.fiber_stack_size, .{
                .guard_page = opts.guard_page,
                .paint_canary = opts.paint_canary,
            });
        use_pool = !use_direct;
        errdefer {
            if (use_pool) env.pool.?.release(stack) else stack_mod.free(env.allocator, stack);
        }
    }

    const slot = try env.allocator.create(Slot);
    errdefer env.allocator.destroy(slot);
    slot.* = .{};

    const wrapper = try env.allocator.create(Wrapper);
    errdefer env.allocator.destroy(wrapper);
    wrapper.* = .{ .args = args, .slot = slot };

    const gen = t.generation;
    t.* = .{
        .id = TaskId.next(),
        .generation = gen,
        .state = .blocked,
        .stack = stack,
        .name = opts.name,
        .priority = opts.priority,
        .mode = if (is_leaf) .leaf else .stackful,
        .allocator = env.allocator,
        .executor = env.executor,
        .stack_pool = if (use_pool) env.pool else null,
        .task_cache = env.cache,
        .entry_fn = Wrapper.entry,
        .user_data = wrapper,
        .result_slot = slot,
        .result_deinit = struct {
            fn d(p: *anyopaque, a: std.mem.Allocator) void {
                const s: *Slot = @ptrCast(@alignCast(p));
                a.destroy(s);
            }
        }.d,
        .on_cpu = .init(false),
        .finished = .init(false),
        .scheduled = .init(false),
        .join_waiters = .{},
        .join_lock = .{},
    };

    if (!is_leaf) {
        context_mod.make(&t.ctx, t.stack.bytes(), taskTrampoline, t);
    } else {
        t.ctx = .{};
    }
    try env.executor.enqueue(t);

    return .{
        .raw = .{ .task = t, .generation = gen },
        .slot = slot,
        .allocator = env.allocator,
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
    if (t.isLeaf()) {
        @panic("zigroutines: yield() in leaf task — use stackful spawn (or smaller stack) for cooperative yield");
    }
    const ex = t.executor orelse @panic("zigroutines: yield() without executor");
    ex.yieldFromRunning();
}

pub fn requireStackfulForPark() void {
    const t = current() orelse return;
    if (t.isLeaf()) {
        @panic("zigroutines: park in leaf task — leaf tasks must run to completion; use stackful spawn for channels/timers/I/O");
    }
}

pub fn callOnWorkerStack(comptime func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) CallReturn(@TypeOf(func)) {
    const me = current() orelse return @call(.auto, func, args);
    if (me.isLeaf()) return @call(.auto, func, args);
    const ex = me.executor orelse return @call(.auto, func, args);

    const Ret = CallReturn(@TypeOf(func));
    const Frame = struct {
        args: std.meta.ArgsTuple(@TypeOf(func)),
        result: Ret = undefined,
        fn run(ptr: *anyopaque) void {
            const f: *@This() = @ptrCast(@alignCast(ptr));
            f.result = @call(.auto, func, f.args);
        }
    };
    var frame: Frame = .{ .args = args };
    me.bounce_fn = Frame.run;
    me.bounce_arg = &frame;
    ex.parkFromRunning(.worker_bounce);
    return frame.result;
}

pub fn CallReturn(comptime Func: type) type {
    const info = @typeInfo(Func);
    const fn_info = switch (info) {
        .@"fn" => |f| f,
        else => @compileError("callOnWorkerStack expects a function"),
    };
    return fn_info.return_type orelse void;
}

pub fn takeBounceAndRun(t: *Task) bool {
    const bf = t.bounce_fn orelse return false;
    if (t.blocked_on != .worker_bounce) return false;
    const ba = t.bounce_arg;
    t.bounce_fn = null;
    t.bounce_arg = null;
    t.blocked_on = .none;
    if (ba) |arg| bf(arg);
    return true;
}
