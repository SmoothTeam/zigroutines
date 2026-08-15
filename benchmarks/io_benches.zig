const std = @import("std");
const builtin = @import("builtin");
const zr = @import("zigroutines");
const common = @import("common.zig");

fn supportsPollNet() bool {
    return switch (builtin.os.tag) {
        .windows, .linux, .macos, .freebsd => true,
        else => false,
    };
}

pub fn runAll(alloc: std.mem.Allocator) !void {
    if (comptime !zr.context.supported) {
        std.debug.print("tcp_pingpong: skip (unsupported target)\n", .{});
        std.debug.print("udp_ping: skip (unsupported target)\n", .{});
        return;
    }
    if (!supportsPollNet()) {
        std.debug.print("tcp_pingpong: skip (no poll net)\n", .{});
        std.debug.print("udp_ping: skip (no poll net)\n", .{});
        return;
    }
    try tcpPingPong(alloc, .poll);
    try udpPing(alloc, .poll);
    if (comptime builtin.os.tag == .windows) {
        try tcpPingPong(alloc, .iocp);
    }
    if (comptime builtin.os.tag == .linux) {
        try tcpPingPong(alloc, .io_uring);
        try udpPing(alloc, .io_uring);
    }
}

fn tcpPingPong(alloc: std.mem.Allocator, io_kind: zr.Config.IoConfig) !void {
    const rounds: usize = 20_000;
    var rt = try zr.Runtime.init(alloc, .{
        .workers = 1,
        .stack_pool = io_kind != .iocp,
        .io = io_kind,
    });
    defer rt.deinit();
    const tag: []const u8 = switch (io_kind) {
        .iocp => "tcp_pingpong_iocp",
        .io_uring => "tcp_pingpong_io_uring",
        else => "tcp_pingpong",
    };
    const bio = rt.ioBackend() orelse {
        std.debug.print("{s}: skip (no io backend)\n", .{tag});
        return;
    };

    const PortCh = zr.Channel(u16);
    const port_ch = try PortCh.create(alloc, 1);
    defer port_ch.destroy();

    const DoneCh = zr.Channel(usize);
    const done_ch = try DoneCh.create(alloc, 1);
    defer done_ch.destroy();

    const msg = "PING\n";

    const S = struct {
        fn server(io: zr.IoBackend, pch: *PortCh, expect: usize) void {
            var ln = zr.TcpListener.bind(io, 0) catch {
                pch.close();
                return;
            };
            defer ln.close();
            pch.send(ln.localPort()) catch {
                pch.close();
                return;
            };

            var peer = ln.accept() catch return;
            defer peer.close();

            var buf: [64]u8 = undefined;
            var got: usize = 0;
            while (got < expect) {
                const n = peer.read(&buf) catch break;
                if (n == 0) break;
                peer.writeAll(buf[0..n]) catch break;
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    if (buf[i] == '\n') got += 1;
                }
            }
        }

        fn client(io: zr.IoBackend, pch: *PortCh, dch: *DoneCh, count: usize) void {
            const port = pch.recv() catch {
                dch.send(0) catch {};
                return;
            };
            if (port == 0) {
                dch.send(0) catch {};
                return;
            }

            var stream = zr.TcpStream.connect(io, port) catch {
                dch.send(0) catch {};
                return;
            };
            defer stream.close();

            var buf: [64]u8 = undefined;
            var done: usize = 0;
            while (done < count) : (done += 1) {
                stream.writeAll(msg) catch {
                    dch.send(done) catch {};
                    return;
                };
                stream.readExact(buf[0..msg.len]) catch {
                    dch.send(done) catch {};
                    return;
                };
            }
            dch.send(done) catch {};
        }

        fn driver(r: *zr.Runtime, io: zr.IoBackend, pch: *PortCh, dch: *DoneCh, count: usize) void {
            _ = r.spawn(.{}, server, .{ io, pch, count }) catch {
                dch.send(0) catch {};
                return;
            };
            _ = r.spawn(.{}, client, .{ io, pch, dch, count }) catch {
                dch.send(0) catch {};
                return;
            };
            const outcome = zr.select.recv(usize, dch, .{
                .timeout_ns = 60 * std.time.ns_per_s,
                .timers = &r.timers,
            });
            switch (outcome) {
                .value => |n| dch.send(n) catch {},
                else => {
                    io.cancelAll();
                    dch.send(0) catch {};
                },
            }
        }
    };

    _ = try rt.spawn(.{}, S.driver, .{ &rt, bio, port_ch, done_ch, rounds });

    const t0 = common.nowNs();
    try rt.run();
    const t1 = common.nowNs();

    const completed = done_ch.tryRecv() catch 0;
    if (completed == 0) {
        std.debug.print("{s}: failed (0 roundtrips)\n", .{tag});
        return;
    }
    common.printThroughput(tag, completed, t1 - t0, "roundtrips");
    const lat_tag: []const u8 = switch (io_kind) {
        .iocp => "tcp_pingpong_iocp_latency",
        .io_uring => "tcp_pingpong_io_uring_latency",
        else => "tcp_pingpong_latency",
    };
    common.printRate(lat_tag, completed, t1 - t0);
}

fn udpPing(alloc: std.mem.Allocator, io_kind: zr.Config.IoConfig) !void {
    const rounds: usize = 10_000;
    var rt = try zr.Runtime.init(alloc, .{
        .workers = 1,
        .stack_pool = true,
        .io = io_kind,
    });
    defer rt.deinit();
    const tag: []const u8 = switch (io_kind) {
        .iocp => "udp_ping_iocp",
        .io_uring => "udp_ping_io_uring",
        else => "udp_ping",
    };
    const bio = rt.ioBackend() orelse {
        std.debug.print("{s}: skip (no io backend)\n", .{tag});
        return;
    };

    const DoneCh = zr.Channel(usize);
    const done_ch = try DoneCh.create(alloc, 1);
    defer done_ch.destroy();

    const PortCh = zr.Channel(u16);
    const port_ch = try PortCh.create(alloc, 1);
    defer port_ch.destroy();

    const payload = "PING";

    const S = struct {
        fn server(io: zr.IoBackend, pch: *PortCh, expect: usize) void {
            var sock = zr.UdpSocket.bind(io, 0) catch {
                pch.close();
                return;
            };
            defer sock.close();
            pch.send(sock.localPort()) catch {
                pch.close();
                return;
            };

            var buf: [32]u8 = undefined;
            var i: usize = 0;
            while (i < expect) : (i += 1) {
                _ = sock.recv(&buf) catch return;
            }
        }

        fn client(io: zr.IoBackend, pch: *PortCh, dch: *DoneCh, count: usize) void {
            const port = pch.recv() catch {
                dch.send(0) catch {};
                return;
            };
            if (port == 0) {
                dch.send(0) catch {};
                return;
            }

            var sock = zr.UdpSocket.bind(io, 0) catch {
                dch.send(0) catch {};
                return;
            };
            defer sock.close();

            var done: usize = 0;
            while (done < count) : (done += 1) {
                _ = sock.sendTo(payload, .loopback, port) catch {
                    dch.send(done) catch {};
                    return;
                };
                zr.yield();
            }
            dch.send(done) catch {};
        }

        fn driver(r: *zr.Runtime, io: zr.IoBackend, pch: *PortCh, dch: *DoneCh, count: usize) void {
            _ = r.spawn(.{}, server, .{ io, pch, count }) catch {
                dch.send(0) catch {};
                return;
            };
            _ = r.spawn(.{}, client, .{ io, pch, dch, count }) catch {
                dch.send(0) catch {};
                return;
            };
            const outcome = zr.select.recv(usize, dch, .{
                .timeout_ns = 30 * std.time.ns_per_s,
                .timers = &r.timers,
            });
            io.cancelAll();
            switch (outcome) {
                .value => |n| dch.send(n) catch {},
                else => dch.send(0) catch {},
            }
        }
    };

    _ = try rt.spawn(.{}, S.driver, .{ &rt, bio, port_ch, done_ch, rounds });

    const t0 = common.nowNs();
    try rt.run();
    const t1 = common.nowNs();

    const completed = done_ch.tryRecv() catch 0;
    if (completed == 0) {
        std.debug.print("{s}: failed (0 packets)\n", .{tag});
        return;
    }
    common.printThroughput(tag, completed, t1 - t0, "pkts");
    const lat_tag: []const u8 = switch (io_kind) {
        .iocp => "udp_ping_iocp_latency",
        .io_uring => "udp_ping_io_uring_latency",
        else => "udp_ping_latency",
    };
    common.printRate(lat_tag, completed, t1 - t0);
}
