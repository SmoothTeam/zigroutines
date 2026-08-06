const std = @import("std");
const zr = @import("zigroutines");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var rt = try zr.Runtime.init(alloc, .{
        .workers = 1,
        .stack_pool = false,
        .io = .poll,
    });
    defer rt.deinit();

    const bio = rt.ioBackend() orelse {
        std.debug.print("no io backend\n", .{});
        return;
    };

    const PortCh = zr.Channel(u16);
    const port_ch = try PortCh.create(alloc, 1);
    defer port_ch.destroy();

    const S = struct {
        var ok: bool = false;

        fn server(io: zr.IoBackend, pch: *PortCh) void {
            std.debug.print("server: bind\n", .{});
            var ln = zr.TcpListener.bind(io, 0) catch |e| {
                std.debug.print("server: bind err {any}\n", .{e});
                pch.close();
                return;
            };
            defer ln.close();
            const p = ln.localPort();
            std.debug.print("server: port {d}\n", .{p});
            pch.send(p) catch {
                pch.close();
                return;
            };
            std.debug.print("server: accept\n", .{});
            var peer = ln.accept() catch |e| {
                std.debug.print("server: accept err {any}\n", .{e});
                return;
            };
            defer peer.close();
            std.debug.print("server: accepted\n", .{});

            var buf: [64]u8 = undefined;
            const n = peer.read(&buf) catch |e| {
                std.debug.print("server: read err {any}\n", .{e});
                return;
            };
            std.debug.print("server: read {d}\n", .{n});
            peer.writeAll(buf[0..n]) catch |e| {
                std.debug.print("server: write err {any}\n", .{e});
                return;
            };
            std.debug.print("server: done\n", .{});
        }

        fn clientTask(io: zr.IoBackend, pch: *PortCh) void {
            std.debug.print("client: recv port\n", .{});
            const p = pch.recv() catch |e| {
                std.debug.print("client: port err {any}\n", .{e});
                return;
            };
            std.debug.print("client: connect {d}\n", .{p});
            var stream = zr.TcpStream.connect(io, p) catch |e| {
                std.debug.print("client: connect err {any}\n", .{e});
                return;
            };
            defer stream.close();
            const msg = "ping-zigroutines";
            stream.writeAll(msg) catch |e| {
                std.debug.print("client: write err {any}\n", .{e});
                return;
            };
            std.debug.print("client: wrote\n", .{});
            var buf: [64]u8 = undefined;
            stream.readExact(buf[0..msg.len]) catch |e| {
                std.debug.print("client: read err {any}\n", .{e});
                return;
            };
            ok = std.mem.eql(u8, buf[0..msg.len], msg);
            std.debug.print("client: ok={}\n", .{ok});
        }

        fn watchdog(io: zr.IoBackend) void {
            zr.sleep(5 * std.time.ns_per_s);
            if (!ok) {
                std.debug.print("watchdog: cancelAll after 5s\n", .{});
                io.cancelAll();
            }
        }
    };

    S.ok = false;
    _ = try rt.spawn(.{ .stack_size = 128 * 1024 }, S.server, .{ bio, port_ch });
    _ = try rt.spawn(.{ .stack_size = 128 * 1024 }, S.clientTask, .{ bio, port_ch });
    _ = try rt.spawn(.{}, S.watchdog, .{bio});
    try rt.run();
    std.debug.print("result ok={}\n", .{S.ok});
    if (!S.ok) std.process.exit(1);
}
