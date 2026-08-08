const std = @import("std");

pub fn nowNs() i128 {
    const io = std.Io.Threaded.global_single_threaded.io();
    return @intCast(std.Io.Clock.boot.now(io).nanoseconds);
}

pub fn printRate(name: []const u8, ops: usize, dt_ns: i128) void {
    if (ops == 0) {
        std.debug.print("{s}: 0 ops (skipped or empty)\n", .{name});
        return;
    }
    const dt: f64 = @floatFromInt(@max(dt_ns, 1));
    const ops_f: f64 = @floatFromInt(ops);
    const ns_per = dt / ops_f;
    const ops_per_ns = ops_f / dt;
    const mops = ops_f / (dt / 1e3);
    std.debug.print("{s}: {d} ops in {d:.3} ms → {d:.1} ns/op  ({d:.6} ops/ns, {d:.2} Mops/s)\n", .{
        name,
        ops,
        dt / 1e6,
        ns_per,
        ops_per_ns,
        mops,
    });
}

pub fn printWall(name: []const u8, dt_ns: i128) void {
    const dt: f64 = @floatFromInt(dt_ns);
    std.debug.print("{s}: {d:.3} ms wall\n", .{ name, dt / 1e6 });
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
    const ops_per_ns = ops_f / dt;
    std.debug.print("{s}: {d} {s} in {d:.3} ms → {d:.0} {s}/s  ({d:.1} ns/op, {d:.6} ops/ns)\n", .{
        name,
        ops,
        unit,
        dt / 1e6,
        per_s,
        unit,
        ns_per,
        ops_per_ns,
    });
}
