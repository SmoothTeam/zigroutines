const std = @import("std");
const zr = @import("zigroutines");
const builtin = @import("builtin");

fn supportsPollNet() bool {
    return switch (builtin.os.tag) {
        .windows, .linux, .macos, .freebsd => true,
        else => false,
    };
}

test "tcp echo loopback ephemeral port" {
    if (comptime !zr.context.supported) return error.SkipZigTest;
    if (!supportsPollNet()) return error.SkipZigTest;

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var rt = try zr.Runtime.init(alloc, .{
        .workers = 1,
        .stack_pool = false,
        .io = .poll,
    });
    defer rt.deinit();

    const bio = rt.ioBackend() orelse return error.SkipZigTest;

    const PortCh = zr.Channel(u16);
    const port_ch = try PortCh.create(alloc, 1);
    defer port_ch.destroy();

    const ResultCh = zr.Channel(bool);
    const result_ch = try ResultCh.create(alloc, 1);
    defer result_ch.destroy();

    const msg = "ping-zigroutines";

    const S = struct {
        fn server(io: zr.IoBackend, pch: *PortCh) void {
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
            const n = peer.read(&buf) catch return;
            if (n == 0) return;
            peer.writeAll(buf[0..n]) catch return;
        }

        fn clientTask(io: zr.IoBackend, pch: *PortCh, rch: *ResultCh) void {
            const p = pch.recv() catch {
                rch.send(false) catch {};
                return;
            };
            if (p == 0) {
                rch.send(false) catch {};
                return;
            }

            var stream = zr.TcpStream.connect(io, p) catch {
                rch.send(false) catch {};
                return;
            };
            defer stream.close();

            stream.writeAll(msg) catch {
                rch.send(false) catch {};
                return;
            };

            var buf: [64]u8 = undefined;
            stream.readExact(buf[0..msg.len]) catch {
                rch.send(false) catch {};
                return;
            };
            rch.send(std.mem.eql(u8, buf[0..msg.len], msg)) catch {};
        }

        fn driver(r: *zr.Runtime, io: zr.IoBackend, pch: *PortCh, rch: *ResultCh) void {
            _ = r.spawn(.{ .stack_size = 128 * 1024 }, server, .{ io, pch }) catch {
                rch.send(false) catch {};
                return;
            };
            _ = r.spawn(.{ .stack_size = 128 * 1024 }, clientTask, .{ io, pch, rch }) catch {
                rch.send(false) catch {};
                return;
            };

            const outcome = zr.select.recv(bool, rch, .{
                .timeout_ns = 3 * std.time.ns_per_s,
                .timers = &r.timers,
            });
            switch (outcome) {
                .value => |ok| {
                    if (!ok) rch.send(false) catch {};
                    rch.send(ok) catch {};
                },
                .timeout, .closed, .canceled => {
                    io.cancelAll();
                    rch.send(false) catch {};
                },
            }
        }
    };

    _ = try rt.spawn(.{ .stack_size = 128 * 1024 }, S.driver, .{ &rt, bio, port_ch, result_ch });
    try rt.run();

    const ok = result_ch.tryRecv() catch false;
    try std.testing.expect(ok);
}

test "tcp echo bind any address" {
    if (comptime !zr.context.supported) return error.SkipZigTest;
    if (!supportsPollNet()) return error.SkipZigTest;

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var rt = try zr.Runtime.init(alloc, .{
        .workers = 1,
        .stack_pool = false,
        .io = .poll,
    });
    defer rt.deinit();
    const bio = rt.ioBackend() orelse return error.SkipZigTest;

    const ResultCh = zr.Channel(bool);
    const result_ch = try ResultCh.create(alloc, 1);
    defer result_ch.destroy();

    const S = struct {
        fn work(r: *zr.Runtime, io: zr.IoBackend, rch: *ResultCh) void {
            var ln = zr.TcpListener.bindWith(io, 0, .{ .address = .any }) catch {
                rch.send(false) catch {};
                return;
            };
            defer ln.close();
            const port = ln.localPort();

            const Client = struct {
                fn run(client_io: zr.IoBackend, p: u16, out: *ResultCh) void {
                    var stream = zr.TcpStream.connect(client_io, p) catch {
                        out.send(false) catch {};
                        return;
                    };
                    defer stream.close();
                    stream.writeAll("z") catch {
                        out.send(false) catch {};
                        return;
                    };
                    var b: [1]u8 = undefined;
                    stream.readExact(&b) catch {
                        out.send(false) catch {};
                        return;
                    };
                    out.send(b[0] == 'z') catch {};
                }
            };

            _ = r.spawn(.{}, Client.run, .{ io, port, rch }) catch {
                rch.send(false) catch {};
                return;
            };

            var peer = ln.accept() catch {
                io.cancelAll();
                rch.send(false) catch {};
                return;
            };
            defer peer.close();
            var buf: [8]u8 = undefined;
            const n = peer.read(&buf) catch {
                rch.send(false) catch {};
                return;
            };
            peer.writeAll(buf[0..n]) catch {
                rch.send(false) catch {};
                return;
            };

            const outcome = zr.select.recv(bool, rch, .{
                .timeout_ns = 3 * std.time.ns_per_s,
                .timers = &r.timers,
            });
            switch (outcome) {
                .value => |ok| rch.send(ok) catch {},
                else => {
                    io.cancelAll();
                    rch.send(false) catch {};
                },
            }
        }
    };

    _ = try rt.spawn(.{ .stack_size = 128 * 1024 }, S.work, .{ &rt, bio, result_ch });
    try rt.run();
    try std.testing.expect(result_ch.tryRecv() catch false);
}

test "udp loopback send recv" {
    if (comptime !zr.context.supported) return error.SkipZigTest;
    if (!supportsPollNet()) return error.SkipZigTest;

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var rt = try zr.Runtime.init(alloc, .{
        .workers = 1,
        .stack_pool = false,
        .io = .poll,
    });
    defer rt.deinit();
    const bio = rt.ioBackend() orelse return error.SkipZigTest;

    const OkCh = zr.Channel(bool);
    const ok_ch = try OkCh.create(alloc, 1);
    defer ok_ch.destroy();

    const S = struct {
        fn work(r: *zr.Runtime, io: zr.IoBackend, och: *OkCh) void {
            var rx = zr.UdpSocket.bind(io, 0) catch {
                och.send(false) catch {};
                return;
            };
            defer rx.close();
            const port = rx.localPort();
            if (port == 0) {
                och.send(false) catch {};
                return;
            }

            var tx = zr.UdpSocket.bind(io, 0) catch {
                och.send(false) catch {};
                return;
            };
            defer tx.close();

            const payload = "udp-ping";
            _ = tx.sendTo(payload, .loopback, port) catch {
                och.send(false) catch {};
                return;
            };

            const Done = zr.Channel(bool);
            const done = Done.create(r.allocator, 1) catch {
                och.send(false) catch {};
                return;
            };
            defer done.destroy();

            const Recv = struct {
                fn run(sock: *zr.UdpSocket, d: *Done, expect: []const u8) void {
                    var buf: [32]u8 = undefined;
                    const n = sock.recv(&buf) catch {
                        d.send(false) catch {};
                        return;
                    };
                    d.send(n == expect.len and std.mem.eql(u8, buf[0..n], expect)) catch {};
                }
            };
            _ = r.spawn(.{}, Recv.run, .{ &rx, done, payload }) catch {
                och.send(false) catch {};
                return;
            };

            const outcome = zr.select.recv(bool, done, .{
                .timeout_ns = 3 * std.time.ns_per_s,
                .timers = &r.timers,
            });
            switch (outcome) {
                .value => |ok| och.send(ok) catch {},
                else => {
                    io.cancelAll();
                    och.send(false) catch {};
                },
            }
        }
    };

    _ = try rt.spawn(.{ .stack_size = 128 * 1024 }, S.work, .{ &rt, bio, ok_ch });
    try rt.run();
    try std.testing.expect(ok_ch.tryRecv() catch false);
}

test "iocp backend create and supports_async on windows" {
    if (comptime !zr.context.supported) return error.SkipZigTest;

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var rt = try zr.Runtime.init(alloc, .{
        .workers = 1,
        .stack_pool = false,
        .io = .iocp,
    });
    defer rt.deinit();
    const bio = rt.ioBackend() orelse return error.TestUnexpectedResult;
    if (builtin.os.tag == .windows) {
        try std.testing.expect(bio.supportsAsync());
    }
}

test "io cancelAll unblocks waiters" {
    if (comptime !zr.context.supported) return error.SkipZigTest;
    if (!supportsPollNet()) return error.SkipZigTest;

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var rt = try zr.Runtime.init(alloc, .{
        .workers = 1,
        .stack_pool = false,
        .io = .poll,
    });
    defer rt.deinit();
    const bio = rt.ioBackend() orelse return error.SkipZigTest;

    const S = struct {
        var saw_err: bool = false;
        fn blocker(io: zr.IoBackend) void {
            var ln = zr.TcpListener.bind(io, 0) catch return;
            defer ln.close();
            _ = ln.accept() catch {
                saw_err = true;
                return;
            };
        }
        fn canceler(io: zr.IoBackend) void {
            zr.sleep(5 * std.time.ns_per_ms);
            io.cancelAll();
        }
    };
    S.saw_err = false;
    _ = try rt.spawn(.{ .stack_size = 128 * 1024 }, S.blocker, .{bio});
    _ = try rt.spawn(.{}, S.canceler, .{bio});
    try rt.run();
    try std.testing.expect(S.saw_err);
}
