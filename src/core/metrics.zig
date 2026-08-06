const std = @import("std");

pub const Metrics = struct {
    enabled: bool = false,

    spawns: std.atomic.Value(u64) = .init(0),
    finishes: std.atomic.Value(u64) = .init(0),
    yields: std.atomic.Value(u64) = .init(0),
    parks: std.atomic.Value(u64) = .init(0),
    steals: std.atomic.Value(u64) = .init(0),
    timer_fires: std.atomic.Value(u64) = .init(0),
    io_wakes: std.atomic.Value(u64) = .init(0),
    chan_sends: std.atomic.Value(u64) = .init(0),
    chan_recvs: std.atomic.Value(u64) = .init(0),

    pub fn init(enabled: bool) Metrics {
        return .{ .enabled = enabled };
    }

    pub fn inc(self: *Metrics, field: enum {
        spawns,
        finishes,
        yields,
        parks,
        steals,
        timer_fires,
        io_wakes,
        chan_sends,
        chan_recvs,
    }) void {
        if (!self.enabled) return;
        switch (field) {
            .spawns => _ = self.spawns.fetchAdd(1, .monotonic),
            .finishes => _ = self.finishes.fetchAdd(1, .monotonic),
            .yields => _ = self.yields.fetchAdd(1, .monotonic),
            .parks => _ = self.parks.fetchAdd(1, .monotonic),
            .steals => _ = self.steals.fetchAdd(1, .monotonic),
            .timer_fires => _ = self.timer_fires.fetchAdd(1, .monotonic),
            .io_wakes => _ = self.io_wakes.fetchAdd(1, .monotonic),
            .chan_sends => _ = self.chan_sends.fetchAdd(1, .monotonic),
            .chan_recvs => _ = self.chan_recvs.fetchAdd(1, .monotonic),
        }
    }

    pub const Snapshot = struct {
        spawns: u64,
        finishes: u64,
        yields: u64,
        parks: u64,
        steals: u64,
        timer_fires: u64,
        io_wakes: u64,
        chan_sends: u64,
        chan_recvs: u64,
    };

    pub fn snapshot(self: *const Metrics) Snapshot {
        return .{
            .spawns = self.spawns.load(.monotonic),
            .finishes = self.finishes.load(.monotonic),
            .yields = self.yields.load(.monotonic),
            .parks = self.parks.load(.monotonic),
            .steals = self.steals.load(.monotonic),
            .timer_fires = self.timer_fires.load(.monotonic),
            .io_wakes = self.io_wakes.load(.monotonic),
            .chan_sends = self.chan_sends.load(.monotonic),
            .chan_recvs = self.chan_recvs.load(.monotonic),
        };
    }

    pub fn format(self: Snapshot, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print(
            "spawns={d} finishes={d} yields={d} parks={d} steals={d} timers={d} io_wakes={d} chan_s/r={d}/{d}",
            .{
                self.spawns,
                self.finishes,
                self.yields,
                self.parks,
                self.steals,
                self.timer_fires,
                self.io_wakes,
                self.chan_sends,
                self.chan_recvs,
            },
        );
    }
};
