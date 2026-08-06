const std = @import("std");
const task_mod = @import("task.zig");
const timer_mod = @import("timer_queue.zig");

pub const Config = struct {
    enabled: bool = false,
    quantum_ns: u64 = 5 * std.time.ns_per_ms,
};

threadlocal var tls_slice_start: i128 = 0;
threadlocal var tls_enabled: bool = false;
threadlocal var tls_quantum_ns: u64 = 5 * std.time.ns_per_ms;

pub fn bind(cfg: Config) void {
    tls_enabled = cfg.enabled;
    tls_quantum_ns = cfg.quantum_ns;
    tls_slice_start = timer_mod.nowNs();
}

pub fn onTaskStart() void {
    tls_slice_start = timer_mod.nowNs();
}

pub fn checkpoint() void {
    if (!tls_enabled) return;
    const now = timer_mod.nowNs();
    if (now - tls_slice_start >= @as(i128, @intCast(tls_quantum_ns))) {
        tls_slice_start = now;
        if (task_mod.current()) |_| {
            task_mod.yield();
        }
    }
}

pub fn forceYield() void {
    if (task_mod.current()) |_| {
        task_mod.yield();
    }
}

pub fn forEach(comptime n: usize, comptime body: fn (usize) void) void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        body(i);
        checkpoint();
    }
}

pub fn isEnabled() bool {
    return tls_enabled;
}
