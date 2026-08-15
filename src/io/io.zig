// SPDX-FileCopyrightText: 2026 Apanazar
//
// SPDX-License-Identifier: LGPL-3.0-or-later

const std = @import("std");
const runtime_mod = @import("../core/runtime.zig");
const task_mod = @import("../core/task.zig");

pub const adapter = @import("std_io_adapter.zig");
pub const future_state = @import("async_future.zig");
pub const backend = @import("io_backend.zig");
pub const reactor = @import("poll_reactor.zig");
pub const mock = @import("mock_backend.zig");
pub const net = @import("network.zig");
pub const iocp = @import("iocp_backend.zig");
pub const iouring = @import("io_uring_backend.zig");

pub const IoAdapter = adapter.IoAdapter;
pub const Backend = backend.Backend;
pub const Handle = backend.Handle;
pub const Interest = backend.Interest;
pub const Reactor = reactor.Reactor;
pub const MockBackend = mock.MockBackend;
pub const TcpListener = net.TcpListener;
pub const TcpStream = net.TcpStream;
pub const IocpBackend = iocp.IocpBackend;
pub const IoUringBackend = iouring.IoUringBackend;

pub const UdpSocket = net.UdpSocket;
pub const Ipv4 = net.Ipv4;
pub const BindOpts = net.BindOpts;

pub fn asyncCall(
    runtime: *runtime_mod.Runtime,
    comptime func: anytype,
    args: std.meta.ArgsTuple(@TypeOf(func)),
) !task_mod.JoinHandle {
    return runtime.spawn(.{}, func, args);
}
