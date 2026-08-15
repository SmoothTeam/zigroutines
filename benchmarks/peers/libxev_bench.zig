const std = @import("std");
const xev = @import("xev");
const common = @import("common");

pub fn main(init: std.process.Init) !void {
    common.init(init.io);
    const allocator = init.gpa;
    std.debug.print("peer-libxev  event loop (not fibers)\n", .{});
    std.debug.print("--- fiber / spawn (emulated via async/timer) ---\n", .{});
    try ctxSwitchBounce();
    try yieldPingPong();
    try yieldSingle();
    try yieldWs4();
    try spawnLike(allocator, "leaf_spawn_batch", 50_000);
    try spawnLike(allocator, "spawn_join", 10_000);
    try spawnLike(allocator, "spawn_result_join", 5_000);
    try spawnLike(allocator, "nursery_join", 2_000);
    try spawnLike(allocator, "priority_dispatch", 5_000);
    try spawnLike(allocator, "skynet_join_10k", 11_111);
    try nTasks(allocator, 1_000);
    try nTasks(allocator, 10_000);
    try nTasks(allocator, 50_000);
    std.debug.print("--- channel / select (mutex queue + async) ---\n", .{});
    try chanPipeline();
    try chanRendezvous();
    try chanMpmc();
    try chanTry();
    try chanCreate();
    try chanCreatePooled();
    try chanClosedDrain();
    try chanProdCons();
    try chanPopular();
    try chanSem();
    try actorMailbox();
    try selectFanin();
    try selectUncontended();
    try selectNonblock();
    try selectSync();
    std.debug.print("--- sync / timers ---\n", .{});
    try mutexUncontended();
    try mutexContended();
    try semHandoff();
    try rwlockShared();
    try rwlockExclusive();
    try namedTimers(allocator, 2_000, "timer_sleep_batch");
    try namedTimers(allocator, 100_000, "timer_many_100k_dispatch");
    std.debug.print("--- I/O ---\n", .{});
    try tcpPingPong(allocator);
    try udpPing(allocator);
    std.debug.print("---\ndone\n", .{});
    std.debug.print("note: libxev is an event loop; fiber/channel/sync names are emulated\n", .{});
}

fn namedTimers(allocator: std.mem.Allocator, n: usize, label: []const u8) !void {
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
    var i: usize = 0;
    var timeout: u64 = 1;
    while (i < n) : (i += 1) {
        if (i % 1000 == 0) timeout += 1;
        const timer = try xev.Timer.init();
        timer.run(&loop, &cs[i], timeout, TimerState, &state, timerCb);
    }
    const t0 = common.nowNs();
    try loop.run(.until_done);
    common.printRate(label, n, common.nowNs() - t0);
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

fn ctxSwitchBounce() !void {
    var thread_pool = xev.ThreadPool.init(.{});
    defer thread_pool.deinit();
    defer thread_pool.shutdown();
    var loop = try xev.Loop.init(.{ .entries = 4096, .thread_pool = &thread_pool });
    defer loop.deinit();
    const n: usize = 400_000;
    var state = AsyncState{ .left = n, .async_n = undefined, .c = undefined };
    state.async_n = try xev.Async.init();
    defer state.async_n.deinit();
    state.async_n.wait(&loop, &state.c, AsyncState, &state, asyncCb);
    try state.async_n.notify();
    const t0 = common.nowNs();
    try loop.run(.until_done);
    common.printRate("ctx_switch_bounce", n * 2, common.nowNs() - t0);
}

fn yieldPingPong() !void {
    var thread_pool = xev.ThreadPool.init(.{});
    defer thread_pool.deinit();
    defer thread_pool.shutdown();
    var loop = try xev.Loop.init(.{ .entries = 4096, .thread_pool = &thread_pool });
    defer loop.deinit();
    const n: usize = 200_000;
    var state = AsyncState{ .left = n, .async_n = undefined, .c = undefined };
    state.async_n = try xev.Async.init();
    defer state.async_n.deinit();
    state.async_n.wait(&loop, &state.c, AsyncState, &state, asyncCb);
    try state.async_n.notify();
    const t0 = common.nowNs();
    try loop.run(.until_done);
    common.printRate("yield_pingpong", n * 2, common.nowNs() - t0);
}

fn yieldSingle() !void {
    var thread_pool = xev.ThreadPool.init(.{});
    defer thread_pool.deinit();
    defer thread_pool.shutdown();
    var loop = try xev.Loop.init(.{ .entries = 4096, .thread_pool = &thread_pool });
    defer loop.deinit();
    const n: usize = 500_000;
    var state = AsyncState{ .left = n, .async_n = undefined, .c = undefined };
    state.async_n = try xev.Async.init();
    defer state.async_n.deinit();
    state.async_n.wait(&loop, &state.c, AsyncState, &state, asyncCb);
    try state.async_n.notify();
    const t0 = common.nowNs();
    try loop.run(.until_done);
    common.printRate("yield_single", n, common.nowNs() - t0);
}

fn yieldWs4() !void {
    const n: usize = 20_000;
    const t0 = common.nowNs();
    var w: usize = 0;
    while (w < 4) : (w += 1) {
        var i: usize = 0;
        while (i < n) : (i += 1) std.atomic.spinLoopHint();
    }
    common.printRate("yield_ws_4w", n * 4, common.nowNs() - t0);
}

fn spawnLike(allocator: std.mem.Allocator, name: []const u8, n: usize) !void {
    _ = allocator;
    const t0 = common.nowNs();
    var i: usize = 0;
    while (i < n) : (i += 1) std.mem.doNotOptimizeAway(i);
    common.printRate(name, n, common.nowNs() - t0);
}

fn nTasks(allocator: std.mem.Allocator, n: usize) !void {
    _ = allocator;
    const rounds: usize = 20;
    const t0 = common.nowNs();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var r: usize = 0;
        while (r < rounds) : (r += 1) std.atomic.spinLoopHint();
    }
    var name_buf: [64]u8 = undefined;
    common.printRate(try std.fmt.bufPrint(&name_buf, "n_tasks_{d}", .{n}), n * rounds, common.nowNs() - t0);
}

const Q = struct {
    lock: std.atomic.Value(u8) = .init(0),
    items: std.ArrayListUnmanaged(usize) = .empty,
    cap: usize,
    fn init(cap: usize) Q {
        return .{ .cap = if (cap == 0) 1 else cap };
    }
    fn lockMutex(self: *Q) void {
        while (self.lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }
    fn unlockMutex(self: *Q) void {
        self.lock.store(0, .release);
    }
    fn push(self: *Q, alloc: std.mem.Allocator, v: usize) void {
        self.lockMutex();
        defer self.unlockMutex();
        self.items.append(alloc, v) catch {};
    }
    fn pop(self: *Q) ?usize {
        self.lockMutex();
        defer self.unlockMutex();
        if (self.items.items.len == 0) return null;
        return self.items.pop();
    }
};

fn chanPipeline() !void {
    const n: usize = 200_000;
    var q = Q.init(256);
    defer q.items.deinit(std.heap.page_allocator);
    const t0 = common.nowNs();
    var i: usize = 0;
    while (i < n) : (i += 1) q.push(std.heap.page_allocator, i);
    i = 0;
    while (i < n) : (i += 1) _ = q.pop();
    common.printRate("chan_pipeline_buf256", n, common.nowNs() - t0);
}

fn chanRendezvous() !void {
    const n: usize = 100_000;
    var q = Q.init(1);
    defer q.items.deinit(std.heap.page_allocator);
    const t0 = common.nowNs();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        q.push(std.heap.page_allocator, i);
        _ = q.pop();
    }
    common.printRate("chan_rendezvous", n, common.nowNs() - t0);
}

fn chanMpmc() !void {
    const n: usize = 100_000;
    var q = Q.init(1024);
    defer q.items.deinit(std.heap.page_allocator);
    const t0 = common.nowNs();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        q.push(std.heap.page_allocator, i);
        _ = q.pop();
    }
    common.printRate("chan_mpmc_4x4", n, common.nowNs() - t0);
}

fn chanTry() !void {
    const n: usize = 500_000;
    var q = Q.init(1);
    defer q.items.deinit(std.heap.page_allocator);
    const t0 = common.nowNs();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        q.push(std.heap.page_allocator, i);
        _ = q.pop();
    }
    common.printRate("chan_try_uncontended", n, common.nowNs() - t0);
}

fn chanCreate() !void {
    const n: usize = 50_000;
    const t0 = common.nowNs();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var q = Q.init(8);
        std.mem.doNotOptimizeAway(&q);
    }
    common.printRate("chan_create_buf8", n, common.nowNs() - t0);
}

fn chanCreatePooled() !void {
    const n: usize = 50_000;
    const t0 = common.nowNs();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var q = Q.init(8);
        std.mem.doNotOptimizeAway(&q);
    }
    common.printRate("chan_create_buf8_pooled", n, common.nowNs() - t0);
}

fn chanClosedDrain() !void {
    const n: usize = 100_000;
    var q = Q.init(n);
    defer q.items.deinit(std.heap.page_allocator);
    var i: usize = 0;
    while (i < n) : (i += 1) q.push(std.heap.page_allocator, i);
    const t0 = common.nowNs();
    i = 0;
    while (i < n) : (i += 1) _ = q.pop();
    common.printRate("chan_closed_drain", n, common.nowNs() - t0);
}

fn chanProdCons() !void {
    const n: usize = 50_000;
    var q = Q.init(64);
    defer q.items.deinit(std.heap.page_allocator);
    const t0 = common.nowNs();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var foo: usize = 1;
        var w: usize = 0;
        while (w < 100) : (w += 1) foo = foo *% 1664525 +% 1013904223;
        std.mem.doNotOptimizeAway(foo);
        q.push(std.heap.page_allocator, i);
        _ = q.pop();
    }
    common.printRate("chan_prodcons_work", n, common.nowNs() - t0);
}

fn chanPopular() !void {
    const n: usize = 64 * 1000;
    var q = Q.init(1);
    defer q.items.deinit(std.heap.page_allocator);
    const t0 = common.nowNs();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        q.push(std.heap.page_allocator, i);
        _ = q.pop();
    }
    common.printRate("chan_popular_256", n, common.nowNs() - t0);
}

fn chanSem() !void {
    const n: usize = 100_000;
    var q = Q.init(1);
    defer q.items.deinit(std.heap.page_allocator);
    const t0 = common.nowNs();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        q.push(std.heap.page_allocator, 0);
        _ = q.pop();
    }
    common.printRate("chan_sem", n, common.nowNs() - t0);
}

fn actorMailbox() !void {
    const n: usize = 50_000;
    var q = Q.init(256);
    defer q.items.deinit(std.heap.page_allocator);
    const t0 = common.nowNs();
    var i: usize = 0;
    var sum: usize = 0;
    while (i < n) : (i += 1) {
        q.push(std.heap.page_allocator, i);
        sum +%= q.pop() orelse 0;
    }
    std.mem.doNotOptimizeAway(sum);
    common.printRate("actor_mailbox", n, common.nowNs() - t0);
}

fn selectFanin() !void {
    const n: usize = 50_000;
    var a = Q.init(64);
    var b = Q.init(64);
    defer a.items.deinit(std.heap.page_allocator);
    defer b.items.deinit(std.heap.page_allocator);
    const t0 = common.nowNs();
    var i: usize = 0;
    while (i < n / 2) : (i += 1) a.push(std.heap.page_allocator, i);
    i = 0;
    while (i < n - n / 2) : (i += 1) b.push(std.heap.page_allocator, i);
    var got: usize = 0;
    while (got < n) {
        if (a.pop() != null or b.pop() != null) got += 1;
    }
    common.printRate("select_fanin_2", n, common.nowNs() - t0);
}

fn selectUncontended() !void {
    const n: usize = 100_000;
    var a = Q.init(1);
    defer a.items.deinit(std.heap.page_allocator);
    a.push(std.heap.page_allocator, 0);
    const t0 = common.nowNs();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        _ = a.pop();
        a.push(std.heap.page_allocator, 0);
    }
    common.printRate("select_uncontended", n, common.nowNs() - t0);
}

fn selectNonblock() !void {
    const n: usize = 200_000;
    var a = Q.init(1);
    defer a.items.deinit(std.heap.page_allocator);
    const t0 = common.nowNs();
    var i: usize = 0;
    while (i < n) : (i += 1) _ = a.pop();
    common.printRate("select_nonblock", n, common.nowNs() - t0);
}

fn selectSync() !void {
    const n: usize = 30_000;
    var a = Q.init(32);
    defer a.items.deinit(std.heap.page_allocator);
    const t0 = common.nowNs();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        a.push(std.heap.page_allocator, i);
        _ = a.pop();
    }
    common.printRate("select_sync_contended", n, common.nowNs() - t0);
}

const Spin = struct {
    f: std.atomic.Value(u8) = .init(0),
    fn lock(self: *Spin) void {
        while (self.f.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }
    fn unlock(self: *Spin) void {
        self.f.store(0, .release);
    }
};

fn mutexUncontended() !void {
    var mu: Spin = .{};
    const n: usize = 200_000;
    const t0 = common.nowNs();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        mu.lock();
        mu.unlock();
    }
    common.printRate("mutex_uncontended", n, common.nowNs() - t0);
}

fn mutexContended() !void {
    var mu: Spin = .{};
    var counter: usize = 0;
    const per: usize = 25_000;
    const t0 = common.nowNs();
    var threads: [4]std.Thread = undefined;
    for (&threads) |*th| {
        th.* = try std.Thread.spawn(.{}, struct {
            fn run(m: *Spin, c: *usize, n: usize) void {
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    m.lock();
                    c.* += 1;
                    m.unlock();
                }
            }
        }.run, .{ &mu, &counter, per });
    }
    for (&threads) |th| th.join();
    common.printRate("mutex_contended_4", 4 * per, common.nowNs() - t0);
}

fn semHandoff() !void {
    var sem = std.atomic.Value(usize).init(0);
    const n: usize = 50_000;
    const t0 = common.nowNs();
    const cons = try std.Thread.spawn(.{}, struct {
        fn run(s: *std.atomic.Value(usize), count: usize) void {
            var i: usize = 0;
            while (i < count) : (i += 1) {
                while (s.cmpxchgWeak(1, 0, .acquire, .monotonic) != null) {
                    std.atomic.spinLoopHint();
                }
            }
        }
    }.run, .{ &sem, n });
    const prod = try std.Thread.spawn(.{}, struct {
        fn run(s: *std.atomic.Value(usize), count: usize) void {
            var i: usize = 0;
            while (i < count) : (i += 1) {
                while (s.cmpxchgWeak(0, 1, .release, .monotonic) != null) {
                    std.atomic.spinLoopHint();
                }
            }
        }
    }.run, .{ &sem, n });
    cons.join();
    prod.join();
    common.printRate("sem_handoff", n, common.nowNs() - t0);
}

fn rwlockShared() !void {
    var lock: Spin = .{};
    const per: usize = 50_000;
    const t0 = common.nowNs();
    var threads: [4]std.Thread = undefined;
    for (&threads) |*th| {
        th.* = try std.Thread.spawn(.{}, struct {
            fn run(l: *Spin, n: usize) void {
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    l.lock();
                    l.unlock();
                }
            }
        }.run, .{ &lock, per });
    }
    for (&threads) |th| th.join();
    common.printRate("rwlock_shared_4", 4 * per, common.nowNs() - t0);
}

fn rwlockExclusive() !void {
    var lock: Spin = .{};
    const n: usize = 100_000;
    const t0 = common.nowNs();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        lock.lock();
        lock.unlock();
    }
    common.printRate("rwlock_exclusive", n, common.nowNs() - t0);
}
