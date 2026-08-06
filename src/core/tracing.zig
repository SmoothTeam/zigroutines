const std = @import("std");
const task_mod = @import("task.zig");

pub const Event = enum {
    task_spawn,
    task_start,
    task_yield,
    task_park,
    task_wake,
    task_finish,
    chan_send,
    chan_recv,
    select_enter,
    select_leave,
    io_wait,
    io_wake,
    cancel,
    custom,
};

pub const Record = struct {
    event: Event,
    task_id: u64 = 0,
    detail: u64 = 0,
    name: ?[:0]const u8 = null,
};

pub const Tracer = struct {
    ptr: *anyopaque,
    on_event: *const fn (ptr: *anyopaque, rec: Record) void,
};

var global_tracer: ?Tracer = null;

pub fn setTracer(t: ?Tracer) void {
    global_tracer = t;
}

pub fn getTracer() ?Tracer {
    return global_tracer;
}

pub fn emit(event: Event, detail: u64) void {
    const tr = global_tracer orelse return;
    var task_id: u64 = 0;
    var name: ?[:0]const u8 = null;
    if (task_mod.current()) |t| {
        task_id = @intFromEnum(t.id);
        name = t.name;
    }
    tr.on_event(tr.ptr, .{
        .event = event,
        .task_id = task_id,
        .detail = detail,
        .name = name,
    });
}

pub fn emitTask(event: Event, t: *task_mod.Task, detail: u64) void {
    const tr = global_tracer orelse return;
    tr.on_event(tr.ptr, .{
        .event = event,
        .task_id = @intFromEnum(t.id),
        .detail = detail,
        .name = t.name,
    });
}

pub const RingTracer = struct {
    buf: []Record,
    pos: std.atomic.Value(usize) = .init(0),
    count: std.atomic.Value(usize) = .init(0),

    pub fn init(buf: []Record) RingTracer {
        return .{ .buf = buf };
    }

    pub fn tracer(self: *RingTracer) Tracer {
        return .{
            .ptr = self,
            .on_event = onEvent,
        };
    }

    fn onEvent(ptr: *anyopaque, rec: Record) void {
        const self: *RingTracer = @ptrCast(@alignCast(ptr));
        if (self.buf.len == 0) return;
        const i = self.pos.fetchAdd(1, .monotonic) % self.buf.len;
        self.buf[i] = rec;
        _ = self.count.fetchAdd(1, .monotonic);
    }

    pub fn len(self: *const RingTracer) usize {
        return @min(self.count.load(.monotonic), self.buf.len);
    }
};
