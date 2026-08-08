const std = @import("std");
const xev = @import("xev");
const common = @import("common");

pub fn main(init: std.process.Init) !void {
    common.init(init.io);
    const allocator = init.gpa;
    std.debug.print("peer-libxev  zig=0.16  (event loop)\n", .{});
    std.debug.print("--- timers ---\n", .{});
    try millionTimers(allocator, 100_000);
    std.debug.print("--- async ---\n", .{});
    try asyncPummel();
    std.debug.print("--- I/O ---\n", .{});
    try tcpPingPong(allocator);
    try udpPing(allocator);
    std.debug.print("---\ndone\n", .{});
    std.debug.print(
        \\skipped: timer_many_1M (slow)
        \\n/a: fiber yield/spawn/n_tasks, channel/select/actor,
        \\  mutex/sem/rwlock (fiber sync), nursery/skynet/priority
        \\
    , .{});
}

fn millionTimers(allocator: std.mem.Allocator, n: usize) !void {
    var thread_pool = xev.ThreadPool.init(.{});
    defer thread_pool.deinit();
    defer thread_pool.shutdown();

    var loop = try xev.Loop.init(.{
        .entries = std.math.pow(u13, 2, 12),
        .thread_pool = &thread_pool,
    });
    defer loop.deinit();

    var cs = try allocator.alloc(xev.Completion, n);
    defer allocator.free(cs);
    var state = TimerState{ .remaining = n };

    const t_init0 = common.nowNs();
    var i: usize = 0;
    var timeout: u64 = 1;
    while (i < n) : (i += 1) {
        if (i % 1000 == 0) timeout += 1;
        const timer = try xev.Timer.init();
        timer.run(&loop, &cs[i], timeout, TimerState, &state, timerCb);
    }
    const t_init1 = common.nowNs();

    const t_run0 = common.nowNs();
    try loop.run(.until_done);
    const t_run1 = common.nowNs();

    var name_buf: [64]u8 = undefined;
    common.printRate(try std.fmt.bufPrint(&name_buf, "timer_many_{d}_spawn", .{n}), n, t_init1 - t_init0);
    common.printRate(try std.fmt.bufPrint(&name_buf, "timer_many_{d}_dispatch", .{n}), n, t_run1 - t_run0);
}

const TimerState = struct { remaining: usize };

fn timerCb(ud: ?*TimerState, _: *xev.Loop, _: *xev.Completion, result: xev.Timer.RunError!void) xev.CallbackAction {
    _ = result catch unreachable;
    if (ud) |s| {
        if (s.remaining > 0) s.remaining -= 1;
    }
    return .disarm;
}

fn asyncPummel() !void {
    var thread_pool = xev.ThreadPool.init(.{});
    defer thread_pool.deinit();
    defer thread_pool.shutdown();

    var loop = try xev.Loop.init(.{
        .entries = std.math.pow(u13, 2, 12),
        .thread_pool = &thread_pool,
    });
    defer loop.deinit();

    const n: usize = 200_000;
    var state = AsyncState{ .left = n, .async_n = undefined, .c = undefined };
    state.async_n = try xev.Async.init();
    defer state.async_n.deinit();
    state.async_n.wait(&loop, &state.c, AsyncState, &state, asyncCb);
    try state.async_n.notify();

    const t0 = common.nowNs();
    try loop.run(.until_done);
    const t1 = common.nowNs();
    common.printRate("async_notify_pummel", n, t1 - t0);
}

const AsyncState = struct {
    left: usize,
    async_n: xev.Async,
    c: xev.Completion,
};

fn asyncCb(ud: ?*AsyncState, loop: *xev.Loop, c: *xev.Completion, result: xev.Async.WaitError!void) xev.CallbackAction {
    _ = result catch unreachable;
    const s = ud.?;
    if (s.left == 0) return .disarm;
    s.left -= 1;
    if (s.left == 0) return .disarm;
    s.async_n.wait(loop, c, AsyncState, s, asyncCb);
    s.async_n.notify() catch {};
    return .disarm;
}

const tcp_rounds: usize = 20_000;
const TCP_PORT: u16 = 38471;

fn tcpPingPong(allocator: std.mem.Allocator) !void {
    var thread_pool = xev.ThreadPool.init(.{});
    defer thread_pool.deinit();
    defer thread_pool.shutdown();

    var server_loop = try xev.Loop.init(.{
        .entries = std.math.pow(u13, 2, 12),
        .thread_pool = &thread_pool,
    });
    defer server_loop.deinit();

    var client_loop = try xev.Loop.init(.{
        .entries = std.math.pow(u13, 2, 12),
        .thread_pool = &thread_pool,
    });
    defer client_loop.deinit();

    var server = try TcpServer.init(allocator, &server_loop);
    defer server.deinit();
    try server.start();
    const thr = try std.Thread.spawn(.{}, TcpServer.threadMain, .{&server});

    var client = try TcpClient.init(allocator, &client_loop);
    defer client.deinit();
    try client.start();

    const t0 = common.nowNs();
    try client_loop.run(.until_done);
    thr.join();
    const t1 = common.nowNs();
    common.printRate("tcp_pingpong", client.pongs, t1 - t0);
    common.printThroughput("tcp_pingpong_rps", client.pongs, t1 - t0, "RT");
}

const BufferPool = std.heap.MemoryPool([256]u8);
const CompletionPool = std.heap.MemoryPool(xev.Completion);
const TCPPool = std.heap.MemoryPool(xev.TCP);

const TcpClient = struct {
    loop: *xev.Loop,
    alloc: std.mem.Allocator,
    completion_pool: CompletionPool = .empty,
    read_buf: [64]u8 = undefined,
    pongs: u64 = 0,
    const PING = "P";

    fn init(alloc: std.mem.Allocator, loop: *xev.Loop) !TcpClient {
        return .{ .loop = loop, .alloc = alloc };
    }
    fn deinit(self: *TcpClient) void {
        self.completion_pool.deinit(self.alloc);
    }
    fn start(self: *TcpClient) !void {
        const addr = try std.Io.net.IpAddress.parse("127.0.0.1", TCP_PORT);
        const socket = try xev.TCP.init(addr);
        const c = try self.completion_pool.create(self.alloc);
        socket.connect(self.loop, c, addr, TcpClient, self, clientConnect);
    }
    fn clientConnect(self_: ?*TcpClient, l: *xev.Loop, c: *xev.Completion, socket: xev.TCP, r: xev.ConnectError!void) xev.CallbackAction {
        _ = r catch unreachable;
        const self = self_.?;
        socket.write(l, c, .{ .slice = PING }, TcpClient, self, clientWrite);
        const c_read = self.completion_pool.create(self.alloc) catch unreachable;
        socket.read(l, c_read, .{ .slice = &self.read_buf }, TcpClient, self, clientRead);
        return .disarm;
    }
    fn clientWrite(self_: ?*TcpClient, l: *xev.Loop, c: *xev.Completion, s: xev.TCP, b: xev.WriteBuffer, r: xev.WriteError!usize) xev.CallbackAction {
        _ = l;
        _ = s;
        _ = b;
        _ = r catch unreachable;
        self_.?.completion_pool.destroy(c);
        return .disarm;
    }
    fn clientRead(self_: ?*TcpClient, l: *xev.Loop, c: *xev.Completion, socket: xev.TCP, buf: xev.ReadBuffer, r: xev.ReadError!usize) xev.CallbackAction {
        const self = self_.?;
        _ = r catch unreachable;
        _ = buf;
        self.pongs += 1;
        if (self.pongs >= tcp_rounds) {
            socket.shutdown(l, c, TcpClient, self, clientShutdown);
            return .disarm;
        }
        const c_ping = self.completion_pool.create(self.alloc) catch unreachable;
        socket.write(l, c_ping, .{ .slice = PING }, TcpClient, self, clientWrite);
        return .rearm;
    }
    fn clientShutdown(self_: ?*TcpClient, l: *xev.Loop, c: *xev.Completion, socket: xev.TCP, r: xev.ShutdownError!void) xev.CallbackAction {
        _ = r catch {};
        socket.close(l, c, TcpClient, self_.?, clientClose);
        return .disarm;
    }
    fn clientClose(self_: ?*TcpClient, l: *xev.Loop, c: *xev.Completion, socket: xev.TCP, r: xev.CloseError!void) xev.CallbackAction {
        _ = l;
        _ = socket;
        _ = r catch {};
        self_.?.completion_pool.destroy(c);
        return .disarm;
    }
};

const TcpServer = struct {
    loop: *xev.Loop,
    alloc: std.mem.Allocator,
    buffer_pool: BufferPool = .empty,
    completion_pool: CompletionPool = .empty,
    socket_pool: TCPPool = .empty,

    fn init(alloc: std.mem.Allocator, loop: *xev.Loop) !TcpServer {
        return .{ .loop = loop, .alloc = alloc };
    }
    fn deinit(self: *TcpServer) void {
        self.buffer_pool.deinit(self.alloc);
        self.completion_pool.deinit(self.alloc);
        self.socket_pool.deinit(self.alloc);
    }
    fn start(self: *TcpServer) !void {
        const addr = try std.Io.net.IpAddress.parse("127.0.0.1", TCP_PORT);
        var socket = try xev.TCP.init(addr);
        const c = try self.completion_pool.create(self.alloc);
        try socket.bind(addr);
        try socket.listen(128);
        socket.accept(self.loop, c, TcpServer, self, serverAccept);
    }
    fn threadMain(self: *TcpServer) !void {
        try self.loop.run(.until_done);
    }
    fn serverAccept(self_: ?*TcpServer, l: *xev.Loop, c: *xev.Completion, r: xev.AcceptError!xev.TCP) xev.CallbackAction {
        const self = self_.?;
        const sock = self.socket_pool.create(self.alloc) catch unreachable;
        sock.* = r catch unreachable;
        const buf = self.buffer_pool.create(self.alloc) catch unreachable;
        sock.read(l, c, .{ .slice = buf }, TcpServer, self, serverRead);
        return .disarm;
    }
    fn serverRead(self_: ?*TcpServer, loop: *xev.Loop, c: *xev.Completion, socket: xev.TCP, buf: xev.ReadBuffer, r: xev.ReadError!usize) xev.CallbackAction {
        const self = self_.?;
        const n = r catch |err| switch (err) {
            error.EOF => {
                self.buffer_pool.destroy(@alignCast(@as(*[256]u8, @ptrFromInt(@intFromPtr(buf.slice.ptr)))));
                socket.shutdown(loop, c, TcpServer, self, serverShutdown);
                return .disarm;
            },
            else => {
                self.buffer_pool.destroy(@alignCast(@as(*[256]u8, @ptrFromInt(@intFromPtr(buf.slice.ptr)))));
                self.completion_pool.destroy(c);
                return .disarm;
            },
        };
        const c_w = self.completion_pool.create(self.alloc) catch unreachable;
        const out = self.buffer_pool.create(self.alloc) catch unreachable;
        @memcpy(out[0..n], buf.slice[0..n]);
        socket.write(loop, c_w, .{ .slice = out[0..n] }, TcpServer, self, serverWrite);
        return .rearm;
    }
    fn serverWrite(self_: ?*TcpServer, l: *xev.Loop, c: *xev.Completion, s: xev.TCP, buf: xev.WriteBuffer, r: xev.WriteError!usize) xev.CallbackAction {
        _ = l;
        _ = s;
        _ = r catch {};
        const self = self_.?;
        self.completion_pool.destroy(c);
        self.buffer_pool.destroy(@alignCast(@as(*[256]u8, @ptrFromInt(@intFromPtr(buf.slice.ptr)))));
        return .disarm;
    }
    fn serverShutdown(self_: ?*TcpServer, l: *xev.Loop, c: *xev.Completion, s: xev.TCP, r: xev.ShutdownError!void) xev.CallbackAction {
        _ = r catch {};
        s.close(l, c, TcpServer, self_.?, serverClose);
        return .disarm;
    }
    fn serverClose(self_: ?*TcpServer, l: *xev.Loop, c: *xev.Completion, socket: xev.TCP, r: xev.CloseError!void) xev.CallbackAction {
        _ = l;
        _ = socket;
        _ = r catch {};
        self_.?.completion_pool.destroy(c);
        return .disarm;
    }
};

const udp_rounds: usize = 20_000;
const UDP_PORT: u16 = 38472;

fn udpPing(allocator: std.mem.Allocator) !void {
    _ = allocator;
    var thread_pool = xev.ThreadPool.init(.{});
    defer thread_pool.deinit();
    defer thread_pool.shutdown();

    var loop = try xev.Loop.init(.{
        .entries = std.math.pow(u13, 2, 12),
        .thread_pool = &thread_pool,
    });
    defer loop.deinit();

    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", UDP_PORT);
    var p = try UdpPinger.init(addr);
    try p.start(&loop);

    const t0 = common.nowNs();
    try loop.run(.until_done);
    const t1 = common.nowNs();
    common.printRate("udp_ping", p.pongs, t1 - t0);
    common.printThroughput("udp_ping_pps", p.pongs, t1 - t0, "pkt");
}

const UdpPinger = struct {
    udp: xev.UDP,
    addr: std.Io.net.IpAddress,
    pongs: u64 = 0,
    op_count: u8 = 0,
    read_buf: [64]u8 = undefined,
    c_read: xev.Completion = undefined,
    c_write: xev.Completion = undefined,
    state_read: xev.UDP.State = undefined,
    state_write: xev.UDP.State = undefined,
    const PING = "U";

    fn init(addr: std.Io.net.IpAddress) !UdpPinger {
        return .{ .udp = try xev.UDP.init(addr), .addr = addr };
    }
    fn start(self: *UdpPinger, loop: *xev.Loop) !void {
        try self.udp.bind(self.addr);
        self.udp.read(loop, &self.c_read, &self.state_read, .{ .slice = &self.read_buf }, UdpPinger, self, udpRead);
        self.write(loop);
    }
    fn write(self: *UdpPinger, loop: *xev.Loop) void {
        self.udp.write(loop, &self.c_write, &self.state_write, self.addr, .{ .slice = PING }, UdpPinger, self, udpWrite);
    }
    fn maybeWrite(self: *UdpPinger, loop: *xev.Loop) void {
        self.op_count += 1;
        if (self.op_count == 2) {
            self.op_count = 0;
            self.write(loop);
        }
    }
    fn udpRead(self_: ?*UdpPinger, loop: *xev.Loop, c: *xev.Completion, _: *xev.UDP.State, _: std.Io.net.IpAddress, socket: xev.UDP, buf: xev.ReadBuffer, r: xev.ReadError!usize) xev.CallbackAction {
        _ = c;
        _ = socket;
        _ = buf;
        const self = self_.?;
        _ = r catch unreachable;
        self.pongs += 1;
        if (self.pongs >= udp_rounds) {
            self.udp.close(loop, &self.c_read, UdpPinger, self, udpClose);
            return .disarm;
        }
        self.maybeWrite(loop);
        return .rearm;
    }
    fn udpWrite(self_: ?*UdpPinger, loop: *xev.Loop, c: *xev.Completion, s: *xev.UDP.State, socket: xev.UDP, b: xev.WriteBuffer, r: xev.WriteError!usize) xev.CallbackAction {
        _ = c;
        _ = s;
        _ = socket;
        _ = b;
        _ = r catch unreachable;
        self_.?.maybeWrite(loop);
        return .disarm;
    }
    fn udpClose(_: ?*UdpPinger, _: *xev.Loop, _: *xev.Completion, _: xev.UDP, r: xev.CloseError!void) xev.CallbackAction {
        _ = r catch {};
        return .disarm;
    }
};
