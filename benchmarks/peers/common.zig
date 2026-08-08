const std = @import("std");

var g_io: std.Io = undefined;
var g_io_ready: bool = false;

pub fn init(io: std.Io) void {
    g_io = io;
    g_io_ready = true;
}

pub fn nowNs() i128 {
    std.debug.assert(g_io_ready);
    const ts = std.Io.Clock.awake.now(g_io);
    return @intCast(ts.nanoseconds);
}

pub fn printRate(name: []const u8, ops: usize, dt_ns: i128) void {
    if (ops == 0) {
        std.debug.print("{s}: 0 ops (skipped)\n", .{name});
        return;
    }
    const dt: f64 = @floatFromInt(@max(dt_ns, 1));
    const ops_f: f64 = @floatFromInt(ops);
    const ns_per = dt / ops_f;
    const ops_per_ns = ops_f / dt;
    const mops = ops_f / (dt / 1e6) / 1000.0;
    std.debug.print("{s}: {d} ops in {d:.3} ms → {d:.1} ns/op  ({d:.6} ops/ns, {d:.2} Mops/s)\n", .{
        name,
        ops,
        dt / 1e6,
        ns_per,
        ops_per_ns,
        mops,
    });
}

pub fn printThroughput(name: []const u8, ops: usize, dt_ns: i128, unit: []const u8) void {
    if (dt_ns <= 0) {
        std.debug.print("{s}: {d} {s} (dt=0)\n", .{ name, ops, unit });
        return;
    }
    const dt: f64 = @floatFromInt(dt_ns);
    const ops_f: f64 = @floatFromInt(ops);
    const per_s = ops_f / (dt / 1e9);
    const ns_per = dt / ops_f;
    std.debug.print("{s}: {d} {s} in {d:.3} ms → {d:.0} {s}/s  ({d:.1} ns/op)\n", .{
        name,
        ops,
        unit,
        dt / 1e6,
        per_s,
        unit,
        ns_per,
    });
}
