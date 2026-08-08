const std = @import("std");
const builtin = @import("builtin");
const backend = @import("io_backend.zig");
const task_mod = @import("../core/task.zig");

const Handle = backend.Handle;
const Backend = backend.Backend;
const BackendError = backend.BackendError;
const is_windows = builtin.os.tag == .windows;

inline fn onWorker(comptime func: anytype, args: anytype) @TypeOf(@call(.auto, func, args)) {
    return task_mod.callOnWorkerStack(func, args);
}

pub const NetError = BackendError || error{
    AddressInUse,
    ConnectionRefused,
    NetworkUnreachable,
    WouldBlock,
};

pub const Ipv4 = struct {
    addr: u32,

    pub const loopback = Ipv4{ .addr = 0x7f000001 };
    pub const any = Ipv4{ .addr = 0 };

    pub fn fromOctets(a: u8, b: u8, c: u8, d: u8) Ipv4 {
        return .{ .addr = (@as(u32, a) << 24) | (@as(u32, b) << 16) | (@as(u32, c) << 8) | d };
    }
};

pub const BindOpts = struct {
    address: Ipv4 = .loopback,
    backlog: u31 = 128,
};

pub const TcpListener = struct {
    handle: Handle,
    io: Backend,
    bound_port: u16 = 0,
    bound_addr: Ipv4 = .loopback,

    pub fn bind(io: Backend, port: u16) NetError!TcpListener {
        return bindWith(io, port, .{});
    }

    pub fn bindWith(io: Backend, port: u16, opts: BindOpts) NetError!TcpListener {
        return onWorker(bindWithImpl, .{ io, port, opts });
    }

    fn bindWithImpl(io: Backend, port: u16, opts: BindOpts) NetError!TcpListener {
        const h = try createSocket();
        errdefer closeHandle(h);

        try setNonBlocking(h);
        try setReuseAddr(h);

        const host_addr = opts.address.addr;

        if (comptime is_windows) {
            try winBindAddr(h, port, host_addr, opts.backlog);
        } else {
            var sa: std.posix.sockaddr.in = .{
                .family = std.posix.AF.INET,
                .port = std.mem.nativeToBig(u16, port),
                .addr = std.mem.nativeToBig(u32, host_addr),
            };
            std.posix.bind(@intCast(h), @ptrCast(&sa), @sizeOf(@TypeOf(sa))) catch |err| switch (err) {
                error.AddressInUse => return error.AddressInUse,
                else => return error.Unexpected,
            };
            std.posix.listen(@intCast(h), opts.backlog) catch return error.Unexpected;
        }

        var actual = port;
        if (port == 0) {
            actual = getSockPort(h) catch port;
        }
        io.associate(h) catch {};
        return .{ .handle = h, .io = io, .bound_port = actual, .bound_addr = opts.address };
    }

    pub fn localPort(self: *const TcpListener) u16 {
        return self.bound_port;
    }

    pub fn close(self: *TcpListener) void {
        closeHandle(self.handle);
        self.handle = 0;
    }

    pub fn accept(self: *TcpListener) NetError!TcpStream {
        var spins: u32 = 0;
        while (true) {
            const client = onWorker(acceptOnce, .{self.handle}) catch |err| switch (err) {
                error.WouldBlock => {
                    if (spins < 64) {
                        spins += 1;
                        if (task_mod.current()) |_| {
                            task_mod.yield();
                        }
                        continue;
                    }
                    spins = 0;
                    try self.io.wait(self.handle, .read);
                    continue;
                },
                else => |e| return e,
            };
            try onWorker(setNonBlocking, .{client});
            self.io.associate(client) catch {};
            return .{ .handle = client, .io = self.io };
        }
    }
};

pub const TcpStream = struct {
    handle: Handle,
    io: Backend,

    pub fn connect(io: Backend, port: u16) NetError!TcpStream {
        return connectTo(io, .loopback, port);
    }

    pub fn connectTo(io: Backend, address: Ipv4, port: u16) NetError!TcpStream {
        const prep = try onWorker(connectPrep, .{ address.addr, port });
        errdefer closeHandle(prep.handle);
        if (prep.need_wait) {
            try io.wait(prep.handle, .write);
            try onWorker(checkConnectError, .{prep.handle});
        }
        io.associate(prep.handle) catch {};
        return .{ .handle = prep.handle, .io = io };
    }

    const ConnectPrep = struct { handle: Handle, need_wait: bool };

    fn connectPrep(host_addr: u32, port: u16) NetError!ConnectPrep {
        const h = try createSocket();
        errdefer closeHandle(h);
        try setNonBlocking(h);
        connectNonblockAddr(h, host_addr, port) catch |err| switch (err) {
            error.WouldBlock => return .{ .handle = h, .need_wait = true },
            else => |e| return e,
        };
        return .{ .handle = h, .need_wait = false };
    }

    pub fn close(self: *TcpStream) void {
        closeHandle(self.handle);
        self.handle = 0;
    }

    pub fn readExact(self: *TcpStream, buf: []u8) NetError!void {
        var off: usize = 0;
        while (off < buf.len) {
            const n = try self.read(buf[off..]);
            if (n == 0) return error.ConnectionReset;
            off += n;
        }
    }

    pub fn read(self: *TcpStream, buf: []u8) NetError!usize {
        while (true) {
            const n = onWorker(recvOnce, .{ self.handle, buf }) catch |err| switch (err) {
                error.WouldBlock => {
                    try self.io.wait(self.handle, .read);
                    continue;
                },
                else => |e| return e,
            };
            return n;
        }
    }

    pub fn writeAll(self: *TcpStream, data: []const u8) NetError!void {
        var sent: usize = 0;
        while (sent < data.len) {
            const n = onWorker(sendOnce, .{ self.handle, data[sent..] }) catch |err| switch (err) {
                error.WouldBlock => {
                    try self.io.wait(self.handle, .write);
                    continue;
                },
                else => |e| return e,
            };
            if (n == 0) return error.ConnectionReset;
            sent += n;
        }
    }
};

fn createSocket() NetError!Handle {
    if (comptime is_windows) {
        const s = winSocket();
        if (s == INVALID_SOCKET) return error.Unexpected;
        return s;
    } else {
        const fd = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0) catch return error.Unexpected;
        return @intCast(fd);
    }
}

fn closeHandle(h: Handle) void {
    if (h == 0) return;
    if (comptime is_windows) {
        _ = closesocket(h);
    } else {
        std.posix.close(@intCast(h));
    }
}

fn setNonBlocking(h: Handle) NetError!void {
    if (comptime is_windows) {
        var mode: u32 = 1;
        if (ioctlsocket(h, FIONBIO, &mode) != 0) return error.Unexpected;
    } else {
        const flags = std.posix.fcntl(@intCast(h), std.posix.F.GETFL, {}) catch return error.Unexpected;
        _ = std.posix.fcntl(@intCast(h), std.posix.F.SETFL, flags | std.posix.O.NONBLOCK) catch return error.Unexpected;
    }
}

fn setReuseAddr(h: Handle) NetError!void {
    if (comptime is_windows) {
        var yes: i32 = 1;
        _ = setsockopt(h, SOL_SOCKET, SO_REUSEADDR, @ptrCast(&yes), @sizeOf(i32));
    } else {
        std.posix.setsockopt(@intCast(h), std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1))) catch {};
    }
}

fn acceptOnce(h: Handle) NetError!Handle {
    if (comptime is_windows) {
        var addr: sockaddr_in = undefined;
        var len: i32 = @sizeOf(sockaddr_in);
        const c = winAccept(h, @ptrCast(&addr), &len);
        if (c == INVALID_SOCKET) {
            const e = WSAGetLastError();
            if (e == WSAEWOULDBLOCK) return error.WouldBlock;
            return error.Unexpected;
        }
        return c;
    } else {
        const c = std.posix.accept(@intCast(h), null, null) catch |err| switch (err) {
            error.WouldBlock => return error.WouldBlock,
            else => return error.Unexpected,
        };
        return @intCast(c);
    }
}

fn connectNonblockAddr(h: Handle, host_addr: u32, port: u16) NetError!void {
    if (comptime is_windows) {
        var sa: sockaddr_in = .{
            .sin_family = AF_INET,
            .sin_port = std.mem.nativeToBig(u16, port),
            .sin_addr = std.mem.nativeToBig(u32, host_addr),
            .sin_zero = @splat(0),
        };
        const rc = winConnect(h, @ptrCast(&sa), @sizeOf(sockaddr_in));
        if (rc == 0) return;
        const e = WSAGetLastError();
        if (e == WSAEWOULDBLOCK or e == WSAEINPROGRESS) return error.WouldBlock;
        if (e == WSAECONNREFUSED) return error.ConnectionRefused;
        return error.Unexpected;
    } else {
        var psa: std.posix.sockaddr.in = .{
            .family = std.posix.AF.INET,
            .port = std.mem.nativeToBig(u16, port),
            .addr = std.mem.nativeToBig(u32, host_addr),
        };
        std.posix.connect(@intCast(h), @ptrCast(&psa), @sizeOf(@TypeOf(psa))) catch |err| switch (err) {
            error.WouldBlock => return error.WouldBlock,
            error.ConnectionRefused => return error.ConnectionRefused,
            else => return error.Unexpected,
        };
    }
}

fn getSockPort(h: Handle) NetError!u16 {
    if (comptime is_windows) {
        var sa: sockaddr_in = undefined;
        var len: i32 = @sizeOf(sockaddr_in);
        if (getsockname(h, @ptrCast(&sa), &len) != 0) return error.Unexpected;
        return std.mem.bigToNative(u16, sa.sin_port);
    } else {
        var sa: std.posix.sockaddr.in = undefined;
        var len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.in);
        std.posix.getsockname(@intCast(h), @ptrCast(&sa), &len) catch return error.Unexpected;
        return std.mem.bigToNative(u16, sa.port);
    }
}

fn checkConnectError(h: Handle) NetError!void {
    if (comptime is_windows) {
        var err_code: i32 = 0;
        var len: i32 = @sizeOf(i32);
        _ = getsockopt(h, SOL_SOCKET, SO_ERROR, @ptrCast(&err_code), &len);
        if (err_code == 0) return;
        if (err_code == WSAECONNREFUSED) return error.ConnectionRefused;
        return error.Unexpected;
    } else {
        var e: i32 = 0;
        std.posix.getsockopt(@intCast(h), std.posix.SOL.SOCKET, std.posix.SO.ERROR, std.mem.asBytes(&e)) catch return error.Unexpected;
        if (e == 0) return;
        return error.ConnectionRefused;
    }
}

fn recvOnce(h: Handle, buf: []u8) NetError!usize {
    if (comptime is_windows) {
        const n = winRecv(h, buf.ptr, @intCast(buf.len), 0);
        if (n == SOCKET_ERROR) {
            const e = WSAGetLastError();
            if (e == WSAEWOULDBLOCK) return error.WouldBlock;
            if (e == WSAECONNRESET) return error.ConnectionReset;
            return error.Unexpected;
        }
        return @intCast(n);
    } else {
        const n = std.posix.recv(@intCast(h), buf, 0) catch |err| switch (err) {
            error.WouldBlock => return error.WouldBlock,
            error.ConnectionResetByPeer => return error.ConnectionReset,
            else => return error.Unexpected,
        };
        return n;
    }
}

fn sendOnce(h: Handle, buf: []const u8) NetError!usize {
    if (comptime is_windows) {
        const n = winSend(h, buf.ptr, @intCast(buf.len), 0);
        if (n == SOCKET_ERROR) {
            const e = WSAGetLastError();
            if (e == WSAEWOULDBLOCK) return error.WouldBlock;
            if (e == WSAECONNRESET) return error.ConnectionReset;
            return error.Unexpected;
        }
        return @intCast(n);
    } else {
        const n = std.posix.send(@intCast(h), buf, 0) catch |err| switch (err) {
            error.WouldBlock => return error.WouldBlock,
            error.ConnectionResetByPeer => return error.ConnectionReset,
            else => return error.Unexpected,
        };
        return n;
    }
}

fn winBindAddr(h: Handle, port: u16, host_addr: u32, backlog: u31) NetError!void {
    var sa: sockaddr_in = .{
        .sin_family = AF_INET,
        .sin_port = std.mem.nativeToBig(u16, port),
        .sin_addr = std.mem.nativeToBig(u32, host_addr),
        .sin_zero = @splat(0),
    };
    if (winBindSock(h, @ptrCast(&sa), @sizeOf(sockaddr_in)) != 0) {
        const e = WSAGetLastError();
        if (e == WSAEADDRINUSE) return error.AddressInUse;
        return error.Unexpected;
    }
    if (winListen(h, @intCast(backlog)) != 0) return error.Unexpected;
}

pub const UdpSocket = struct {
    handle: Handle,
    io: Backend,
    bound_port: u16 = 0,

    pub fn bind(io: Backend, port: u16) NetError!UdpSocket {
        return bindWith(io, port, .{});
    }

    pub fn bindWith(io: Backend, port: u16, opts: BindOpts) NetError!UdpSocket {
        return onWorker(udpBindImpl, .{ io, port, opts });
    }

    fn udpBindImpl(io: Backend, port: u16, opts: BindOpts) NetError!UdpSocket {
        const h = try createUdpSocket();
        errdefer closeHandle(h);
        try setNonBlocking(h);
        try setReuseAddr(h);
        if (comptime is_windows) {
            var sa: sockaddr_in = .{
                .sin_family = AF_INET,
                .sin_port = std.mem.nativeToBig(u16, port),
                .sin_addr = std.mem.nativeToBig(u32, opts.address.addr),
                .sin_zero = @splat(0),
            };
            if (winBindSock(h, @ptrCast(&sa), @sizeOf(sockaddr_in)) != 0) {
                const e = WSAGetLastError();
                if (e == WSAEADDRINUSE) return error.AddressInUse;
                return error.Unexpected;
            }
        } else {
            var sa: std.posix.sockaddr.in = .{
                .family = std.posix.AF.INET,
                .port = std.mem.nativeToBig(u16, port),
                .addr = std.mem.nativeToBig(u32, opts.address.addr),
            };
            std.posix.bind(@intCast(h), @ptrCast(&sa), @sizeOf(@TypeOf(sa))) catch |err| switch (err) {
                error.AddressInUse => return error.AddressInUse,
                else => return error.Unexpected,
            };
        }
        var actual = port;
        if (port == 0) {
            actual = getSockPort(h) catch port;
        }
        io.associate(h) catch {};
        return .{ .handle = h, .io = io, .bound_port = actual };
    }

    pub fn localPort(self: *const UdpSocket) u16 {
        return self.bound_port;
    }

    pub fn close(self: *UdpSocket) void {
        closeHandle(self.handle);
        self.handle = 0;
    }

    pub fn recv(self: *UdpSocket, buf: []u8) NetError!usize {
        while (true) {
            const n = onWorker(recvOnce, .{ self.handle, buf }) catch |err| switch (err) {
                error.WouldBlock => {
                    try self.io.wait(self.handle, .read);
                    continue;
                },
                else => |e| return e,
            };
            return n;
        }
    }

    pub fn sendTo(self: *UdpSocket, data: []const u8, address: Ipv4, port: u16) NetError!usize {
        while (true) {
            const n = onWorker(sendToOnce, .{ self.handle, data, address.addr, port }) catch |err| switch (err) {
                error.WouldBlock => {
                    try self.io.wait(self.handle, .write);
                    continue;
                },
                else => |e| return e,
            };
            return n;
        }
    }
};

fn createUdpSocket() NetError!Handle {
    if (comptime is_windows) {
        const s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        if (s == INVALID_SOCKET) return error.Unexpected;
        return s;
    } else {
        const fd = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0) catch return error.Unexpected;
        return @intCast(fd);
    }
}

fn sendToOnce(h: Handle, buf: []const u8, host_addr: u32, port: u16) NetError!usize {
    if (comptime is_windows) {
        var sa: sockaddr_in = .{
            .sin_family = AF_INET,
            .sin_port = std.mem.nativeToBig(u16, port),
            .sin_addr = std.mem.nativeToBig(u32, host_addr),
            .sin_zero = @splat(0),
        };
        const n = sendto(h, buf.ptr, @intCast(buf.len), 0, @ptrCast(&sa), @sizeOf(sockaddr_in));
        if (n == SOCKET_ERROR) {
            const e = WSAGetLastError();
            if (e == WSAEWOULDBLOCK) return error.WouldBlock;
            return error.Unexpected;
        }
        return @intCast(n);
    } else {
        var sa: std.posix.sockaddr.in = .{
            .family = std.posix.AF.INET,
            .port = std.mem.nativeToBig(u16, port),
            .addr = std.mem.nativeToBig(u32, host_addr),
        };
        const n = std.posix.sendto(@intCast(h), buf, 0, @ptrCast(&sa), @sizeOf(@TypeOf(sa))) catch |err| switch (err) {
            error.WouldBlock => return error.WouldBlock,
            else => return error.Unexpected,
        };
        return n;
    }
}

const INVALID_SOCKET: Handle = @bitCast(@as(isize, -1));
const SOCKET_ERROR: i32 = -1;
const AF_INET: u16 = 2;
const SOCK_STREAM: i32 = 1;
const SOCK_DGRAM: i32 = 2;
const IPPROTO_TCP: i32 = 6;
const IPPROTO_UDP: i32 = 17;
const FIONBIO: i32 = -2147195266; // 0x8004667E
const SOL_SOCKET: i32 = 0xffff;
const SO_REUSEADDR: i32 = 4;
const SO_ERROR: i32 = 0x1007;
const WSAEWOULDBLOCK: i32 = 10035;
const WSAEINPROGRESS: i32 = 10036;
const WSAECONNREFUSED: i32 = 10061;
const WSAEADDRINUSE: i32 = 10048;
const WSAECONNRESET: i32 = 10054;

const sockaddr_in = extern struct {
    sin_family: u16,
    sin_port: u16,
    sin_addr: u32,
    sin_zero: [8]u8 = @splat(0),
};

const WINAPI = std.builtin.CallingConvention.winapi;

extern "ws2_32" fn socket(af: i32, sock_type: i32, protocol: i32) callconv(WINAPI) Handle;
extern "ws2_32" fn closesocket(s: Handle) callconv(WINAPI) i32;
extern "ws2_32" fn ioctlsocket(s: Handle, cmd: i32, argp: *u32) callconv(WINAPI) i32;
extern "ws2_32" fn setsockopt(s: Handle, level: i32, optname: i32, optval: [*]const u8, optlen: i32) callconv(WINAPI) i32;
extern "ws2_32" fn getsockname(s: Handle, name: *anyopaque, namelen: *i32) callconv(WINAPI) i32;
extern "ws2_32" fn getsockopt(s: Handle, level: i32, optname: i32, optval: [*]u8, optlen: *i32) callconv(WINAPI) i32;
extern "ws2_32" fn bind(s: Handle, name: *const anyopaque, namelen: i32) callconv(WINAPI) i32;
extern "ws2_32" fn listen(s: Handle, backlog: i32) callconv(WINAPI) i32;
extern "ws2_32" fn accept(s: Handle, addr: ?*anyopaque, addrlen: ?*i32) callconv(WINAPI) Handle;
extern "ws2_32" fn connect(s: Handle, name: *const anyopaque, namelen: i32) callconv(WINAPI) i32;
extern "ws2_32" fn recv(s: Handle, buf: [*]u8, len: i32, flags: i32) callconv(WINAPI) i32;
extern "ws2_32" fn send(s: Handle, buf: [*]const u8, len: i32, flags: i32) callconv(WINAPI) i32;
extern "ws2_32" fn sendto(s: Handle, buf: [*]const u8, len: i32, flags: i32, to: *const anyopaque, tolen: i32) callconv(WINAPI) i32;
extern "ws2_32" fn WSAGetLastError() callconv(WINAPI) i32;

fn winSocket() Handle {
    return socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
}
fn winAccept(h: Handle, addr: ?*anyopaque, len: *i32) Handle {
    return accept(h, addr, len);
}
fn winConnect(h: Handle, name: *const anyopaque, namelen: i32) i32 {
    return connect(h, name, namelen);
}
fn winBindSock(h: Handle, name: *const anyopaque, namelen: i32) i32 {
    return bind(h, name, namelen);
}
fn winListen(h: Handle, backlog: i32) i32 {
    return listen(h, backlog);
}
fn winRecv(h: Handle, buf: [*]u8, len: i32, flags: i32) i32 {
    return recv(h, buf, len, flags);
}
fn winSend(h: Handle, buf: [*]const u8, len: i32, flags: i32) i32 {
    return send(h, buf, len, flags);
}
