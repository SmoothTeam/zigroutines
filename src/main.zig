const std = @import("std");

pub const version = Version{
    .major = 0,
    .minor = 10,
    .patch = 0,
    .phase = .pre_1_0,
};

pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,
    phase: Phase,

    pub const Phase = enum {
        scaffold,
        context,
        single_thread,
        multi_thread,
        mvp,
        io_ready,
        polish,
        standards,
        io_complete,
        pre_1_0,
    };

    pub fn format(self: Version, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{d}.{d}.{d}-{s}", .{
            self.major,
            self.minor,
            self.patch,
            @tagName(self.phase),
        });
    }
};

pub const stack = @import("stack/stack.zig");
pub const context = @import("context/context.zig");
pub const task = @import("core/task.zig");
pub const runtime = @import("core/runtime.zig");
pub const executor = @import("core/executor.zig");
pub const cancellation = @import("core/cancellation.zig");
pub const synchronization = @import("core/synchronization.zig");
pub const timer_queue = @import("core/timer_queue.zig");
pub const structured_concurrency = @import("core/structured_concurrency.zig");
pub const metrics = @import("core/metrics.zig");
pub const preemption = @import("core/preemption.zig");
pub const tracing = @import("core/tracing.zig");
pub const scheduler = @import("scheduler/scheduler.zig");
pub const channel = @import("csp/channel.zig");
pub const select = @import("csp/select.zig");
pub const io = @import("io/io.zig");
pub const actors = @import("actors/actor.zig");
pub const utils = @import("utils/utils.zig");
pub const c_bindings = @import("abi/c_bindings.zig");

pub const cancel = cancellation;
pub const sync = synchronization;
pub const timer = timer_queue;
pub const scope = structured_concurrency;
pub const preempt = preemption;
pub const trace = tracing;
pub const c_api = c_bindings;

pub const Task = task.Task;
pub const Runtime = runtime.Runtime;
pub const Config = runtime.Config;
pub const SchedulerPolicy = runtime.SchedulerPolicy;
pub const CancelToken = cancellation.CancelToken;
pub const Channel = channel.Channel;
pub const ChannelError = channel.Error;
pub const ChannelFullPolicy = channel.FullPolicy;
pub const FullPolicy = channel.FullPolicy;
pub const ChannelOptions = channel.ChannelOptions;
pub const Context = context.Context;
pub const JoinHandle = task.JoinHandle;
pub const SpawnOptions = task.SpawnOptions;
pub const Executor = executor.Executor;
pub const Scope = structured_concurrency.Scope;
pub const Nursery = structured_concurrency.Nursery;
pub const NurseryOptions = structured_concurrency.NurseryOpts;
pub const NurseryOpts = structured_concurrency.NurseryOpts;
pub const TimerQueue = timer_queue.TimerQueue;
pub const Metrics = metrics.Metrics;
pub const IoAdapter = io.IoAdapter;
pub const IoBackend = io.Backend;
pub const PollReactor = io.Reactor;
pub const Reactor = io.Reactor;
pub const MockBackend = io.MockBackend;
pub const TcpListener = io.TcpListener;
pub const TcpStream = io.TcpStream;
pub const UdpSocket = io.UdpSocket;
pub const IocpBackend = io.IocpBackend;
pub const IoUringBackend = io.IoUringBackend;
pub const SpinLock = synchronization.SpinLock;
pub const Semaphore = synchronization.Semaphore;
pub const Mutex = synchronization.Mutex;
pub const RwLock = synchronization.RwLock;
pub const RateLimiter = synchronization.RateLimiter;
pub const ParkingLot = synchronization.ParkingLot;
pub const Actor = actors.Actor;

pub const yield = task.yield;
pub const current = task.current;
pub const currentTask = task.current;
pub const sleep = runtime.sleep;
pub const currentRuntime = runtime.currentRuntime;
pub const checkpoint = preemption.checkpoint;
pub const TypedJoinHandle = task.TypedJoinHandle;
pub const Ipv4 = io.Ipv4;
pub const BindOpts = io.BindOpts;
