const coro = @import("deps/zigcoro/src/coro.zig");
const executor = @import("deps/zigcoro/src/executor.zig");

pub const Error = coro.Error;
pub const StackT = coro.StackT;
pub const stack_alignment = coro.stack_alignment;
pub const default_stack_size = coro.default_stack_size;
pub const Frame = coro.Frame;
pub const FrameT = coro.FrameT;
pub const Env = coro.Env;
pub const initEnv = coro.initEnv;
pub const getEnv = coro.getEnv;
pub const xasync = coro.xasync;
pub const xawait = coro.xawait;
pub const xresume = coro.xresume;
pub const xsuspend = coro.xsuspend;
pub const xsuspendBlock = coro.xsuspendBlock;
pub const stackAlloc = coro.stackAlloc;
pub const inCoro = coro.inCoro;
pub const xframe = coro.xframe;

pub const Executor = executor.Executor;
pub const Channel = executor.Channel;
pub const ChannelConfig = executor.ChannelConfig;
