const std = @import("std");
const builtin = @import("builtin");

fn nowNs() i128 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const ts = std.Io.Clock.boot.now(io);
    return @intCast(ts.nanoseconds);
}

pub const WorkerWake = struct {
    signaled: std.atomic.Value(bool) = .init(false),
    waiting: std.atomic.Value(u32) = .init(0),

    pub fn init() WorkerWake {
        return .{};
    }

    pub fn deinit(self: *WorkerWake) void {
        self.* = undefined;
    }

    pub fn wait(self: *WorkerWake, timeout_ns: ?u64) void {
        _ = self.waiting.fetchAdd(1, .acq_rel);
        defer _ = self.waiting.fetchSub(1, .acq_rel);

        const start = nowNs();
        const budget: i128 = if (timeout_ns) |ns| @intCast(ns) else 50 * std.time.ns_per_ms;

        var spins: u32 = 0;
        while (true) {
            if (self.signaled.swap(false, .acq_rel)) return;
            if (nowNs() - start >= budget) return;

            spins +%= 1;
            if (spins < 64) {
                std.atomic.spinLoopHint();
            } else if (spins < 256) {
                std.Thread.yield() catch {};
            } else {
                if (comptime builtin.os.tag == .windows) {
                    sleepMs(1);
                } else {
                    const req = std.posix.timespec{ .sec = 0, .nsec = 1_000_000 };
                    _ = std.posix.nanosleep(&req, null);
                }
                spins = 0;
            }
        }
    }

    pub fn signal(self: *WorkerWake) void {
        self.signaled.store(true, .release);
    }

    pub fn signalAll(self: *WorkerWake) void {
        self.signaled.store(true, .release);
    }
};

fn sleepMs(ms: u32) void {
    if (comptime builtin.os.tag == .windows) {
        const WINAPI = std.builtin.CallingConvention.winapi;
        const Sleep = struct {
            extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(WINAPI) void;
        }.Sleep;
        Sleep(ms);
    }
}

pub const is_windows = builtin.os.tag == .windows;
